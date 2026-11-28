# Performance budgets in CI

SPEC §15 sets budgets that are requirements. The CI job **Performance budgets** (`.github/workflows/build.yml`, job `perf`) checks the engine's share of them on every push with `tidings-bench` (`MailEngine/Sources/tidings-bench`).

## What it measures

A synthetic mailbox of **250,000 messages** (`SyntheticCorpus`: Zipf vocabulary, mixed Danish/English, eight years of mail). It is shaped like a real account: mail from the last 45 days is in the Inbox (about 3.8k messages), the rest is in Archive, and conversations run from one to six messages. The 300 newest Inbox messages also have a raw body in the cache tier, in three kinds: plain text, a ~50 KB HTML newsletter, and a message with a 256 KB attachment.

| Metric | What the engine does | Budget |
|---|---|---|
| Cold launch → usable stream (p50 of 7 opens) | Open `MailStore` (GRDB pool, migration check) and read the Inbox conversations, as `AppModel.reload` does | < 400 ms |
| Search keystroke → results (p95) | Phase 1 of `AppModel.runSearch`: `SearchEngine.hits` plus the person card (`contact(for:)`), over the typed sequence from `tidings-probe bench-search` (22 queries × 10 rounds) | < 30 ms |
| Search facets (p95) | Phase 2: `SearchEngine.facets` over the same queries (skipped for a lone letter, as in the app) | < 100 ms |
| Search person card (p95) | `contact(for:)` alone, also over prefixes of busy senders ("no" → every noreply@) | — (regressions reported) |
| Open cached message (p95) | The conversation's messages, the raw body from the cache tier, a full MIME parse | < 50 ms |
| Peak memory | The bench process's peak resident size | < 300 MB |
| Store on disk | Reported only | — |

These are the **engine's share** of each budget. SwiftUI layout, the `WKWebView`, scrolling at 120 fps and next-frame triage feedback can't be measured headless, and they aren't in these numbers. The runner is a shared Linux x86_64 machine and is slower than a current Mac (M0's 6.1 ms search p95 on a Mac is ~11 ms here), so passing in CI leaves the Mac with more headroom, not less.

`run` makes five passes over everything, and each metric reports its median pass: one pass's search p95 varies by ±15% on identical code, while the median of five varies by a few percent.

## When it fails

- **Over budget**: always a failure.
- **Regression**: more than 10% slower than the baseline, and by more than the metric's noise floor (1 ms for search and opening a message, 3 ms for facets, 5 ms for launch and the person card, 8 MB for memory). The baseline is the results of the last passing run on `main`, kept in the Actions cache (`perf-baseline-<sha>`). Timings are compared only between runs on the **same CPU model**. A slowdown against a baseline from another processor shows as ⚠️ in the report and doesn't fail. In CI a regression is a warning, not a failure (`--warn-on-regression`): two shared VMs with the same CPU model can differ by more than 10%. Budgets always fail.
- When either check fails, the job measures once more before deciding, so one bad minute on a shared runner doesn't fail the build.

The report is in the job's summary, and the raw results are uploaded as the `perf-results` artifact.

The no-change sync budget needs the local Dovecot, so it stays a manual check: `TIDINGS_BENCH=10000 swift test --filter SyncBenchmarkTests`.

## Running it locally

```sh
swift build -c release --package-path MailEngine --product tidings-bench
B=MailEngine/.build/release/tidings-bench
$B seed --dir /tmp/bench          # ~4 minutes, once; 1.5 GB
$B run  --dir /tmp/bench --out before.json
# …change something, rebuild…
$B run  --dir /tmp/bench --out after.json
$B compare --current after.json --baseline before.json
```

A seeded directory can be reused across changes. Delete it and seed again after a migration that changes how messages are stored or indexed.

## History

- **2026-11-28, first run:** search facets p95 was **544 ms** (M0: 50 ms). Two filters added after M0 to every search plan made every query read the `message` table: "leave Junk out" (local junk filter) and "leave reactions out" (email reactions). Facets then joined `message` once per match (130k for "fa") and ran a subquery each time. Fix: reactions are no longer put in the full-text index (migration `v27-reactions-unindexed`), and facets for queries the sort key can answer stream rowids from the index and skip the few Junk and reaction keys in Swift. Result: **34 ms**. The year facet also stopped calling `Calendar` once per day bucket (slow on Linux).

  Building the check turned up two more problems, fixed the same day:
  - **Results waited for everything.** `AppModel.runSearch` showed hits only once facets and the person card were ready too: ~87 ms for "fa" after the facets fix, ~550 ms before it. Now the hits and the card show together (phase 1, ~14 ms p95) and the facets follow (phase 2). The card had to get faster for that: it grouped every sender match (~250 ms for "no" at 250k), and now it weighs the newest 1,000 matches and counts the chosen address exactly from the `fromAddress` index (3–8 ms). For a prefix that several senders share, it now picks the one you've heard from most lately rather than most ever.
  - **The unified Inbox scanned every message.** `threads(mailbox:)` without an account can't use `message_mailbox_thread` (account first), so each reload walked all 250k messages through the thread index: ~275 ms. Migration `v27-stream-index` adds a covering index `(mailbox, threadID, sortKey, surfacedAt, date, reactionTo, accountID)` that answers it from the index alone. (A narrower `(mailbox, threadID, sortKey)` measured **~45 ms**; the covering one also skips the row reads.)

