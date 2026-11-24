# iCloud Mail IMAP/SMTP — research notes (2026-11-24)

Legend: **V** = verified by probe from this machine · **S** = sourced · **U** = uncertain.

## Endpoints
- IMAP `imap.mail.me.com:993` implicit TLS only (143 timed out). **V**
- SMTP `smtp.mail.me.com:587` STARTTLS only (465/25 closed). **V**
- ManageSieve `:4190` closed. **V**

## Pre-auth IMAP capability (V)
`XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 SASL-IR AUTH=ATOKEN AUTH=PLAIN AUTH=ATOKEN2 AUTH=XOAUTH2` — `ID` rejected before login; strict about CRLF.

## Post-auth IMAP capability — VERIFIED on Magnus's account (2026-11-24)
`XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 CONDSTORE ENABLE QRESYNC QUOTA XAPPLELITERAL NAMESPACE UIDPLUS UNSELECT SORT ESEARCH ESORT CONTEXT=SORT WITHIN SASL-IR ID IDLE X-APPLE-REMOTE-LINKS LIST-STATUS`

Differences from the older sourced list below: **no** ACL, METADATA, THREAD, CATENATE, BINARY, URLAUTH, MULTISEARCH, XMSEARCH, LANGUAGE, ANNOTATE; new: `XAPPLELITERAL`, `X-APPLE-REMOTE-LINKS`. Confirmed absent: MOVE, SPECIAL-USE, COMPRESS, NOTIFY, LIST-EXTENDED.
- `ENABLE CONDSTORE QRESYNC` → OK (bare-OK handling works).
- INBOX: `UIDVALIDITY 1`, `HIGHESTMODSEQ` reported.
- **PERMANENTFLAGS verified:** `\Answered \Flagged \Draft \Deleted \Seen \Recent $MailFlagBit0 $MailFlagBit1 $MailFlagBit2 $Forwarded Redirected $NotJunk NotJunk $iCloudCleanup \*`
- **`LIST "" ("*")` (LIST-EXTENDED pattern-list syntax) returns OK with zero mailboxes.** Use `LIST "" "*"`.
- **LIST returns `\\Sent` and `\\Trash` attributes** (and `\\Noinferiors` on INBOX) even though SPECIAL-USE is not advertised. Archive/Junk/Drafts come without attributes → name matching still needed.
- **`UID SEARCH HEADER X-Tidings-Test <id>` → `NO [UNAVAILABLE] Unexpected exception`.** Don't rely on SEARCH HEADER for custom headers; fetch `BODY.PEEK[HEADER.FIELDS (…)]` instead.
- Username: full `@icloud.com` address works. A custom-domain (iCloud+) address does not work as login.

## Post-auth IMAP capability, older sources (S)
`ACL RIGHTS=tekx CONDSTORE ENABLE QRESYNC QUOTA NAMESPACE UIDPLUS CHILDREN BINARY UNSELECT SORT CATENATE URLAUTH LANGUAGE ESEARCH ESORT THREAD=ORDEREDSUBJECT THREAD=REFERENCES CONTEXT=SEARCH CONTEXT=SORT WITHIN SASL-IR SEARCHRES METADATA ID XMSEARCH X-SUN-SORT ANNOTATE-EXPERIMENT-1 X-UNAUTHENTICATE X-SUN-IMAP XUM1 MULTISEARCH IDLE LIST-STATUS`
Sources: MailKit #970, evolution-list 2021, nextcloud/mail #13889 (Oct 2026), postalsys/imapflow #457 (Nov 2026).

**Absent:** MOVE, SPECIAL-USE, COMPRESS=DEFLATE, NOTIFY, OBJECTID, LIST-EXTENDED, X-GM-EXT.

## Quirks (S)
- `ENABLE CONDSTORE QRESYNC` → tagged OK, no `* ENABLED`. Treat OK as enabled.
- Re-send `CAPABILITY` after login (proxy literal corruption otherwise, mbsync 2022).
- `LANGUAGE` advertised but returns BAD; `QUOTA` BAD on some accounts.
- `SELECT … (CONDSTORE ANNOTATE)` → BAD. No `LIST … RETURN`.
- No `[CLOSED]` on re-select; `STATUS (PERMANENTFLAGS)` invalid.
- Historic: bogus `FETCH -1` lines on QRESYNC SELECT; `UID FETCH n:*` past last UID returned nothing.
- Capabilities may vary between backend hosts → never cache across connections.

## Keywords
`PERMANENTFLAGS (... \*)` **V**. Third-party keywords: **V** persisted, visible from a second connection, bump MODSEQ, survive COPY+EXPUNGE moves, ≥ 41 per message accepted. Not added to the mailbox `FLAGS` list. Whether Apple Mail/iCloud.com preserve them when changing flags: **U**.

## Auth
App-specific password required (2FA on). IMAP user = address (or local part); SMTP = full address. XOAUTH2 advertised but not available to new third parties. **S**

## Limits
SMTP SIZE 28319744 bytes **V**; 1000 msgs/day, 1000 recipients/day, 500/message, 20 MB user-facing **S**. Concurrent connections unpublished (~4–5 community) → cap at 3. **U**

## Folders
No SPECIAL-USE. Common: `INBOX`, `Drafts`, `Sent Messages` (sometimes `Sent`), `Deleted Messages`, `Junk`, `Archive`; may be localized. **S/U**

## Spam
Server-side filter → Junk; 30-day auto-delete; moving out of / into Junk trains per sender (Apple docs; IMAP-move equivalence **U**).

## Sending identities
Custom-domain From works with primary login **S**. Hide My Email From over SMTP **U** → test before enabling.

## Push
`XAPPLEPUSHSERVICE` is Apple-APNs-only. Third parties: IDLE per selected mailbox + CONDSTORE/QRESYNC polling.
