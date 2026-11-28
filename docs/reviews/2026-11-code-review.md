# Code review and refactor — November 2026

A full review of MailEngine, the push server and both apps, followed by a refactor towards
self-explaining code: names over narrating comments, long functions split into named steps,
magic values named, duplication removed, comments kept for intent (the *why*: RFCs, server
quirks, product decisions, safety rules). Behaviour was kept, except for the bug fixes listed
below. Public MailEngine API is source-compatible (only additions).

Each area section below lists strengths, then findings by severity, each marked **FIXED** or
**NOT FIXED** with the reason. Line numbers refer to the code before the refactor unless noted.

## Verdict

The codebase was already in good shape: a clear engine/app split, careful sync design
(CONDSTORE/QRESYNC with UID-set fallback, optimistic triage with provisional UIDs, folder
generations), parameterised SQL throughout, and comments that mostly explained *why*. The main
structural debts were very long functions (`syncMailbox` ~170 lines, `AppModel.reload`,
`CloudSync.handleEvent`, the 200-line command list, menu definitions), a god object
(`AppModel`, ~90 stored properties), copy-pasted helpers, and unnamed numbers. The review also
found a handful of real bugs, several of them security-relevant in how untrusted mail is handled.

## Bugs fixed

Security / safety
- **Header injection in outgoing mail** (`Compose/MIMEBuilder.swift`): CR/LF in a reply's
  subject, a forwarded filename, display names or ids could add headers. All header text is now
  single-line. Tested.
- **SMTP command injection** (`Compose/SMTPClient.swift`): envelope addresses with CR/LF are
  refused; the reply reader stops after 64 KiB without a line break.
- **TestFence could vouch for the wrong mailbox** (`IMAP/TestFence.swift`): STORE/MOVE act on the
  selected mailbox, but the fence checked the named one. It now refuses unless they match. Tested.
- **Remote images for look-alike senders** (`Classify/RemoteContent.swift`, `JunkFilter.swift`):
  "have I written to them" was a LIKE substring match (`%@%` matched everyone). Now exact, with
  wildcards escaped. Tested.
- **Crafted invite could crash sync** (`Calendar/CalendarInvite.swift`): huge BYDAY/BYMONTH
  overflowed. Range-checked now. Tested.
- **Line breaks in invite replies** (`Calendar/CalendarReply.swift`). Tested.
- **Out-of-bounds read** on stored embeddings of a different length (`Classify/Refinement.swift`)
  and on empty vectors (`Support/VectorMath.swift`).

Correctness
- A failed Sent copy after a successful send dropped the connection and skipped marking the
  original \Answered (`Sync/AccountSync+Outbox.swift`).
- Server turns between queue draining and folder changes weren't handed out in order.
- `deleteMailbox`/`deleteMessages` each ran as two transactions.
- A sync loop could outlive a removed account (`AppModel.start`).
- Cancelling a send-later on the push server with no running sync left the message queued.
- A rule run was looked up as "latest run", racing other accounts.
- `RichTextEditor` coordinators kept a stale binding.
- The AI category editor doubled its "Name:" prefix on each save.
- "Summarizing…" could stick when the conversation changed mid-run.
- Search timing ignored whole seconds; quiet triage, Undo and a smart-folder save on folder
  rename swallowed errors; plaintext-IMAP hosts weren't lowercased.

## Recommended next steps (not done: behaviour, product or API decisions)

1. **Signature HTML sanitiser** is regex-based and bypassable (`<img/onerror>`, entity-encoded
   `javascript:`, `data:`). Use an allow-list sanitiser.
2. **Links from JSON-LD/highlights** aren't scheme-checked; the app should open only http(s).
3. **Mac EHLO** sends the computer name (leaks the owner's name; not a valid hostname). Use
   `[127.0.0.1]` as iOS/Linux do.
4. **Push server**: a retried send-later PUT during sending can queue twice; the pairing rate
   limit is global (lockout by anyone who can reach it); one undecryptable password stops
   `start()` for all accounts; sealed passwords aren't bound to their account (no AAD).
5. **Signature rendering** can stall forever if WebKit never calls back (needs a timeout).
6. **Pull-to-refresh** decides "done" by comparing a localized status string.
7. **AppModel** is a god object; extract search first. Many store writes still use `try?`.
8. **Cloud apply**: each `messageState` record re-runs a full reassert pass (quadratic), and
   apply + bookkeeping aren't one transaction.
9. **API names**: `MailSession.qresyncEnabled` is also true for CONDSTORE only;
   `ServerProfile.requiresCapabilityAfterLogin`/`maxConnections` are never read.
10. **Tests**: the app has no test target, so pure helpers there (HTML export, list formatting,
    app-password parsing, invite formatting) are untested.

## Verification

- MailEngine on Linux (Swift 6.2): builds clean, all tests pass (273 before → 278 after, the
  new ones being regression tests for the fixes above). Integration tests self-skip without
  Dovecot.
- Push server on Linux: all tests pass.
- Apps: no Xcode was available, so the apps were not compiled here. Every App file passes a
  Swift 6 syntax parse, symbol references were checked by hand, and string literals, keyboard
  shortcuts and accessibility modifiers were diffed against the old code. macOS CI is the first
  full compile of the App changes.

---

## Review: engine-sync (`MailEngine/Sources/MailEngine/{Sync,IMAP,Store}`)

Line numbers are from the baseline (before the refactor) unless marked "now".

### Strengths

- **The sync state machine is carefully reasoned.** `syncMailbox` takes MODSEQ/UIDNEXT/EXISTS
  from the SELECT *before* reading anything, so a change that lands during a pass is fetched
  again next time and never lost. A message held back by a queued action keeps the old MODSEQ.
  The CONDSTORE path checks counts and falls back to comparing UID sets, which also repairs
  local drift. A QRESYNC server that refuses VANISHED is downgraded for the session.
- **Optimistic triage is well designed.** Each action is applied locally and enqueued in one
  transaction. Rows get provisional UIDs until COPYUID arrives. Undo is a cancel while the action
  is still queued and an inverse action afterwards. `drainLocked` holds back later changes to the
  same messages after a refusal, so changes can't overtake each other, and one dropped connection
  doesn't use up every change's tries.
- **Folder changes are safe against a sync in progress.** `folderGeneration` makes a stale
  listing restart its pass, and the server turn (`acquireServer`) makes a queued move land before
  its folder is renamed or deleted.
- **The safety fence is real.** `TestFence` checks both the mailbox and a per-run marker header
  before every mutation, and the move fallback won't run a blanket EXPUNGE without UIDPLUS.
- **The SQL is parameterized throughout.** Only constants, ints and generated placeholder lists
  are interpolated. The FTS5 index is contentless, and its rowid layout lets filters read the
  rowid without a join (SortKey).
- Comments mostly explain *why*: RFC references, iCloud quirks with dates, and product
  decisions. That is the right instinct; the problems were mostly comments that narrate.

### Findings (by severity)

#### High

1. **TestFence could vouch for the wrong mailbox.** `IMAP/TestFence.swift:93` (`checkMarked`)
   checked that the *named* mailbox is inside the fence, then searched the *selected* mailbox for
   marked UIDs, and STORE/MOVE act on the selected mailbox. A caller could pass
   `in: "Tidings-Test"` while INBOX was selected. Rule 2 (the marker) still held, but rule 1 (the
   mailbox) was bypassed. **FIXED**: the fence now refuses unless the selected mailbox is the one
   named, using a new `Violation.mailboxNotSelected` case. This strengthens the fence; nothing in
   the repo switches over `Violation` exhaustively. KeywordTest and IMAPIntegrationTests already
   select before they act.
2. **A failed Sent copy aborted the sync loop and lost the \Answered mark.**
   `Sync/AccountSync+Outbox.swift:498-503`: the outbox row is deleted (correctly: never resend),
   then `fileSentCopy` throws, for example on a network blip during APPEND or a failed CREATE.
   That skipped `markOriginal`, so the reply never marked the original \Answered, and the whole
   connection reconnected. **FIXED**: the failure is logged and the loop carries on to
   `markOriginal`. Cancellation still propagates. A connection that is really broken still fails
   at the next `drain`.

#### Medium

3. **Server turns were not FIFO (barging).** `Sync/AccountSync.swift:100-110`: `releaseServer`
   cleared `serverBusy` and then resumed a waiter. A task that arrived between the release and
   the waiter's resumption could take the turn, and the woken waiter went to the back of the
   queue. That was correct (the `while` re-checked) but starvable. **FIXED**: the turn is handed
   straight to the next waiter.
4. **Some multi-step store mutations were not atomic.** `Store/MailStore+Sync.swift:156-174`:
   `deleteMailbox` deleted messages in one transaction and the mailbox state in another, and
   `deleteMessages` read ids in one transaction and deleted them in another. A crash in between
   left a state row whose messages were gone, so the next pass trusted a MODSEQ for an empty
   mailbox. **FIXED**: each now runs in a single `db.write`.
   `MailStore.renameMailbox` (now in `Store/MailStore+Folders.swift`) still deletes stale states
   before its write transaction. **NOT FIXED**: `deleteMailbox` opens its own write, and GRDB
   writes don't nest. A fix needs a `deleteMailboxIn(db)` variant, which can come later.
5. **The wake continuation outlived a failed IDLE.** `Sync/AccountSync.swift:185-190`:
   `setWake(nil)` ran only when IDLE returned normally. After a throw, the next `signalWork`
   yielded into a dead stream until the next IDLE replaced it. That was harmless but sloppy.
   **FIXED** with `defer`.
6. **Swallowed errors.**
   - `run()` used `try? store.resetInterruptedSends`. A failure here strands outbox rows in
     `sending` forever. **FIXED**: the failure is now logged. Behavior is unchanged: the loop
     still runs.
   - `drainLocked` silently deleted actions that no longer decode. **FIXED**: they are now
     logged.
   - `OutboxItem.message`'s setter and `init` swallow JSON encode failures and would store an
     empty payload (`Store/MailStore+Outbox.swift:270-279`). **NOT FIXED**: this is public API,
     and encoding a plain Codable struct can't fail in practice.
   - The `try?` calls left in place are deliberate best-effort paths, now commented where that
     wasn't obvious: the cache write, the keyword read-back, the invite answer, `preferFullest`'s
     SELECT, and logout.
7. **The provisional UID can collide.** `Store/MailStore+Triage.swift:103`: it is
   `base + (id & 0x0FFF_FFFF)`, so two rows whose ids differ by 2^28 that move into the same
   mailbox would hit the `(accountID, mailbox, uid)` unique key. **NOT FIXED**: this is
   theoretical at mail volumes. The value is now named (`provisionalUID(forRow:)`) so the limit
   is visible.

#### Low / design

8. **God function `syncMailbox`** (~170 lines, `Sync/AccountSync.swift:318-481`). **FIXED**: it
   is now a ~45-line outline in the new `Sync/AccountSync+Mailbox.swift`, made of named steps:
   `savedState`, `modSeqToSyncFrom`, `isUnchanged`/`recordSkippedPass`,
   `fetchChanges` (QRESYNC→CONDSTORE fallback), `compareUIDSets`, `fetchFullList`,
   `applyFlagChanges`, `storeNewMessages`/`fetchBodies`, and `makeMessage` split into
   `recordOwnInviteAnswer` and `isOwnAddress`. A `MailboxDelta` value carries a pass's findings
   instead of three loose `var`s plus a `heldBack` flag.
9. **The `run` loop** (nested closure ~50 lines). **FIXED**: it is split into `run` (reconnect
   and backoff), `stayInStep` (the connected loop), `idleUnlessWorkIsWaiting`, and
   `pushLocalWork` (snoozes → outbox → queue). The last was repeated 3× across `run` and
   `catchUp`.
10. **`syncAll`** mixed layout learning, role resolution, mailbox selection and pruning.
    **FIXED**: it now uses `learnFolderLayout`, `mailboxesToSync` and `forgetMailboxes(missingFrom:)`.
11. **`perform`** (~110 lines, nested switches, `fatalError("unreachable")`). **FIXED**: it is
    split into `performMove`/`movePlan` (a `MovePlan` value) and
    `performFlagChange`/`flagEdit`. `newestMessageIDs(of:)` replaces three copies, and
    `snoozeKeywords(in:)` replaces two. The three different conditions for when to call
    `noteMessageState` (across move, flag and undo) became one `TriageKind.changesRecordedState`.
12. **`execute`** mixed target spelling, local relabelling, the move, flags and keyword
    detection. **FIXED**: it is now `executeMove`, `serverSpelling(of:)`, `executeFlags` and
    `learnWhetherKeywordsStick`.
13. **Responsibilities were in the wrong place.** Raw SQL and `MailStore` extensions lived in
    Sync files (`AccountSync+Triage.swift:492-544`, `AccountSync+Folders.swift:322-402`, the
    inline `UPDATE`s in `undo`/`execute`/`wakeDueSnoozes`). **FIXED**: they moved to `Store/`
    (`MailStore+Triage.swift`, the new `MailStore+Folders.swift`) as named operations:
    `restoreSnoozeState`, `relabelMailbox`, `threadIDs(localIDs:)`, `applyMoveResult`. Separately,
    `MessageCache` and `AccountConfig` moved out of `AccountSync.swift` into their own files. The
    cache's folder helpers came along, sharing one `mailboxDirectory`, and the account-path guard
    was unified.
14. **Duplication.**
    - Deleting a row together with its FTS entry was written twice (`MailStore.delete(ids:)` and
      `deleteRowsIn`).
    - Snapshot row mapping was written twice (`snapshots` and `snapshotsIn`).
    - The IMAP body-section byte collection was written twice (`fetchRaw` and `fetchHeaderField`).
    - The all-UIDs set was built three times.
    - Logout was written twice.
    - The `\Noinferiors`/`\Noselect` checks were written twice each.
    - Auto-draft retirement was written twice.
    - The `"?"` placeholder list was hand-built 13 times, and the `stride(by: 500)` chunking four
      times.

    **FIXED**: these are now `deleteRowsIn`, `snapshotsIn`, `bodySections(in:)`,
    `uidSet(from:)`/`uidSetOrAll`, `logOut`, `MailboxListing.has(attribute:)`/`isSelectable`/
    `canHoldSubfolders`, `retire(_:in:)`, and `Collection.sqlPlaceholders`/`sqlBatches()`/
    `chunks(of:)` in the new `Store/SQLBatching.swift`, which uses GRDB's
    `databaseQuestionMarks`.
15. **Magic values.** **FIXED**, each now named:
    - Sync loop and backoff: 5 s / 300 s / 1 s minimum IDLE / 600 s poll, now
      `defaultPollInterval` (public, additive).
    - Outbox retry: 6 attempts, 30 s doubling to 3600 s.
    - Server-copy checks: 2/4/6 s.
    - Fallback folder names (`Archive`, `Deleted Messages`, `Junk`, `Sent Messages`).
    - `$Forwarded` and `(no subject)`.
    - `2 << 30` cache limit and `86_400`.
    - Preview length 160 and the SortKey category mask `& 7`.
    - The `removeFirst(6)` in `MailboxRoleResolver`.
    - Folder name limit 200 and the 230 wpm reading speed.
    - Assist's heuristics (6 recipients, 40 chars, ×3/×4 overfetch, first 3 To addresses,
      LIMIT 5/6/200, ≥3 samples).
    - KeywordTest's keyword and cap-probe default, and TestFence's synthetic body.
16. **Dead or false code.**
    - `ReadingText`'s `trimmed == "-- "` could never match, because the line had already been
      trimmed.
    - `summaries(latest:)` had a pointless `do { }` wrapper.
    - `allOrSome` was marked `throws` but never threw.
    - `setWake` was a trivial setter.
    - `import GRDB` in the Folders file was unused.
    - `qresyncEnabled`'s doc comment described `enableExtensions`.
    - `MailboxRoleResolver.resolve`'s doc referred to a "preference order" that doesn't exist.
    - `MessageSummary` counts used positional tuples (`c.0`).

    **FIXED**.
17. **Per-message work that should be per-pass.** `makeMessage` loaded `highlightTraining()`
    from the database for *every* new message, and every pass computed `correspondentDomains`
    even when nothing was new. **FIXED**: a `MessageContext` is built once per pass, and only
    when the pass has new mail.
18. **`lastPass` was `public private(set)`**, which would have forced `syncMailbox` to stay in
    one file. It is now `public internal(set)`. The public getter is unchanged, so this is
    source-compatible.

#### Recommendations (public API, NOT changed)

- `MailSession.qresyncEnabled` is true when only CONDSTORE was enabled. A better name is
  `extensionsEnabled`; it is used by tidings-probe and a test.
- `ServerProfile.requiresCapabilityAfterLogin` and `maxConnections` are read nowhere: the
  CAPABILITY call after login is unconditional, and there is no pool. Either honour them or drop
  them.
- `IMAPDiagnostics.echo` is a `nonisolated(unsafe) static var`. Setting it while another task
  logs is a data race. A `Mutex` would make it sound.
- `PendingAction.action` and `OutboxItem.message` decode with `try?`. A typed error, or at least
  a log, would make corruption visible.
- `MailboxState.highestModSeq` stores `UInt64` as `Int64(bitPattern:)`. That is correct but
  surprising. A `DatabaseValueConvertible` wrapper would localise the trick.

#### Test gaps

- No unit test covers `acquireServer`/`releaseServer` ordering, or the new hand-off.
- No test covers the Sent-copy failure path in `sendDue`. It needs Mailpit plus a refusing
  IMAP APPEND.
- `TestFence`'s new "selected mailbox" check is covered indirectly: KeywordTest and the
  integration test still pass because they select first. A dedicated negative test (name
  `Tidings-Test` while INBOX is selected) would pin it. It needs Dovecot, so it would self-skip
  here.

---

## Review: engine-content (MIME, Compose, Calendar, Highlights, Classify)

Scope: `MailEngine/Sources/MailEngine/{MIME,Compose,Calendar,Highlights,Classify}/**` (22 files, ~5,700 lines)
and the tests that exercise them.

### Strengths

- **Built to survive real mail.** `MIMEParser` never throws. It falls back on every step: an unknown
  charset becomes UTF-8 and then Latin-1/CP1252, a missing boundary becomes a single part, a bad
  encoded word stays as written. Mislabelled ISO-8859-1 is decoded as CP1252. Base64 is decoded
  leniently, base64url included.
- **Byte-level MIME splitting.** Parts are `ArraySlice<UInt8>` all the way down, so nothing is
  decoded until it is needed and there are no extra copies. Multipart nesting is capped at 20 levels.
- **7-bit-clean output.** The builder writes QP text, base64 binaries, RFC 2047 headers and RFC 2231
  filenames. Bcc is kept out of the headers. SMTP refuses to send the password in the clear when
  STARTTLS is missing, re-reads EHLO after TLS (RFC 3207), puts a timeout on every reply, and refuses
  a partial delivery.
- **The Linux rule is followed.** Apple-only APIs (CFString charsets, NaturalLanguage,
  FoundationModels, `Host`) sit behind `#if canImport`/`#if os` with fallbacks. The literal NBSP in
  the `HTMLText` regex follows the CLAUDE.md rule.
- **Calendar handling is careful.** It covers Windows zone names, the calendar's own VTIMEZONE rules,
  floating times, UTC midnights for all-day events, and replies that echo UID/SEQUENCE/RECURRENCE-ID
  exactly.
- **Privacy by default.** Phishing checks, the junk filter, event extraction and classification all
  run on the device. Tracking pixels are stripped whatever the image setting.
- **Tests.** Most behaviour has focused Swift Testing coverage, with round trips through our own parser.

### Findings (by severity)

#### High

1. **Header injection in outgoing mail.** `Compose/MIMEBuilder.swift` (`build`, `address`,
   `attachmentPart`; `encodeHeader` returned ASCII input unchanged). Header text that comes from
   received mail is written out without filtering. Two examples: the `Re:` subject, which
   `EncodedWords.decode` decodes and may contain CRLF, and the decoded filename of an attachment that
   is forwarded via `MIMEParser.attachments(in:)`. Display names, Message-ID, In-Reply-To/References,
   MIME type and Content-ID are written the same way. An attacker who sends
   `=?utf-8?B?<base64 "x\r\nBcc: …">?=` can add headers, or even a body, to the reply or forward the
   user sends. **FIXED:** all header text now goes through `MIMEBuilder.singleLine` (CR/LF become
   spaces), and `encodeHeader` does the same. Covered by the new test
   `lineBreaksInHeaderTextCannotInjectHeaders`.
2. **Crafted invite crashes the app (integer overflow trap).** `Calendar/CalendarInvite.swift`,
   `TimeZoneResolver.onset`. `BYDAY=-100000000000000SU` overflowed `(-n - 1) * -7 * 86_400`, and
   `BYMONTH=Int.max` overflowed `month + 1`. Both values come from any received `.ics`, and they are
   parsed during sync. **FIXED:** the ordinal must be within the RFC 5545 range of ±53, and the month
   within 1…12. The step was also split into `ruleParts` and `nthLastWeekday`. Covered by the new test
   `craftedTimeZoneRulesDoNotCrash`.
3. **Remote images load for look-alike senders.** `Classify/RemoteContent.swift`,
   `allowsRemoteImages`. The rule was `lower(recipients) LIKE '%sender%'`, with the sender unescaped.
   `ob@example.dk` matched a message you sent to `bob@example.dk`. Worse, a From of `%@%` matched every
   message you ever sent, so tracking images loaded and leaked your IP. **FIXED:** the new
   `MailStore.hasWritten(to:from:in:)` escapes the LIKE wildcards and confirms the exact address with
   `AddressParser`. Covered by the new test `imagesNeedTheExactAddressNotASubstring`.

#### Medium

4. **Junk-filter protection by substring.** `Classify/JunkFilter.swift`, `hasWrittenTo`. It used
   `instr(lower(recipients), address)`, so any sender whose address is a substring of a correspondent's
   address was never moved to Junk. **FIXED:** it now uses the same exact-match helper as finding 3.
5. **Line breaks in iTIP reply parameters.** `Calendar/CalendarReply.swift`, `property`. The CN of a
   received invite is TEXT-unescaped, so `\n` becomes a real line break. That break was written into
   our REPLY and started a new content line. **FIXED:** the new `parameterValue` turns line breaks into
   spaces (RFC 5545 §3.2 forbids control characters in parameter values). Covered by the new test
   `replyKeepsTheOrganizerNameOnOneLine`.
6. **SMTP command injection through envelope addresses.** `Compose/SMTPClient.swift`, `deliver`.
   `MAIL FROM:<\(from)>` and `RCPT TO:<\(recipient)>` were sent verbatim, so a CR/LF in an address
   would start a new SMTP command. **FIXED:** `isSafeEnvelopeAddress` rejects such an address before
   anything is sent, using the existing `.rejected(command:code: 0, …)` shape. No new error case was
   added, so the public enum stays source-compatible.
7. **Out-of-bounds read in refinement.** `Classify/Refinement.swift`, `run`. Stored embedding vectors
   were passed to `SoftmaxClassifier.predict` without a length check. `VectorMath.dot` reads exactly
   `dimension` floats through raw pointers. A vector saved by an older or different embedding model
   (an OS update can change `NLContextualEmbedding.dimension`) is read past its end. Training data was
   already filtered by dimension; the candidates were not. **FIXED:** a guard on `vector.count`.
8. **The SMTP decoder buffered without bound.** `SMTPResponseDecoder.channelRead`. A server that never
   sends CRLF could fill memory until the 60 s timeout ran out. **FIXED:** past 64 KiB without a line
   break, the decoder fails with `.notSMTP` and closes (RFC 5321 caps a line at 512 octets).
9. **The EHLO name leaks the Mac's name and can be invalid.** `SMTPClient.swift`, `ehlo`. On macOS the
   EHLO name is `Host.current().localizedName` (for example "Magnus’s-MacBook-Pro"). It reveals the
   owner's name to every SMTP server and can contain non-ASCII characters and an apostrophe, which RFC
   5321 does not allow in a domain. **NOT FIXED:** changing it is a product decision and would change
   behaviour. Recommendation: use `[127.0.0.1]` everywhere, as iOS and Linux already do.
10. **The signature sanitizer can be bypassed.** `Compose/Signature.swift`, `SignatureHTML.sanitize`.
    It is regex based. It misses event handlers separated by `/` (`<img/onerror=…>`), entity-encoded
    schemes (`jav&#x61;script:`), `data:` URLs in `href` and unclosed `<script`. Signatures are your
    own pasted content, so the risk is limited to pasting hostile HTML. The App's editor web view should
    not run scripts in any case. **NOT FIXED:** a real fix is an allow-list or DOM-based sanitizer,
    not a refactor.

#### Low

11. **Unreachable `redacted:` parameter.** `SMTPConnection.command(_:redacted:)`. Nothing logged, so
    the redaction never happened, but the parameter suggested it did. **FIXED:** removed. AUTH is now
    in `authenticate` with an `expectAuth` helper.
12. **Inconsistent session teardown.** `SMTPClient.verify` closed through
    `defer { Task { … close() } }`, which is unstructured and fire-and-forget, while `send` closed
    inline. **FIXED:** both go through `withSession`.
13. **Fragile SIZE parsing.** `split(separator: " ")[1]` was safe only because the decoder trims
    whitespace. **FIXED:** `sizeLimit(in:)` reads it safely.
14. **False doc comment.** `RemoteContent.stripTracking` said "nil if the URL can't be parsed", but it
    returns the link unchanged in that case. **FIXED:** the comment now describes what happens.
15. **Dead code.** `extractingImages` had a `counter` variable that was never read. **FIXED:** removed.
16. **The QP soft break can leave a leading "." unencoded.** `MIMEBuilder.quotedPrintable`. A "."
    that lands at the start of a line after a soft break is written as is. SMTP dot-stuffing
    (`dataPayload`) covers it, so this only matters for robustness. **NOT FIXED:** fixing it would
    change the bytes we produce, for no correctness gain.
17. **Remote-image counting is incomplete.** `RemoteContent.isTracker` and `attribute`. `\bwidth`
    also matches `max-width=` and `\bsrc` matches `data-src`. Remote images are counted only from
    `<img src="http…">`, so `srcset`, CSS `url()` and protocol-relative `//host` are missed. The App's
    web view should enforce blocking anyway; the count is only a hint. **NOT FIXED** (heuristic; out of
    refactor scope).
18. **Possible quadratic time in HTML regexes.** `HTMLText.toPlainText`,
    `PhishingCheck.mismatchedLinks` and `SchemaOrgEvents.scriptPattern` use lazy `[\s\S]*?</tag>` or
    `(.*?)</a>`. Many unclosed openers make these O(n·k). Bodies are usually small. **NOT FIXED.**
    Consider capping the HTML length before these passes.
19. **Unvalidated URLs.** `Highlights.swift` and `SchemaOrgEvents`. The URLs that highlights and
    suggestions carry come from the sender's JSON-LD and are not checked for scheme. Any scheme
    (`javascript:`, `file:`) reaches the App. **NOT FIXED:** the App should open only http(s).
    Recommend a small `isWebURL` filter in the engine.
20. **Fixed 0.5 when there are no clues.** `JunkFilter.score`. The neutral value is a constant, which
    is fine. **NOT FIXED.**
21. **Possible unaligned read.** `Refinement.floats` uses `bindMemory(to: Float16.self)` on `Data`
    bytes, which assumes alignment. SQLite blobs are malloc-aligned in practice. **NOT FIXED** (note
    only). `loadUnaligned` would be strictly correct.

#### Design, naming and readability (all FIXED unless noted)

- `MIMEParser.collect` took five `inout` parameters and one branch did seven jobs. It is now the
  `BodyCollector` struct, with named steps `collectMultipart`, `collectReaction`, `isCalendar` and
  `collectText`.
- The `isAttachment` and Content-ID trimming logic was duplicated between `collect` and
  `attachments(in:)`. It is now `Entity.isAttachment` and `Entity.contentID`.
- The `EncodedWords` regex was compiled on every call. It is now a `static let`, as are the
  `ReactionDetector` `<img>` regex and `PhishingCheck.brandDomains` (a computed property that rebuilt a
  `Set` on every evaluation).
- `MIMEBuilder.bodyPart` built the text/html part twice (once for the plain alternative, once again
  for the calendar case). It now builds one list of alternatives, and the shared
  `Part.quotedPrintableText` is also used by `reactionPart`. The `rfc2231Safe` set was a roundabout
  `alphanumerics ∪ … − æøå ∩ ASCII`; it is now the explicit attr-char set, with identical behaviour.
- `quotedPrintable` decided what to encode inline. That is now `quotedPrintablePiece`, with the RFC
  rule in its doc comment.
- Magic numbers became named constants: header and QP line lengths and the encoded-word size; the
  SMTP timeouts; the event extractor's gaps, grace period, look-ahead, recap window and lengths; the
  scanner's context and title limits; reaction limits; phishing score thresholds and the number of
  link mismatches reported; the minimum number of training examples; the default restaurant booking
  length; and `ICalDuration.secondsPerDay` in place of the many `86_400`s.
- Long functions are split:
  - `TextDates.hits` → `joiningDatesAndTimes` and `Hit.joined(withTimeOf:)`. The two merge branches
    were near-duplicates.
  - `TextDates.suggestion` → `interval`, `isPlausible`, `sentDayStart` and `confidence`.
  - `TextDates.title` → `titleBeforeDate` and `title(fromSubject:)`.
  - `SchemaOrgEvents.suggestion` (70 lines) → `flight`, `lodging`, `restaurant` and `event`, with a
    `Booking` value. This also removes the `number_` name.
  - `PhishingCheck.evaluate` and its numbered narration comments → `Sender`, `authenticationFailures`,
    `brandImpersonation`, `foreignAddressInDisplayName`, `lookalikeDomain` and `replyToElsewhere`.
  - `EventScanner.scan` → `isScanned` and `extractSuggestions`.
- Each `TextDates` and `SchemaOrgEvents` site rebuilt its own UTC `Calendar`. They now use
  `TimeZoneResolver.utc`. The odd double-calendar `sentDayStart` closure is now a named method that
  does the same thing.
- The `NSRange(location: 0, length: (s as NSString).length)` boilerplate in `EventExtractor` is now two
  file-private helpers, `firstMatch(inWhole:)` and `deletingMatches(in:)`.
- `HighlightExtractor.flatten` was a byte-for-byte copy of `SchemaOrgEvents.flatten`. One copy remains.
- `OutgoingMessage.escapeHTML` re-implemented `SignatureHTML.escape`. It now reuses it.
- `SignatureHTML.linkMentioned` computed `bare(text)` four times. It now computes it once.
- **NOT FIXED (recommendations):**
  - There are three slightly different HTML `attribute(_:in:)` helpers (`ReactionDetector`,
    `SignatureHTML`, `RemoteContent`). Their word-boundary rules (`\s` vs `\b`) and entity decoding
    differ, so merging them would change behaviour. Worth unifying deliberately, together with
    finding 17.
  - `HighlightExtractor.string/types` and `SchemaOrgEvents.string/types` overlap but differ on
    purpose.
  - `ICalendar.parseLine` is a hand-written scanner. It reads clearly enough; its "// Name." markers
    are harmless.

#### Public API notes (left unchanged, recommendations only)

- `MIMEBuilder.encodeHeader` is public but is an implementation detail. Nothing outside the engine
  uses it.
- `RiskLevel` uses a hand-written `<`. That is fine, but it could derive `Comparable` from `rawValue`
  via an extension.

#### Test gaps

- The new tests cover findings 1, 2, 3 and 5.
- Still untested: the SMTP envelope check and the oversized-line limit. Their tests need a fake server
  (only Mailpit is allowed), and `deliver` is otherwise covered by the Mailpit integration tests.
- Still untested: the refinement dimension mismatch, deeply nested multipart (depth cap), and RFC 2231
  continuations with missing pieces.

---

## Review: engine-rest

Scope: `MailEngine/Sources/MailEngine/{Rules,Search,Cloud,Notify,AI,Assist,Accounts,Push,Categories,Support}`,
`Version.swift`, `tidings-probe`, `PushServer/Sources` + `PushServer/Tests`.

### Strengths

- **Push server security basics are right.** Device tokens are 32 random bytes, shown once, stored only as
  SHA-256 and looked up by hash (no timing oracle on a high-entropy secret). The pairing secret is compared
  with a constant-time compare over SHA-256 digests (`Tokens.matches`), failed pairings are rate-limited,
  account passwords are sealed with AES-GCM under a master key that only lives in the environment, nothing
  secret is ever returned, logs redact logins (`ma…@icloud.com`) and cap server messages, plain-text IMAP is
  refused except to an allow-list, request bodies are size-capped, and the min secret length is enforced.
- **Clear ADR traceability.** Almost every non-obvious decision cites SPEC/ADR (ADR 0006 state sync, ADR 0007
  push server, SPEC §6/§7/§10/§11/§15).
- **FTS query building is injection-safe.** Every user value is stripped of `"` and wrapped as an FTS5 string
  (`"…"*`), column filters use fixed column names, and every SQL value is a bound argument; the only SQL
  interpolations are integers and fixed fragments.
- **Cloud state model is simple and testable**: snapshot → diff against shadow → outbox; incoming records go
  through one `apply`/`remove` switch with deferral for mail that hasn't arrived. No CloudKit in the engine.
- **Linux portability is handled cleanly** (`VectorMath`, `DataDetection`, `Iconv`, FoundationModels behind
  `canImport`).
- Tests for the server cover pairing/auth/rate limit, sealed passwords, config parsing, and a full end-to-end
  run against Dovecot/Mailpit/fake APNs.

### Findings (by severity)

#### High

1. **Cancelling a send-later whose account isn't running left the message queued** —
   `PushServer/Sources/TidingsPush/PushEngine.swift` `cancelScheduled` (was line ~261). With no watcher for
   the account (its password failed to open, or a restart failed) the mapping was removed and `true`
   returned, but the server-side outbox row stayed. When the watcher started later it would send the mail the
   device had been told was cancelled (and the device, having taken it back, may send it too). **FIXED**: the
   outbox row is deleted in that branch (nothing is sending it, so this is safe).

2. **Re-scheduling an id that is already sending queues a duplicate** — `PushEngine.schedule` (line ~252):
   `_ = try await cancelScheduled(id:)` ignores `false` ("too late") and queues the message again, so a retried
   PUT during the sending window sends twice. **NOT FIXED**: the obvious fix (409) changes the client contract;
   `AppModel+Push.handOffToPushServer` would then keep the item queued locally and the device would send it, so
   it's still a duplicate. Needs a coordinated server+app change (e.g. treat "already sending" as success).

#### Medium

3. **`AccountSync.apply` (rules) could lose a run from the report** — `Rules/AccountSync+Rules.swift` re-read
   the run it had just inserted with `ruleRuns(limit: 1).first { $0.id == runID }`; another account's rule pass
   (same store, different actor) inserting in between made it return nil, dropping notify/deliveries for that
   message. **FIXED**: new `MailStore.ruleRun(id:)`.

4. **`OnDeviceAICheck.classify` measured elapsed time with two different `clock.now` reads** (seconds from one,
   attoseconds from another) — `AI/OnDeviceAICheck.swift`. **FIXED** (one `elapsed`).

5. **`VectorMath.dot` force-unwrapped `baseAddress` of possibly empty buffers** — `Support/VectorMath.swift`.
   An empty array's buffer may have no base address. **FIXED** (early return 0 for an empty overlap).

6. **Applying many `messageState` records is quadratic** — `Cloud/CloudApply.swift` `.messageState` case calls
   `reassertMessageStates` (a pass over *all* message states and their messages) for every record; a snapshot
   upload with N states does N full passes. **NOT FIXED**: deferring the reassert to the end of
   `applyCloudChanges` is the right shape but changes when flags land; worth doing with a test.

7. **Cloud apply isn't atomic per record** — `applyCloudChanges` applies a record (one or more writes) and then
   updates shadow/outbox/pending in a separate write. A crash in between re-applies on next sync (mostly
   idempotent: rules/folders are replace-by-id). **NOT FIXED** (structural; low practical risk).

8. **Pairing rate limit is global** — `API.swift` `PairingLimiter`: anyone who can reach the server can keep
   pairing locked by sending wrong secrets. A deliberate trade-off against brute force (the secret is ≥16 chars);
   a per-IP limit would need the proxy's forwarded address. **NOT FIXED** (design; documented).

9. **One undecryptable account stops the whole server** — `PushEngine.start` → `startWatcher` throws on
   `secrets.open` (e.g. rotated master key), so `start()` fails for every account. **NOT FIXED** (behavior
   change; arguably should mark that account failed and continue).

10. **`Unsubscribe.postOneClick` said "no redirects to follow" but `URLSession` follows them** —
    `Notify/Unsubscribe.swift`. **Comment FIXED** (now only claims what's true); not following redirects needs a
    session delegate. **NOT FIXED**.

#### Low

11. **Sealed passwords aren't bound to their account** (`Secrets.swift`): AES-GCM without associated data, so
    someone who can write the DB could swap blobs between accounts. Low (needs DB write access, and both are
    the owner's). **NOT FIXED** (would need a data migration).
12. **`TIDINGS_PLAINTEXT_IMAP_HOSTS` was compared case-sensitively** against a lowercased host —
    `ServerConfig.swift`. **FIXED** (lowercased on read).
13. **`PushServerClient.pathComponent` uses `.alphanumerics`** (Unicode letters stay unencoded, so a non-ASCII
    login can make `URL(string:)` fail) and lets `.`/`..` through as a whole segment. Public; ids are UUIDs and
    logins addresses, so low. **NOT FIXED** (recommendation: ASCII unreserved set).
14. **`ruleRuns(ruleID:)` LIKE pattern doesn't escape `%`/`_`** — `Rules/MailStore+Rules.swift`. Rule ids are
    UUIDs. **NOT FIXED** (documented by the existing comment).
15. **Search snippet maps an offset in the folded string onto the original** — `SearchEngine.snippet`. Folding
    can change character counts for a few characters (ligatures), shifting the window slightly. Cosmetic.
    **NOT FIXED**.
16. **`in:Snoozed` hard-codes the folder spellings** (`SearchEngine.plan`) next to
    `AccountSync.isSnoozedMailbox` (another area). Duplication across areas. **NOT FIXED**.
17. **Device tokens never expire, and a device can only unpair itself.** Fine for a single-owner server; noted.

#### Design, naming, duplication, magic values, comments

18. **Search: the FTS-vs-scan `FROM … WHERE` was written out four times** (`hits`, `conversations`,
    `conversationCount`, `facets`), each with its own argument assembly; `facets` also had a no-join branch that
    could never run (the plan always has the `reactionTo` message clause). **FIXED**: `Plan.source()` returns
    key column, `FROM … WHERE` and arguments; dead branch removed.
19. **`SearchQuery.apply` duplicated the text operators** for quoted and bare forms and repeated
    `value.lowercased()` per `is:` case. **FIXED**: `applyTextOperator` + `applyOperator` (tuple switch);
    semantics (unknown operator → searched as text) unchanged.
20. **`cloudSnapshot` was a 70-line function over 14 record types**. **FIXED**: split into
    `snapshotOrderedLists`, `snapshotSenderState`, `snapshotConversationState`, `snapshotAccountState`,
    `snapshotSingletons` with a small `CloudSnapshot` accumulator; the record keys `"settings"`/`"training"` are
    named.
21. **Cloud bookkeeping SQL was copy-pasted** ("DELETE FROM cloudX WHERE type = ? AND key = ?", outbox insert,
    outbox row → `CloudChange` twice, table lists twice). **FIXED**: `deleteCloudRow`, `queueCloudChange`,
    `cloudChange(outboxRow:)`, `cloudRecordTables`; `Date(timeIntervalSince1970: 1)` is now
    `neverSyncedChangeDate` with the why; `applyStateSnapshot` uses a grouped key set instead of
    `"type\u{1}key"` strings.
22. **`CloudApply.apply` repeated "replace by id and insert at clamped position" four times.** **FIXED**:
    `placing(_:at:in:id:)`.
23. **Rules: "is this an about condition" pattern-matching repeated 4×** (`Rule.usesLanguageModel`,
    `RuleEngine.matches`, `preview`) and **the push pass re-implemented `RuleAction.leavesInbox` inline**.
    **FIXED**: `RuleCondition.aboutCondition`, `Rule.aboutConditions`/`cheapConditions`; push pass uses
    `leavesInbox`.
24. **Rule report bookkeeping duplicated** in `runRules` and `runRuleOnInbox`. **FIXED**: `RuleReport.record`.
    Also `@discardableResult` sat in the middle of `runRules`' doc comment. **FIXED**.
25. **`MailWriter` repeated the session/respond/clean/catch boilerplate three times** with prompts inline.
    **FIXED**: one `write(instructions:prompt:)`, prompts as named statics; `ThreadDigest` budget trimming is
    its own `fittingBudget`, and a force unwrap became a `flatMap`.
26. **`Assist/Assist.swift` held four unrelated features** (signature details, availability, intro reply,
    needs-reply) and `SendCheck.swift` also held `HTMLDarkMode`. **FIXED**: one file per type.
    `Availability.freeSlots` split into the day loop and `longestFreeSlots`.
27. **`NeedsReply` comment was false** ("questions near the end" — the code checks for `?` anywhere).
    **FIXED** (removed).
28. **PushEngine `notifyNewMail`/`notifyWoke` built pushes inline with repeated payload code and string
    literals** (`"mail"`, `"wake"`, account states `"idle"` …). **FIXED**: `burstPush`, `mailPush`, `wakePush`,
    `payload(kind:login:messageID:)`, `PushKind`, `AccountState`, `mailCategory`, `loggable(_:)` for the
    300-char log cap. `ServerStore.removeScheduled(outboxID:login:)` moved from PushEngine.swift into
    ServerStore.
29. **Magic numbers named throughout**: body limits (`BodyLimit`), APNs token length, bearer prefix, master key
    size, min pairing secret length, min poll seconds, default team/topic, device name length, last-seen
    resolution, alert lifetime, cache size, burst sender count; search day seconds, sender facet count, snippet
    window, related/contact thresholds, size multipliers, date formats; on-device calibration/verification
    limits; ports and autoconfig timeout in `MailProvider` (plus one `login(for:)` instead of three copies);
    AI-category membership sources; signature/phone/slot constants; probe batch size, budgets, keychain
    service.

#### Test gaps

- No test for `cancelScheduled` when the account has no running watcher (the High #1 path).
- No test for duplicate `schedule` of an id mid-send (#2).
- No unit tests for `ServerStore` directly (`setPushToken` uniqueness across devices, `forgetPushToken`).
- `PairingLimiter` window expiry isn't tested (only the lock-out).
- `Availability.freeSlots` and `SearchEngine.facets` year bucketing have thin coverage.

---

## Review: `app-model` (App/Tidings/Model/**, App/Tidings/Support/**)

Scope: `AppModel.swift` (1185 lines before), 21 `AppModel+*.swift` extensions, `BundleSchedule`,
`Snippets`, and Support (`Support`, `Platform`, `CloudSync`, `Notifications`, `CalendarBridge`,
`AvatarImages`, `WakeReminders`, `Intents`). ~6850 lines. The app can't be compiled here (no
Xcode), so every change is a local extraction checked symbol by symbol against the engine API.

### Strengths

- Comments mostly explain *why* (product decisions, protocol quirks, ADR/SPEC references) and
  read well. Very little narration.
- The model keeps UI-facing behaviour in one place, with careful handling of tricky UX
  invariants: held categories while triaging, bundle anchors, pending removals, undo registered
  inside the key event so AppKit grouping sees it, `UndoToken` making toast-undo exact.
- Concurrency discipline is generally good: `@MainActor` model, `[weak self]` on long-lived
  tasks, detached work for the embedding model and search, cancel-and-replace debounces.
- Safety rules from CLAUDE.md are visibly encoded (dev copy never contacts real unsubscribe
  links, calendar disabled in the dev copy, `-TidingsNoCloud`, separate Keychain service).
- Extensions are mostly cohesive per feature (Folders, Rules, Push, Cloud, Invites...).

### Findings, by severity

#### Bugs and correctness risks

1. **Sync loop could outlive its account**. `AppModel.swift` `start()` (was l.467-471): the
   listener task awaited `sync.events()` and then appended a detached `sync.run()` task to
   `tasks[id]` without checking for cancellation. If `stopSync(accountID:)` ran while it was
   subscribing (removing an account right after adding it, or a cloud account change that
   reconnects), the run task was added after the cancel and never cancelled: a sync loop for a
   removed account. **FIXED**: `startSync(_:)` returns if `Task.isCancelled` after subscribing.
2. **Search time showed only the sub-second part**. `runSearch` (was l.1069) computed
   `Double(duration.components.attoseconds) / 1e15`, dropping `components.seconds`: a 1.2 s
   search showed as 200 ms. **FIXED** with `milliseconds(_:)` (seconds included).
3. **Triage failures swallowed** in `performQuietly` (`AppModel+Triage.swift`, was l.227,
   `try?`) and in `undo(_:)` (was l.403): `perform` reported server errors in `lastError`, the
   quiet variant (used by Send and Done, notification buttons, Read Later, replies from search)
   and Undo silently did nothing. **FIXED**: both now go through one `apply(_:_:into:)` that
   records `lastError` like `perform` always did.
4. **Smart-folder save after a folder rename swallowed** (`AppModel+Folders.swift`
   `folderMoved`, was l.288 `try? store.saveSmartFolders`): the in-memory list changed while
   the store kept the old query, so the smart folder silently broke on next launch. **FIXED**:
   the error is reported with the same message `persistSmartFolders` uses.
5. **Misplaced doc comment** `CalendarBridge.swift` l.69: the reminder doc sat on `addEvent`.
   **FIXED** (moved to `addReminder`).
6. Duplicated, half-stale comment in `perform` ("A smart folder mixes folders" twice).
   **FIXED**.
7. Orphaned doc comment: `streamItems`' description sat on `waiting(_:)`. **FIXED**.

#### Concurrency

8. `@ObservationIgnored var ...Task` handles are cancel-and-replace everywhere except a few
   "one at a time" tasks (`refinementTask`, `ruleTask`, `aiCategoryTask`, `autoDraftTask`) which
   are never cancelled on `stopSync()`; harmless (they hold `weak self`) but they keep working
   after the iPhone app stops syncing for suspension. NOT FIXED (behaviour change; worth a
   decision).
9. `scheduleAICategories` captures `self` strongly after `guard let self` for the whole loop of
   store work on the main actor; long passes can hitch the UI. NOT FIXED (needs engine API to
   move off-main; perf, not correctness).
10. `AccountStorage.devKey` and `Keychain.service/synchronizes` are `nonisolated(unsafe) static
    var`s mutated at launch/at sync toggle. Only touched from the main actor today; acceptable,
    but a `@MainActor` annotation would make that checked. NOT FIXED (callers elsewhere).

#### Error handling

11. Widespread `try?` on store writes in the model (AICategories, Mute, HighlightTraining,
    Invites, DateSuggestions, Compose `deleteOutboxItem`, Cloud `resetCloudState`, ...). Most are
    best-effort local state, but a failing store would silently lose user actions. NOT FIXED
    beyond items 3-4: changing all to surface `lastError` alters UX broadly; recommend one
    `attempt(_:)` helper that records to `lastError` and adopting it deliberately.
12. `CloudSync` swallows most store errors with `try?` in `handleEvent`; they're logged only
    for apply/collect. NOT FIXED (same reasoning; consider `SyncLog.cloud` on each).

#### Design and cohesion

13. **`AppModel` is a god object** (~90 stored properties: navigation, search, triage UI,
    sheets, push server, cloud, rules, AI, signatures...). Views use nearly all of them by
    name, so splitting into sub-models (SearchModel, SheetState, PushServerState) can't be done
    without touching other areas. NOT FIXED; recommended as a follow-up, starting with search
    (self-contained: `searchText`...`searchMilliseconds`, `runSearch`, `scheduleRelated`).
14. `reload()` did six things in 70 lines with two local caching closures. **FIXED**: split
    into `threadsForSelection(_:)`, `snoozedThreads()`, `filteredForList(_:)`,
    `updateBadges(unifiedInbox:)`, with a small `InboxReader` doing the one-read-per-reload
    caching.
15. `init()` (50 lines) mixed data-directory choice, dev-account setup and identity migration.
    **FIXED**: `makeDataDirectory`, `devAccounts(devUser:)`, `addMissingIdentities()`;
    dev-copy constants (`devAccountID`, password, default dev user) named and grouped.
16. `start()` nested the model loading and per-account sync start. **FIXED**
    (`loadOnDeviceModels()`, `startSync(_:)`).
17. Long methods split into named steps: `perform` (`removeRowsAtOnce`, `batches(for:)`,
    `apply`), `send` (`finishAnswering`, `showSendToast`), `confirmUnsubscribe`
    (`unsubscribe(_:)`), `respond` (`answeringIdentity`, `answerWording`), `folderMoved`
    (`retargetRules`, `retargetSmartFolders`), `CloudSync.handleEvent` (95 lines →
    `accountChanged`, `applyFetched`, `handleSent`), `finishWorkBeforeSuspending`,
    `handle(_:account:)` (`accountWentOffline`), `streamItems` (`listItems`,
    `deliveredBundle`). **FIXED**.
18. Folder-targeting code (`folderTargets`, `move(_:toFolder:)`, `MailboxState.displayName`)
    lived in `AppModel+Triage.swift`. **FIXED**: moved to `AppModel+Folders.swift`.
19. `AppModel+Classify.swift` runs raw SQL through `store.db` from the app (layering: the App
    shouldn't know the `message` table), and imported GRDB mid-file. Import moved to the top
    and the query named `categorySnapshots(fromSender:)`. The query itself should become a
    `MailStore` API (engine area). PARTLY FIXED.
20. `DateSuggestionCenter.shared` is global mutable state outside the model, used because
    extensions can't add stored properties. Acceptable workaround; NOT FIXED.

#### Duplication (all FIXED unless noted)

21. Account lookup `accounts.first(where: { $0.id == x })` in 8 places → existing `account(id:)`.
22. Reply account / quoted original computed identically in three compose paths →
    `replyingAccount(_:message:)`, `originalMessage(in:account:message:)`.
23. IMAP/SMTP verification duplicated in `addAccount` and `completeAccount` →
    `verifyServers(imap:smtp:password:)`, `signInReadOnly`.
24. Selection reset (`selectedThreadID/selectionIndexHint/heldCategories`) in `selection.didSet`
    and `goToInbox(account:)` → `forgetListPosition()`.
25. j/k clamping and keyboard-navigation flags duplicated for search and list →
    `navigateByKeyboard`, `clampedIndex`, `indexBeforeFirstMove`.
26. "Not sent yet..." toast text in two files → `waitingInOutboxMessage(accountName:)` (same
    localization key). "Too late, it's already sent" toast ×3 → `showTooLateToTakeBack()`.
27. Rule counts refresh ×4 with the inline `-7 * 86_400` → `refreshRuleCounts()`.
28. Auto Drafts: follow-ups and replies duplicated draft-building and saving → `saveAutoDraft`.
29. AI category examples and the 12-example cap duplicated → `example(_:matches:)`,
    `recentExamples`; `toggle` re-implemented `replace(aiCategory:)`.
30. Inbox-threads-from-sender ×3 (Senders) → `inboxThreads(from:)`; newest message of a thread
    ×3 (Links) → `newestMessage(of:)`; folder-name lookup ×5 and "not connected" guard ×3
    (Folders) → `shownName(ofFolder:accountID:)`, `connectedSync(_:)`.
31. `FontTraits.adding` re-implemented `setting` for both platforms → delegates.
32. `AccountStorage` encode/decode ×4 → `read(forKey:)`, `write(_:forKey:)`.
33. Notification `userInfo` keys as string literals in two files → `NotificationInfoKey`.
34. `"-TidingsNoPushServer"` checked in two places → `isPushServerTurnedOff`.

#### Magic values (FIXED)

35. Named: keyboard pause 120 ms, reload coalescing 250 ms, related-search delay/length,
    progress reload interval, suspend margin/poll, toast duration, mark-read dwell, removal
    animation/repeat interval, auto-draft per-pass limit, AI category limits, rule count
    period, auto-reply key/interval, suggestion length, stream tiers (were `3/2/1/0` ints; now
    `StreamTier`), CloudKit record fields and metadata keys, calendar durations, website icon
    cache lifetimes/limits, burst sender count, scan-on-open count. `"dev"` in the model →
    `AppModel.devAccountID`.

#### Dead code (FIXED)

36. Removed unused `unreadCount(_ category:)` (it also read the whole INBOX without
    `ownAddresses` on every call), `StoredMessage.isFlagged`, `CalendarBridge.wasDenied`,
    `moveAICategories(from:to:)` (no view offers category reordering).

#### Naming / comments

37. Most names are good. Some vague ones remain because views use them: `waiting(_:)`,
    `shows(_:under:)`, `allIn(aiCategory:_:)`, `perform(...toast:)`. NOT FIXED (used outside
    the area); `Views/PushServerViews.swift` still compares `$0.id != "dev"` — should use
    `AppModel.devAccountID` (Views area).
38. `"INBOX"` literal appears ~20 times; it's the IMAP-defined name so it reads fine, but a
    single constant would avoid typos. NOT FIXED (churn).

#### Security / privacy

39. Nothing alarming. Attachments are quarantined and written to a per-message temp folder with
    sanitized names; website-icon fetches are cookie-less, https-only, size-capped; dev copy is
    fenced from real calendar/contacts/unsubscribe links; passwords only in Keychain.
    `pushEnvironment` parses the provisioning profile as Latin-1 text, which is fine for the
    plist portion.

#### Test gaps

40. None of the model logic is unit-tested (it lives in the app target). The pure parts most
    worth testing would be `neighbour(after:)`, stream ordering (`streamItems`/tiers/anchors),
    `SnoozePreset.all`, `BundleSchedule`, `DateSuggestionFormat`, `CalendarBridge.recurrence`,
    `MessageLink`. Recommend moving the pure ones into the engine or an app test target.

### Verification

No Xcode here; every edit was re-read and each referenced symbol checked against the engine
(`SMTPEndpoint`, `OutboxItem`, `AutoDraft.Kind`, `MailStore.CategorySnapshot`, `SearchHits`
Sendable, `AccountSync.defaultUndoSendDelay: TimeInterval`, CKSyncEngine event payload types).
No public/internal member used outside the area was renamed or re-signatured. CI (macOS) will
be the compile check.

---

## Review: app-views (`App/Tidings/Views/**`)

Scope: 25 SwiftUI files, about 7,700 lines, shared by the macOS and iOS apps. The app can't be built here, so every refactor was kept to in-file extractions, checked against the existing symbols with grep, and kept the string literals (String Catalog keys), keyboard shortcuts, accessibility labels and ⌘K entries.

### Strengths

- Views are small, named `struct`s with a clear doc comment saying *why* each one exists. The comments explain intent well: why the iPhone has no card, why the web view passes scroll events on, why `heightReset` is there, why the drag isn't offered on iPhone.
- Privacy and security are handled carefully in `MessageWebView`: JavaScript is off, the data store is non-persistent, a CSP and a compiled content-rule list both block remote loads ("belt and braces"), and `cid:` is served from the message itself. Links go out through `Platform.openExternally`.
- Platform differences go through `Platform.isPhone/isMac`. `#if os` is used only where an API differs.
- ⌘K is the single source of actions (`AppCommand`): the key handler, menus and palette all read from one list.
- Bindings that cope with a removed row (`RuleEditor.element(of:at:fallback:)`) show awareness of a real SwiftUI gotcha.

### Findings (most severe first)

#### Bugs / correctness

1. **AICategoryEditor doubled the "Name: " prefix on every edit.** `AICategoryViews.swift` (onAppear, about line 130). `built` saves `about.description = "Name: text"`, but onAppear loaded the whole stored string back into the "What belongs here" field. Every edit-and-save gave "Investors: Investors: …", and also reported `descriptionChanged` (a needless re-sort). **FIXED**: `userDescription(of:)` strips the current name's prefix. A rename still leaves the *old* name's prefix in the text. **NOT FIXED** for that case, because the engine stores no separate user text. Recommendation: store the user's text separately in `AICategory`.
2. **SummaryLine could show "Summarizing…" forever.** `AssistViews.swift:36`. If the task was cancelled while summarising (the thread changed), `working` stayed `true`. The next run might return early (cached text, or no assistant) and never cleared it. **FIXED**: reset `working = false` at the start of each run, next to `text = nil`.
3. **Availability look-ahead vs copy.** `AssistViews.swift` `AvailabilityPicker.load` searches 14 days, but the empty-state copy says "over the next week". **NOT FIXED**: either change would alter behaviour or a String Catalog key. The window is now a named constant (`lookAhead`) so the choice is visible. Product call.
4. **Duplicate `.help` on invite answer buttons.** `InviteCard.swift` `answerButton`: `.help(title)` and then `.help(chosen ? "Your answer" : title)`. One of them is dead, and which one wins depends on how SwiftUI resolves modifiers. **NOT FIXED** (it could change the tooltip). Recommendation: keep only the second.
5. **Snooze target inconsistency.** `StreamView.swift`: the iOS swipe sets `model.snoozeTarget`, but `ThreadActions` "Snooze…" and the sidebar drop set `selectedThreadID`. With a multi-selection, the context-menu path snoozes the selection instead of the clicked row. **NOT FIXED** (behaviour). Worth checking against the AppModel semantics.
6. `AccountSetupView.swift` `BundleScheduleRow.timePicker` force-unwraps `Calendar.date(bySettingHour:)`. That is safe in practice for valid hours. **NOT FIXED**.
7. `OtherAccountForm.connect` doesn't set `model.isAddingAccount = false` on success, while Cancel does. This is probably handled in `addAccount`, but worth confirming. **NOT FIXED**.

#### Design / cohesion / long bodies

8. `ReaderView.body` (about 60 lines) mixed the subject, conversation banners and the message list. **FIXED**: split into `conversationHeader`, `mutedNotice` and `messageCards`. Margins and width are named constants.
9. `MessageCard` (`ReaderView.swift`): `content` was about 75 lines of HTML, reader mode, privacy bar, dark mode and attachment chips. The context menu was inline, and the state was named `body_`. **FIXED**: `htmlContent`, `attachmentChip`, `contextMenuActions` and `headerDividerWithRibbon`. `body_` became `loadedBody`. The card inset/corner/ribbon offset are one constant (`macCardInset`), which records that the ribbon sits on the card's edge. `canDarken` is computed once instead of twice.
10. `CommandPalette.swift` `AppModel.commands`: a 200-line computed property. **FIXED**: split into named groups in palette order (`conversationCommands`, `threadCommands`, `accountCommands`, `backgroundCommands`, `connectionCommands`, `formattingCommands`, `contactAndFollowUpCommands`, `inviteCommands`, `placeCommands`). Ids, titles, keys and order are unchanged. The palette view's body is split into `searchField` and `commandList`.
11. `SignatureViews.swift`: `SignatureEditor.body`, `SignatureRulesView.body` and `SignaturesList` (mis-indented) were long. **FIXED**: `nameAndMode`, `editorArea`, `addressDefaultsSection`, `rulesSection`, `signatureOptions` and `addRule`.
12. `AccountSetupView.swift` `GeneralSettings.body` was about 70 lines of six sections. **FIXED**: one computed property per section. `ICloudAccountForm` footer extracted.
13. `RulesViews.swift`: `RuleEditor.body` was about 90 lines. **FIXED**: `draftSection`, `conditionsSection`, `actionsSection` and `previewRow`. `RulesView.content` became `emptyState`/`rulesList`. `RuleHistoryView` got `runRow`.
14. `SidebarView.body` was 113 lines, with a dead `@Bindable var model` (no `$model` use). **FIXED**: `selection`, `mailboxesSection`, `foldersSection` and `phoneRulesSection`. The `@Bindable` was dropped.
15. `StreamView.body`/`rows` had broken indentation and an inline scroll-follow algorithm. **FIXED**: `keepInView(_:proxy:)`, `bundle(_:members:deliveredAt:)`. `ThreadRow` got `dateOrSnoozeTime`, `autoDraftButton` and `unreadDot`. The repeated `inBundle ? 18 : 0` became `bundleIndent`, and the dot's `4` is tied to the row's `verticalPadding`.
16. `OtherAccountForm.body` was about 90 lines. **FIXED**: `accountSection`, `incomingSection`, `outgoingSection` and `devServerSection`. `isLocal` was a property returning a closure and is now a plain function.
17. `InviteCard.body`: the event details were extracted (`eventDetails`).
18. `AICategoryEditor.body`: the senders, symbol and preview sections were extracted.

#### Duplication

19. The signature delete confirmation was copy-pasted (`SignatureSettingsPane` iOS and `SignaturesView`). **FIXED**: `confirmsSignatureDeletion(_:delete:)`.
20. `closeSetup()` was duplicated in `AccountSetupView`/`ICloudAccountForm`, and inlined again in `OtherAccountForm`'s Cancel. **FIXED**: one `closeAddAccount(model:close:dismiss:)`.
21. The picker tag encoding `"none"`/`"same"`/`"sig:<id>"` was spelled out in about 10 places. **FIXED**: `SignatureChoiceTag`.
22. `ByteCountFormatter.string(fromByteCount:countStyle:)` appeared three times in `SignatureEditor`. **FIXED**: `fileSize(_:)` (the localized key is unchanged, since the interpolations are still strings).
23. The "Always from sender/domain" buttons were duplicated in `PrivacyBar`. **FIXED**: `alwaysLoadButtons`. The ribbon icon styling was duplicated in `MessageRibbon`. **FIXED**: `icon(_:)`. The reaction names were joined twice. **FIXED**.
24. The `.borderless .caption .secondary` toggle buttons (×3) became `quietCaptionButton()`. `.labelsHidden().fixedSize()` (×8) in the rule rows became `compactPicker()`. `RiskBanner` repeated its danger colour/radius ternaries. **FIXED** (`warningColor`, `cornerRadius`).
25. `InviteFormat.repeats` parsed RRULE parts twice, with magic `dropFirst(5)`/`dropFirst(9)`. **FIXED** with a local `value(_:)` helper.
26. The rule lookup by id was duplicated in `RulesView`. **FIXED** (`rule(withID:)`).

#### Magic values

27. Named now: reader margins and width; `macCardInset`; the signature `saveDelay` (700 ms); the rule `previewDelay` (250 ms) and `previewListLimit` (8); the account lookup `lookupDelay` (600 ms); the IMAP/SMTP ports (993/143/465/587); `AppPassword` group length; the bundle `defaultDailyHour` (17); `BundleRow.maxSendersShown`; the sidebar `indentStep`; the availability `lookAhead`. Left as they are: one-off padding and font sizes, which carry no meaning beyond layout.

#### Comments

28. A misplaced doc comment: "Remove this account?" sat above `AwaitingAccountRow`. **FIXED**: moved to `AccountRemovalConfirmation`.
29. Narrating comments ("Let typing settle…", "Mac, as in Mail: a line…", "At once: a guess…") were turned into names or doc comments on the extracted members. Why-comments were kept.
30. `StreamView.swift`: the floating "// Sweep is only in the list's … menu" note isn't attached to code. It was kept as a product-decision note. **NOT CHANGED**.

#### Other / not fixed

- `SignatureImport.download` uses `URLSession.shared` for user-requested images. That is acceptable (the user asked), but it carries no timeout or size cap. Recommendation: limit the size.
- `MessageWebView.Coordinator.cached` is a static mutable dictionary. It is safe because the class is `@MainActor`.
- `OtherAccountForm.apply(_:source: String?? = .none)` uses a double optional (`.some(nil)` means "no source"). It is obscure but contained. Recommendation: use a small enum.
- `MessageCard` reads `model.store.unsubscribedAt` synchronously in `body`, so there is a store hit per render while expanded. It is minor; caching it in the loaded body would avoid that.
- Test gaps: the view logic that is pure (`AppPassword.normalize`, `InviteFormat.repeats/when`, `SignatureRuleRow.choice`, `linkURL(for:)`, `userDescription(of:)`) has no unit tests, because the App target has no test bundle. Recommendation: move these helpers to a testable place.
- Smaller files (HighlightViews, ReplyLaterViews, FolderViews, SearchResultsView, DateSuggestionCard, MessageSourceView, NotificationSettingsView, PushServerViews, SendersView, AttachmentBrowser, JunkBanner, UnsubscribeConfirmation, SmartFolderViews, SnippetsAndReaderViews) were scanned and are in reasonable shape. They were left untouched to keep the diff reviewable.

### Verification

- No files added, deleted or renamed. No public or shared type names or initialisers changed: `MessageCard(message:startsExpanded:reactions:)`, `CategoryPicker()`, `RulesView(inSettings:)`, `SidebarView(didPick:)`, `AppModel.commands`, `run(commandID:)` and `goToArchive()` are all unchanged.
- A script compared the string literals of every changed file against HEAD. The only differences are deduplicated copies of the same keys, a few new doc-comment/non-UI strings, and interpolations that still produce the same catalog key. The counts of `keyboardShortcut` and `accessibility*` modifiers are identical.
- The code can't be compiled here (no Xcode). CI on macOS will build both apps.

---

## Review: app-platform (`App/Tidings/Compose/**`, `App/Tidings/Mac/**`, `App/Tidings/iOS/**`)

Line numbers are for the files as they were at HEAD, before the refactor.

### Strengths

- **Platform split is clean.** Mac/ and iOS/ are excluded from each other's target in `project.yml`, and the
  shared Compose code keeps `#if os(...)` to the editor bridge, the input accessory bar and a few modifiers.
  `RichTextEditor` has the same API on both platforms, so `ComposeView` doesn't need to know which one it gets.
- **The editor logic is mostly pure and shared.** `MarkdownShortcuts`, `TextFormatting.edit` (it returns an
  `Edit` value and the coordinator applies it) and `MailBodyConverter` keep the NSTextView/UITextView
  coordinators thin. The archive format (`EditorArchive`) explains its choice of keyed archive over RTFD.
- **Comments are mostly about intent.** Most comments give a reason: ⌘⌫ handled in RootView because menu shortcuts
  fire before the text field, why `QuoteBarTextView` avoids `layoutManager`, why the iOS signature renderer
  needs a window, the double-tap-without-a-recogniser reasoning in `CategoryPager`. `CategorySwipeBar` has the
  clearest code in the area: tuning constants are named and documented.
- **Concurrency is careful.** `@MainActor` is on every UI type, `[weak self]`/`[weak model]` is used in
  long-lived closures (hot key, wake handler, autosave task, toolbar actions), and the Carbon callback uses
  `MainActor.assumeIsolated` correctly. `BackgroundTaskBox` keeps the expiration-handler race safe.
- **Keyboard reach is complete.** Every menu item has a ⌘ equivalent or a single-key shortcut, with a reason given
  where it doesn't.

### Findings (most severe first)

#### Correctness / bugs

1. **`RichTextEditor` coordinators never refreshed `parent`** — `RichTextEditor.swift:305` (Mac `updateNSView`), `:441`
   (iOS `updateUIView`). The coordinator kept the `RichTextEditor` (and so the `@Binding`) from
   `makeCoordinator()`. If SwiftUI reuses the representable with a new binding (for example a `ComposeView` that
   keeps its identity while its `model` changes), edits go to the stale binding. `InlineComposer` hides this
   with `.id(draftID)`, but the bridge shouldn't depend on that. **FIXED**: `context.coordinator.parent = self`
   at the top of both update methods (the standard representable pattern).
2. **Signature rendering can stall forever** — `SignatureRendering.swift:93-101`. `render(page:)` waits on a
   continuation that only the navigation delegate resumes. If WebKit never calls back (web content process
   crash, for example), `isRendering` stays true and every later signature waits forever. **NOT FIXED**:
   adding a timeout changes behaviour. Recommend `webViewWebContentProcessDidTerminate` resuming the load,
   plus an overall timeout.
3. **Pull-to-refresh compares a localized UI string** — `MobileRootView.swift:406`:
   `syncStatus.values.allSatisfy { $0 == String(localized: "Up to date") }`. This works only while AppModel
   stores that exact localized text. **NOT FIXED**: `syncStatus` belongs to the Model area. Recommend a typed
   "idle" state on AppModel.
4. **`ComposeModel.adopt` keeps Bcc but recomputes `showCcBcc` from it** — `ComposeModel.swift:162-164`. Converting
   Reply↔Forward replaces To/Cc but keeps the old Bcc. That may be on purpose, but it isn't documented. **NOT FIXED**
   (product decision; flagging only).
5. **`ComposerResizeHandle` cursor push/pop can unbalance** — `TidingsApp.swift:648-650`. If the handle goes away
   while hovered (reply minimized or closed with the pointer on it), `NSCursor.pop()` never runs and the
   resize cursor stays pushed. **NOT FIXED**: low impact. `.pointerStyle(.rowResize)` (macOS 15+) would remove
   the push/pop pairing.
6. **iOS editor edits bypass undo** — `RichTextEditor.swift:467-586`. Snippet expansion, list continuation and
   toolbar formatting call `textStorage.replaceCharacters` directly, so ⌘Z or shake-to-undo on iPhone/iPad
   doesn't undo them the way the Mac (`shouldChangeText`/`didChangeText`) does. **NOT FIXED**: a behaviour change.
7. **`GlobalHotKey` ignores `OSStatus`** — `GlobalHotKey.swift:17-27`. A failed `InstallEventHandler` or
   `RegisterEventHotKey` (for example a conflicting system shortcut) fails silently, and `installed` is set
   regardless. **NOT FIXED** (it would need logging policy); low.
8. **Force-unwrap in HTML export** — `RichTextEditor.swift:639` `openList!`. It was guarded by the line before,
   but fragile. **FIXED** (`if let open = openList, open != list`). Also removed `message!.subject`
   (`ComposeView.swift:668`) and `$0.name!` (`ComposeView.swift:257`).

#### Design / cohesion

9. **`TidingsApp.body` was a ~220-line scene builder with ~170 lines of menus inline** — `TidingsApp.swift:26-204`.
   **FIXED**: the formatting, Go, Message and Mailbox menus are now named `formatCommands`, `goCommands`,
   `messageMenu` and `mailboxMenu` (plain computed `some Commands`, one group each). The order of the groups and
   menus, every title and every `.keyboardShortcut` are unchanged (checked mechanically against HEAD).
   I did not move the menus to a data-driven table: the items differ in enablement, toggles and dynamic titles, so
   a table would add indirection and keep about the same number of lines.
10. **`RootView.body` was ~150 lines** — `TidingsApp.swift:266-416`. **FIXED**: extracted `listColumn`,
    `readerColumn`, `inlineReply(available:)`, `dimmedOverlay(dismiss:content:)` (the palette and folder-picker
    overlays were copy-pasted) and `handleEscape()`. `handleKey` is split into the guards plus `handleGoKey` /
    `handleSingleKey`.
11. **Long text-view delegate methods** — `RichTextEditor.swift:357-389` (Mac, ~35 lines) and `:514-586` (iOS, ~70
    lines with three nested branches). **FIXED**: each is now a short dispatcher over named steps
    (`expandSnippet`, `endBlock`/`handleReturn` → `endList`/`continueList`, `startBlock`). Mac `makeNSView` is
    split so `makeTextView()` holds the NSTextView configuration.
12. **Folder files hold unrelated types** — `TidingsApp.swift` also holds `RootView`, `InlineComposerHeight`,
    `ComposerResizeHandle`, `MinimizedReplyBar` and `ToolbarSearchField`. `ComposeView.swift` holds
    `RecipientField` and `OutboxView`. `MobileRootView.swift` holds `AppModel.refresh()`. **NOT FIXED**: the brief
    forbids new files (the checked-in .xcodeproj lists files). Recommend `RootView.swift`, `OutboxView.swift` and
    `RecipientField.swift` once the project can be regenerated.
13. **Misplaced `#endif` in `TidingsApp.swift`** — `:620`. `InlineComposerHeight`, `ComposerResizeHandle` (uses
    `NSCursor`), `MinimizedReplyBar` and `ToolbarSearchField` sat after the `#endif`. They compiled only because
    `Mac/**` is excluded from the iOS target. **FIXED**: the guard now covers the whole file.
14. **`isOverlayOpen` must list every presentation flag by hand** — `TidingsApp.swift:505-511`. A new sheet flag
    that isn't added here breaks J/K focus return without any warning. **NOT FIXED**: it needs an AppModel-level
    "presented" notion (Model area).

#### Duplication

15. **Recipient lists repeated** — `recipients(to) + recipients(cc) + recipients(bcc)` appeared 5 times in
    `ComposeModel.swift` (`:190, :210, :299, :309`, …). **FIXED** with `allRecipients`. The address-field joining
    appeared 5 times. **FIXED** with `ComposeModel.field(_:)`.
16. **Edit bookkeeping duplicated** — `replaceSignature` repeated the four lines of `changed()` minus the
    signature check (`ComposeModel.swift:354-357`). **FIXED** with `markEdited()`. `foldQuotedReply` re-derived
    `isReply`. **FIXED**.
17. **Attach / Share Availability buttons copy-pasted** between the toolbar and the embedded action row
    (`ComposeView.swift:382-387` and `:435-440`), with the same shortcuts and help text. **FIXED**: `attachButton` and
    `availabilityButton`. The From picker's two identical `ForEach`s are now `identityOptions(_:)`. The repeated
    Auto Draft lookup in `InlineComposer` is now `isSuggestedReply`. The double `autoDrafts` search in
    `OutboxView.row` is now one `first(where:)`.
18. **The visible list marker regex `^\t[^\t]*\t` appeared in three places** (`RichTextEditor.swift:533, :665`,
    `TextFormatting.swift:148`). **FIXED**: `MarkdownShortcuts.visibleMarkerPattern` (`nonisolated`, so the
    nonisolated `MailBodyConverter` can read it). The snippet trigger set and "Tab doesn't insert itself" rule
    were duplicated across the two editors. **FIXED**: `snippetTriggers` and `insertion(expanding:typed:)`.
19. **`listEdit` was 75 lines** with an inline paragraph splitter and a doubly computed substring for the
    marker. **FIXED**: `paragraphRanges(in:)` and `visibleMarkerLength(in:paragraph:)`, and the list paragraph
    attributes are computed once.
20. **Three identical navigation delegate bodies** in `SignatureRenderHost` (`SignatureRendering.swift:157-170`).
    **FIXED**: `finishLoading()`.

#### Magic values

21. **FIXED**: main-window minimum sizes (`MainWindow`), reader min width 460 (used twice), "g" sequence
    timeout 1.5 s, inline reply default share 0.55, autosave delay, `application/octet-stream`, newline `10`,
    U+FFFC (`attachmentCharacter`), snippet look-behind 40, iOS formatting bar sizes, signature renderer initial
    size / max height 2000 (used twice) / image timeout / layout settle delay, Sparkle release bundle id, Carbon
    hot key signature, background refresh interval/minimum, pull-to-refresh polling, and in `CategoryPager` the
    estimated label width 110 (×2), min label width 60 (×2, now `maxLabelWidth(in:)`), fade reach and
    double-tap interval.
    **NOT FIXED** on purpose: one-off SwiftUI paddings, frame sizes and window default sizes. In SwiftUI layout
    code these read best inline.

#### Comments

22. Comments that only described the next lines were turned into names (`// Layout catches up…` became
    `layoutSettleDelay`, `// Gmail's "•••"` became the doc on `unfoldQuoteButton`, `// U+FFFC: a picture…` became
    `attachmentCharacter`'s doc, the window-size comment became `MainWindow`'s doc). `send(at:)`'s doc comment sat
    on `isReply` (`ComposeModel.swift:253-255`). **FIXED** (moved). A stray import at the bottom of
    `ComposeModel.swift` was moved to the top, and a broken line wrap was fixed in the `PhoneBottomBar` doc.
    Why-comments are kept.

#### Security / privacy

23. Signature rendering uses a non-persistent `WKWebsiteDataStore` and cancels every non-initial navigation.
    That is good. JavaScript is enabled for measuring. Remote images in a signature are fetched while rendering,
    which is the user's own signature, so acceptable. `MailBodyConverter.inlineHTML` escapes text and `href`. It
    doesn't filter `javascript:` links, but the links are the author's own. No issues that need action.

#### Test gaps

24. `MailBodyConverter` (HTML/plain export, including signatures and lists), `TextFormatting.edit` (list toggling,
    caret maths) and `MarkdownShortcuts` hold real logic with edge cases, and none of it is tested: the App has no
    test target. **NOT FIXED** (out of scope). Recommend an App unit-test target, or moving the parts that don't
    depend on fonts into MailEngine.

### Verification

- The App can't be compiled here (no Xcode). Every changed file passes `swiftc -parse` (Swift 6.2, syntax).
  Every new symbol was checked against its use, access level and actor isolation by hand.
- String literals and `.keyboardShortcut(...)` calls in every changed file were diffed against HEAD. The only
  removals are the deduplicated copies (Attach / Share Availability, the marker regex, U+FFFC). No user-facing
  text changed.
- Nothing defined in this area and used elsewhere was renamed or re-signed.

---

