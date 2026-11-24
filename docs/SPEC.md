# Tidings — product & technical spec

> Working codename. The product name is a build setting (`PRODUCT_DISPLAY_NAME`) so a rename is cheap.
> Decisions here came out of a grilling session on 2026-11-24 (Q1–Q41). Big, hard-to-reverse choices have an ADR in [`docs/adr/`](adr/).

## 1. What it is

A native, keyboard-first, local-first mail client for macOS (iOS later) with Google Inbox–style triage, Liquid Glass UI, on-device AI sorting, Outlook-style rules, smart folders and McMaster-fast search. IMAP/SMTP only for now; iCloud Mail is the reference account.

**Audience:** Magnus's daily driver, open source (AGPL-3.0), built cleanly enough to ship later. App Store sandbox compatible from day one.

**Platforms:** macOS 26+ and iOS 26+, Apple silicon only (Liquid Glass + Foundation Models).

## 2. Accounts & protocol

- Multi-account architecture from day one, unified inbox. v1 is tested against **iCloud + generic IMAP/SMTP**. Gmail/M365 (OAuth, labels) later.
- iCloud auth = **app-specific password** (no third-party OAuth). Stored in Keychain only.
- iCloud facts the engine must respect (see [research notes](research/icloud-imap.md)):
  - Re-issue `CAPABILITY` after login (pre-auth list is minimal; proxy quirk).
  - `ENABLE CONDSTORE QRESYNC` returns bare `OK` without `* ENABLED` — treat OK as enabled.
  - **No `MOVE`** → COPY + `STORE +FLAGS (\Deleted)` + `UID EXPUNGE`, made idempotent and crash-recoverable.
  - **No `SPECIAL-USE`** → map Sent/Trash/Junk/Archive/Drafts by (possibly localized) name.
  - No `NOTIFY`, no `COMPRESS`, no `LIST-EXTENDED` (no `LIST … RETURN`).
  - `IDLE` only on the selected mailbox; ≤ 3 connections per account; re-IDLE every ≤ 25 min.
  - SMTP: `smtp.mail.me.com:587` STARTTLS only, SIZE ≈ 27 MiB raw, 1000 msgs/day.
  - No Sieve → all rules run client-side.

## 3. Storage (local-first, three tiers) — [ADR 0001](adr/0001-local-first-three-tier-storage.md)

| Tier | Contents | Where |
|---|---|---|
| **1 · Always local** | headers, thread graph, Inbox state, compressed plain-text body, FTS index, embeddings, Highlights | SQLite (GRDB) |
| **2 · Cache** | raw MIME/HTML bodies + attachments opened, plus last 30 days for offline | size-capped LRU folder (default 2 GB) |
| **3 · Remote** | everything else | IMAP server |

- User-selectable storage location (incl. external drive, via security-scoped bookmark). Drive missing → read-only notice.
- Never on iCloud Drive.
- Server is source of truth for mail; sync via CONDSTORE/QRESYNC + IDLE.

## 4. Inbox model

- **Done** (archive move), **Pin**, **Snooze** (time + "someday"), **Bundles**, **Sweep** (Done all non-pinned), **Highlights** — all v1.
- Single stream (Inbox-style): Primary as individual rows; other categories collapse into inline bundles.
- Categories: **Primary, Transactions, Updates, Newsletters, Advertising, Social** + custom bundles (rule- or AI-defined).
- Bundle delivery schedules; Advertising + Newsletters default to scheduled.
- Conversations threaded by `References`/`In-Reply-To` with subject fallback, including Sent. Actions apply to threads. Toggle to message view.
- Global ⌘Z undo for every action.

### Where state lives — [ADR 0002](adr/0002-inbox-state-cloudkit-plus-imap.md)
- Things with IMAP meaning are IMAP: Done → Archive folder, Snooze → `Snoozed` folder, spam → Junk, read/flag → system flags. Other clients stay consistent.
- Rich app state (category, pin, snooze-until, bundle, Highlights, rule history, classifier corrections) → **CloudKit private DB**, keyed by `Message-ID` + account.
- Custom IMAP keywords (e.g. `$Pinned`) mirror simple state for other clients. **Verified usable on iCloud in M0.** CloudKit remains the source of truth.

### Always-on work — [ADR 0003](adr/0003-headless-engine.md)
- v1: a login-item background helper runs sync, rules, snooze wake-ups, send-later and classification while the window is closed; catches up after sleep.
- `MailEngine` is a headless Swift package (no AppKit/UIKit) so it can later run on a Linux server (e.g. Coolify) for 24/7 rules + iOS push.

## 5. On-device AI — [ADR 0004](adr/0004-three-layer-classification.md)

Three layers, cheapest first:
1. **Signals** — `List-Unsubscribe`, `Precedence`, known ESPs, transactional patterns, "have I written to them". Handles the bulk instantly.
2. **Fast classifier** — on-device multilingual embeddings → small trainable head, retrained on corrections. ms per message.
3. **Foundation Models** — only for low-confidence messages, Highlights extraction, NL rule conditions, thread summaries.

- Corrections stick per sender. Every message can show "why it's here".
- Mail is mixed Danish/English; system language is Danish. **M0 verified** Foundation Models is available and supports `da_DK` (6/6 samples correct, ~0.6 s each); Danish contextual embeddings are installed.

### Highlights (v1)
Flights/travel, packages, receipts/invoices, calendar events/invites, OTP/2FA codes, reservations, bills/subscriptions. schema.org JSON-LD first, LLM fallback. Each has an action (add to Calendar, copy code, track, open booking). Global hotkey: copy latest OTP.

### Writing assistance
System Writing Tools in the composer, one-line thread summaries, "Summarize" for long threads, 2–3 smart-reply chips, "extract questions". No full drafting (plugins/MCP can add a bigger model later).

## 6. Rules

- Outlook-style: ordered, conditions + actions, "stop processing more rules".
- Pipeline order: **spam → AI classification → user rules** (rules can read and override category).
- **Natural-language conditions** ("all mails that are about shoes"): embedding pre-filter against stored vectors → Foundation Models yes/no verification on candidates. Cheap structured conditions short-circuit first. Few-shot tuning via ✓/✗ in the preview. Per-rule confidence threshold; uncertain → "maybe" bundle.
- Create rules by typing a sentence → editable rule.
- Actions: move, categorize/bundle, pin, snooze, mark read, forward, auto-reply, notify, run plugin, run Shortcut. NL rules may never hard-delete or forward without confirmation.
- Run on new mail automatically; run on existing mail on demand; every rule has a preview ("would have matched 143").

## 7. Search & smart folders

- Results are **newest-first**, computed in two phases: hits on the keystroke, facets right after (see [M0 results](M0-results.md) for why).
- All four layers: **faceted as-you-type** core (< 30 ms p95), **scope-aware** (current bundle/folder/thread; one key widens), **semantic** second tier (embeddings), **entity-aware** (person card on top when query matches a contact).
- Gmail-compatible operators: `from: to: has:attachment larger: before: after: category: is:pinned in:` + NL criteria.
- Danish + English stemming ("faktura" finds "fakturaer").
- Smart folders = saved searches (⌘S), live counts; built-ins: Attachments, Waiting for reply, Receipts this year.

## 8. Spam & privacy

- Layered on top of iCloud's server filter: Authentication-Results (SPF/DKIM/DMARC/ARC), lookalike-domain & display-name spoofing, link-text/href mismatch, local classifier trained on Junk + corrections, LLM phishing explanations. **No external lookups.**
- Corrections move mail in/out of Junk on the server (trains iCloud's filter too). Uncertain → warning banner, stays in inbox.
- Remote content: strip tracking pixels/links always; auto-load images only for senders you've written to or approved; "3 trackers removed" indicator.
- Avatars: Contacts photo → BIMI logo → domain favicon → monogram. Cached per domain, toggle to disable network avatars.

## 9. Compose & send

- Rich-text editor (`NSTextView`) with Markdown-style input shortcuts; sends clean HTML + text/plain alternative. Quoted text trimmed/collapsed.
- Undo send (default 10 s local outbox), send later (via helper; late-send notice after sleep), follow-up nudges ("bring back if no reply in N days"), snippets/templates (`;keyword`, variables), signatures per identity.
- Identities: primary iCloud + custom-domain addresses. From auto-selected by receiving address; warn on mismatch. **Hide My Email** only after a live SMTP test proves it keeps the alias.

## 10. Notifications

Primary-from-people, pinned threads, rules marked "notify", replies to waiting-for threads. Never per-bundle message; optional quiet bundle-delivery summary (off by default). Focus filters via App Intents. Editable VIP list seeded from correspondence frequency.

## 11. Newsletters, extras

- One-click unsubscribe (RFC 8058, mailto fallback; always confirmed), unsubscribe on bundle rows, **Senders** screen sorted by volume.
- v1 extras: read-later reader mode, mute thread, global undo, attachment browser (Quick Look). Screener available but off by default. Daily review → v2.

## 12. UI

- **Pure Apple: Liquid Glass + SF Pro + system colors.** (Magnus's personal web design system does not apply.)
- Layout: sidebar → stream → reading pane on wide windows; collapses to single column with inline-expanding cards on narrow windows or by hotkey (this is also the iOS layout).
- Category colors (icon + faint row tint only; each also has a distinct SF Symbol): Primary = accent, Transactions `.teal`, Updates `.blue`, Newsletters `.purple`, Advertising `.orange`, Social `.green`.
- Keyboard: Gmail/Superhuman single keys on by default (toggle) + ⌘ equivalents + ⌘K command palette; **every** action keyboard-reachable; shortcuts shown in menus/palette.
- Localization: English + Danish via String Catalogs from line one.

## 13. Extensibility

- v1: modular codebase + App Intents/Shortcuts.
- Plugin API designed (not public yet): JavaScriptCore with declared permissions (headers, bodies, per-domain network, state write). Hooks: rule conditions/actions, classifiers, Highlight extractors, ⌘K commands, reading-pane side panel, message actions. **First-party features are built on the same hooks.**
- MCP server over the local store: v1.x.

## 14. Tech stack

Swift 6 (strict concurrency) · SwiftUI shell · AppKit `NSTableView` for the stream · `WKWebView` (no JS, sandboxed) for message bodies · SQLite via GRDB + FTS5 · Apple **swift-nio-imap** · own SMTP + MIME on SwiftNIO · CloudKit · Foundation Models · NaturalLanguage embeddings. Everything non-UI lives in the `MailEngine` package, shared by macOS, iOS and a possible server.

## 15. Performance budgets (CI, 250k-message synthetic mailbox; >10% regression fails)

| Metric | Budget |
|---|---|
| Cold launch → usable stream | < 400 ms |
| Search keystroke → results | < 30 ms p95 (M0: 6.1 ms @ 250k) |
| Search facets | < 100 ms p95 (M0: 50 ms @ 250k) |
| Open cached message | < 50 ms |
| Done/Pin/Snooze feedback | next frame (optimistic) |
| Scrolling | 120 fps ProMotion |
| Memory | < 300 MB |
| Idle CPU | ~0 |

## 16. Onboarding

App-specific-password walkthrough (link to account.apple.com, live validation, iCloud auto-config) → sync order: INBOX headers last 30 days (usable in ~5–10 s) → those bodies + classification → older mail/folders in background with sidebar progress → optional 60-second "teach me" on ~20 ambiguous messages.

## 17. Distribution

Developer ID + notarized + Sparkle now (sandbox on); Mac App Store later; iOS via TestFlight.

## 18. Testing

- CI/integration: local Dovecot in Docker, with iCloud quirk simulation and replayed iCloud transcripts.
- Live iCloud (no second account exists): a **fenced `Tidings-Test` mailbox** in the real account. Destructive tests only touch messages they `APPEND`ed themselves, carrying an `X-Tidings-Test: <run-id>` header; the harness refuses any mutation outside the fence. Nothing in real folders (incl. Junk) is deleted.
- Anything that logs in to iCloud is run by Magnus (one command; password read from Keychain), not by an agent.

## 19. Milestones

| | Scope |
|---|---|
| **M0 · Engine spike** ✅ | iCloud IMAP connect + quirks, fenced live keyword test, tier-1 store + FTS, Foundation Models/Danish check |
| **M1 · Read-only client** | sync, stream, threads, reading pane, instant faceted search |
| **M2 · Triage** | Done/Pin/Snooze/Sweep, undo, keyboard, ⌘K |
| **M3 · Compose** | SMTP, outbox/undo send, identities, signatures — **daily driver** |
| **M4 · Sorting** | AI categories, bundles + schedules, spam layers, remote-content protection |
| **M5 · Rules** | rules incl. NL, smart folders, semantic search |
| **M6 · Polish** | Highlights, notifications, newsletter/Senders tools, read-later, attachments |
| **M7 · Sync & extend** | CloudKit, plugin hooks hardened, MCP server |
| **Later** | iOS app |
