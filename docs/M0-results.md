# M0 results (2026-11-24)

## Done and verified locally
| Check | Result |
|---|---|
| IMAP layer on swift-nio-imap (`IMAPCommands`) | Login, CAPABILITY re-issue, ENABLE with bare-OK quirk, LIST, SELECT/EXAMINE, APPEND (UIDPLUS), UID SEARCH/FETCH/STORE, MOVE fallback (COPY + \Deleted + UID EXPUNGE) |
| iCloud simulation on Dovecot | MOVE/SPECIAL-USE/NOTIFY/COMPRESS hidden; fallback paths exercised in tests |
| Fenced keyword test | Passes against local Dovecot (persist, 2nd connection, mailbox FLAGS, MODSEQ bump, survives move, 40 extra keywords); fence refuses unmarked mail and mailboxes outside `Tidings-Test` |
| Foundation Models, system language `da-DK` | **Available, `supportsLocale(da_DK) == true`**. 6/6 Danish/English samples classified correctly, ~0.6 s each warm (2.2 s cold) |
| Embeddings | `NLContextualEmbedding` Danish + English assets installed (dim 512). `NLEmbedding.sentenceEmbedding(.danish)` is nil → use contextual embeddings with mean pooling |
| Search, 250k synthetic messages (Zipf vocabulary, mixed DA/EN) | **Hits p95 6.1 ms** (budget 30), **facets p95 50 ms** (budget 100). 1.2 GB on disk incl. compressed text and FTS index |
| Tests | 20 tests (unit + Dovecot integration) pass |

## Live iCloud results (run by Magnus)
| Check | Result |
|---|---|
| Login | Full `@icloud.com` address + app-specific password works; custom-domain address does not |
| Capabilities | CONDSTORE, QRESYNC, IDLE, UIDPLUS, ESEARCH, LIST-STATUS present; MOVE, SPECIAL-USE, COMPRESS, NOTIFY, LIST-EXTENDED absent |
| Folders | All 7 resolved; `\Sent`/`\Trash` attributes sent despite no SPECIAL-USE |
| Keyword test | **Usable**: persists, cross-connection, MODSEQ bump, survives move, 40+ per message (see ADR 0002) |
| Quirks found live | `LIST "" ("*")` → OK with zero mailboxes; `UID SEARCH HEADER` → `NO [UNAVAILABLE]`. Both fixed and covered by tests |

## Design changes M0 forced
1. **Search is newest-first, in two phases.** The FTS rowid is a `SortKey` (date seconds | category | attachment bit | disambiguator), so FTS5 streams matches in date order and stops at the limit, and category/attachment/date filters and facets read the rowid without joins. Ranking all matches by bm25 was 600–800 ms per keystroke; this is ~3 ms.
2. **Facets are phase 2** (after hits render) and are skipped for a lone 1-character prefix.
3. **`from:`/`to:`/`subject:` are FTS column filters**, not `LIKE` scans (490 ms → 10 ms).
4. **LLM classification is ~0.6 s/message** → 100k messages would take ~17 h through the LLM alone. Confirms ADR 0004: signals + fast classifier must handle the bulk.

## Open for M1
- Check that Apple Mail / iCloud.com preserve our keywords when they change read/flag state.
- **Relevance:** newest-first ranks "The weekly update" above "Din faktura fra Zalando" for `faktura`. Add a small "best matches" strip (subject/sender-column query) above the chronological list.
- Danish stemming beyond prefix matching (e.g. "køb" ↔ "købte") — evaluate a Snowball-style tokenizer.
- Embedding storage (512-dim → int8 ≈ 128 MB per 250k) and the semantic tier.
- Sync engine (CONDSTORE/QRESYNC + IDLE), MIME parsing, and the app shell.
