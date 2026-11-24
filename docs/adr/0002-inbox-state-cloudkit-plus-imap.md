# 0002 · Inbox state: IMAP semantics + CloudKit

**Status:** accepted · 2026-11-24

## Context
Done/Pin/Snooze/category/bundle state has to survive reinstall and sync to a future iOS app. iCloud IMAP advertises `PERMANENTFLAGS (... \*)` but nobody has publicly proven arbitrary third-party keywords persist and are visible to other clients. Other clients (Apple Mail on iPhone, iCloud.com) should still see a sensible mailbox.

## Decision
- Actions with an IMAP meaning are expressed in IMAP: Done → Archive folder, Snooze → `Snoozed` folder, spam → Junk, read/flagged → system flags.
- Rich state (category, pin, snooze-until, bundle membership, Highlights, rule history, classifier corrections) → CloudKit private database, keyed by account + `Message-ID` (fallback: hash of Date+From+Subject).
- Custom IMAP keywords (`$Pinned`, …) are written as a cross-client mirror of simple boolean state (pinned, category tag). **CloudKit stays the source of truth.**

## Live result (M0, 2026-11-24, Magnus's iCloud account)
Fenced keyword test on `imap.mail.me.com`:
- `PERMANENTFLAGS` includes `\*`
- `$TidingsPinned` persisted, visible from a second connection, MODSEQ 3570 → 3571
- Survived a move (COPY + UID EXPUNGE)
- 40 extra keywords accepted on one message, no cap hit
- Not added to the mailbox `FLAGS` list (fixed list on iCloud; informational only)

→ Keywords are usable. They still don't replace CloudKit: they can't carry values (snooze-until, Highlights, rule history), and other clients such as Apple Mail may replace a message's whole flag set (`STORE FLAGS`). Whether Apple Mail and iCloud.com preserve foreign keywords when changing read/flag state is **untested**. Check it in M1 by toggling read/flagged on a keyword-tagged test message in Apple Mail and re-fetching.

## Consequences
- Requires paid Apple Developer membership (available).
- Works for any IMAP provider, not just iCloud.
- Message-ID is not guaranteed unique; collisions are resolved per account with a secondary hash.
