# 0002 · Inbox state: IMAP semantics + CloudKit

**Status:** accepted · 2026-11-24

## Context
Done/Pin/Snooze/category/bundle state has to survive reinstall and sync to a future iOS app. iCloud IMAP advertises `PERMANENTFLAGS (... \*)` but nobody has publicly proven arbitrary third-party keywords persist and are visible to other clients. Other clients (Apple Mail on iPhone, iCloud.com) should still see a sensible mailbox.

## Decision
- Actions with an IMAP meaning are expressed in IMAP: Done → Archive folder, Snooze → `Snoozed` folder, spam → Junk, read/flagged → system flags.
- Rich state (category, pin, snooze-until, bundle membership, Highlights, rule history, classifier corrections) → CloudKit private database, keyed by account + `Message-ID` (fallback: hash of Date+From+Subject).
- Custom IMAP keywords (`$Pinned`, …) are added *only* as a cross-client nicety if the fenced live keyword test (M0) passes.

## Consequences
- Requires paid Apple Developer membership (available).
- Works for any IMAP provider, not just iCloud.
- Message-ID is not guaranteed unique; collisions are resolved per account with a secondary hash.
