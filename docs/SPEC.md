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
- **More than one account:** add (Settings › General, ⌘K, Mailbox menu) iCloud or any IMAP/SMTP server; the form fills in servers from a built-in table (Gmail, Outlook.com, Yahoo, Fastmail, GMX, …), else the domain's autoconfig or Thunderbird's ISPDB (only the domain is sent), else imap./smtp.<domain>. IMAP needs implicit TLS (no IMAP STARTTLS yet); SMTP TLS or STARTTLS. Both servers are tried before anything is saved; one password, in the Keychain under the account's login. The unified Inbox is the default; each account has its own Inbox row (⌥⌘1…, a filter on the same Inbox and tabs) and `account:` in search. A message that reached two of your accounts is one conversation, acted on in each. New mail comes from the account whose Inbox you're in; the From menu lists every account's addresses and sends through the one it belongs to. **Accounts sync** ([ADR 0006](adr/0006-cloudkit-state-sync.md)): with iCloud sync on, each account's name, servers, addresses and identities go to iCloud (an `account` record keyed by login; no local id, no password) and its password to iCloud Keychain (a synchronizable item; older ones are moved there once). Sign in on the Mac and the iPhone sets the account up by itself once iCloud Keychain brings the password; until then it waits in Settings › Accounts ("Enter Password…", ⌘K "Sign In to …"). Removing an account removes it from every device (its record and its iCloud Keychain item), along with each device's local mail, state and cache for it; nothing changes on the mail server. With sync off, removal is per device and passwords stay on the device.
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
- **Category bar** above the Inbox: All, the six categories, then your **AI categories** (a name and a sentence; the on-device model sorts new mail and your recent Inbox into them; right-click ✓/✗ corrections stick and teach it). **Tab / ⇧Tab** (and ⌘] / ⌘[) cycle.
- Bundle delivery schedules (Settings → Bundles); Advertising + Newsletters default to daily at 17:00. Waiting mail shows as "N more at 17:00"; the sidebar bundle view always shows everything.
- Conversations threaded by `References`/`In-Reply-To` with subject fallback, including Sent. Actions apply to threads. Toggle to message view.
- Global ⌘Z undo for every action.

### Where state lives — [ADR 0002](adr/0002-inbox-state-cloudkit-plus-imap.md)
- Things with IMAP meaning are IMAP: Done → Archive folder, Snooze → `Snoozed` folder, spam → Junk, read/flag → system flags. Other clients stay consistent.
- **Pin = `\Flagged`** (decided in M2): flagging in Apple Mail pins in Tidings and vice versa.
- **Snooze wake time travels as keywords** (`$TidingsSnoozed`, `$TidingsWake-<unix>`) on the message in `Snoozed`, so a fresh install or another device knows when it returns.
- Triage actions are **optimistic + queued** (`pendingAction` table): the UI updates at once, the queue drains in order on the sync connection, sync never touches in-flight messages, and every action is undoable (cancel if not yet sent, inverse if sent).
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

- Corrections: move **this conversation** (default; a weight-3 training label) or **always for this sender** (`senderRule`, layer 0). Two consistent conversation moves for one sender become a rule automatically, with Undo. Every message shows "why it's here" (stable reason codes, localized in the app).
- **M4 implementation:** layer 2 = NLContextualEmbedding (Latin script, one model for DA+EN, ~10 ms/message, 512-d stored as Float16) + on-device softmax regression trained on corrections (×3) and confident header decisions; layer 3 = Foundation Models. Conservative: moves into/out of Primary need layer 3 to agree (or ≥95% with no model). Runs in the background after each sync.
- Mail is mixed Danish/English; system language is Danish. **M0 verified** Foundation Models is available and supports `da_DK` (6/6 samples correct, ~0.6 s each); Danish contextual embeddings are installed.

### Highlights (v1)
Flights/travel, packages, receipts/invoices, calendar events/invites, OTP/2FA codes, reservations, bills/subscriptions. schema.org JSON-LD first, LLM fallback. Each has an action (add to Calendar, copy code, track, open booking). Global hotkey: copy latest OTP.

**Shipped: dates → calendar suggestions** (engine `Highlights/`, all on device):
- After each sync, received mail from the last 45 days is scanned once (not Sent/Drafts/Trash/Junk, not your own mail, not Advertising, not messages with an iTIP invite, which have their own card). Results are stored per message in `eventSuggestion` (`v14-event-suggestions`), keyed by account + Message-ID, so they and your Dismiss survive a move to Archive. Opening older mail scans that conversation on the spot.
- Layers, cheapest first: (1) schema.org JSON-LD in the HTML: `Event` and subtypes, `EventReservation`, `FlightReservation`, `LodgingReservation`, `FoodEstablishmentReservation` (cancelled ones skipped). If present, it wins. (2) `NSDataDetector` over the sender's own words (quotes, attributions and forwarded blocks stripped) plus the subject. Relative dates ("i morgen", "næste tirsdag", "on Friday") are re-anchored to the sent date, year-less dates take the next occurrence, and times are read in the sender's zone (from the Date header offset) unless the text names one ("14:00 CET"). Danish/English plan words raise confidence. History, paperwork, deliveries, opening hours, past dates and quoted text are dropped. (3) Foundation Models (guided yes/no + title, ~0.4 s) only for uncertain candidates (a time with no plan word, a bare date) and fallback titles, at most 12 per pass. Without Apple Intelligence, uncertain ones are kept only in Primary mail.
- Reader: a quiet card ("Add to Calendar: Middag hos os · fre. 27. nov. 19.00"), up to three per message, showing the source sentence and the written time when it's in another zone. **Add…** (⌃⌘E, ⌘K "Add Date to Calendar…") opens an editable event sheet (title, place, all-day, start/end, notes with the sentence and a `tidings://` link) and saves through the EventKit bridge, with Undo. **Dismiss** (✕, ⌘K) is remembered per message. To try it on the local server: `tidings-probe seed-test-server --user dates --date-plans`, then run the dev copy with `-TidingsDevUser dates`.

### Meeting invitations (M4.6)
- Recognised from any `text/calendar` / `application/ics` / `.ics` part (iTIP, RFC 5546): Apple, Google, Outlook/Exchange (Windows TZIDs and VTIMEZONE resolved), Zoom, etc. The calendar alternative is not shown as an attachment.
- Invites, updates, cancellations and counter-proposals for you → **Primary** (reason "A meeting invitation for you"); attendees' answers to your invites → **Updates**. Bulk webinar blasts that don't name you fall through to the normal rules.
- Every message about one event (same `UID`) shares a conversation, even when the sender omits `References`.
- Reader card: date tile, time (plus the organizer's local time when it differs), repeat rule, place, join button (Meet/Teams/Zoom/Webex/FaceTime), organizer and guests with their answers, clashes from your calendar.
- **Accept / Maybe / Decline** (also ⌃⌘Y / ⌃⌘M / ⌃⌘N and ⌘K) sends an iTIP REPLY to the organizer through the outbox (normal undo window, ⌘Z), echoing UID/SEQUENCE/RECURRENCE-ID and the attendee address exactly as invited. Your answer is remembered per event (`inviteResponse`), including answers seen in Sent from other clients; an update with a higher SEQUENCE asks again.
- Calendar (EventKit, full access asked on first use): accepting adds the event (tentative → shown as tentative), declining or a cancellation removes the copy Tidings made, updates move it. Events the calendar server already put there are never duplicated or rewritten. The copy carries no organizer/attendees, so Calendar never sends a second answer.

### Assistant (M4.7, Superhuman-inspired, all on device)
- **Auto Summarize:** one or two sentences under the subject for conversations with 3+ messages or ~1 200+ characters of their own words (quotes stripped). Foundation Models, in the emails' language; cached per conversation and redone when a message arrives. Off without Apple Intelligence.
- **Auto Drafts:** when you wrote last, to real people (≤ 6, no robots), at least N days ago (default 3, max 21), Tidings drafts a follow-up (on-device model, else a localized template) as a reply quoting your message. It waits in Drafts with a banner on the conversation and a Follow-ups row in the sidebar; never sent automatically; deleted when a reply arrives; Discard means never again for that conversation.
- **Instant Intro** (⌘⇧I): reply to everyone introduced, the introducer moved to Bcc, opening "Thanks, Anna (moved to Bcc)!".
- **Share Availability** (⌥⌘A in the composer): free slots in working hours (Settings → Assistant) over the next five working days from your calendar, pick which, insert as text with your time zone.
- **Contact sidebar** (⌃⌘I, toolbar, or tap an avatar; a sheet on iPhone): mail both ways, since when, last contact, typical reply time, links and phone numbers from their signature, recent conversations, colleagues at the same organisation. Built only from your own mail; nothing is looked up online.

### Flow (M4.8)
- **Send and Done** (default on, Settings → Assistant): sending a reply marks the conversation done; ⌥⌘↩ sends the other way; one Undo reverses both.
- **Pre-send check:** "attached/vedhæftet/anbei…" with no attachment, or a dropped participant you name → Attach / Add / Send Anyway.
- **Dark message bodies:** mail without its own background colours is recoloured in dark mode; designed mail keeps its colours on a light card; "Original Colours" per message.
- **Reply Later** (L): keyword `$TidingsReplyLater` on the newest message (syncs via IMAP). Gathered in one row at the top of the Inbox; **Answer Now** (⌘⇧L) walks the pile with the conversation above and the reply below; Skip / Done Without Replying; replying clears it.
- **Links and tasks:** `tidings://message/<Message-ID>`; Copy Link, Add to Reminders (due presets, link back), Add to Things (if installed); Shortcuts actions Get Open Message, Open Message, Add Open Message to Reminders.
- **Keyboard shortcuts sheet** on ? and ⌘/.

### Writing assistance
System Writing Tools in the composer, one-line thread summaries, "Summarize" for long threads, 2–3 smart-reply chips, "extract questions". No full drafting (plugins/MCP can add a bigger model later).

## 6. Rules

- Outlook-style: ordered, conditions + actions, "stop processing more rules".
- Pipeline order: **spam → AI classification → user rules** (rules can read and override category).
- **Natural-language conditions** ("all mails that are about shoes"): embedding pre-filter against stored vectors → Foundation Models yes/no verification on candidates. Cheap structured conditions short-circuit first. Few-shot tuning via ✓/✗ in the preview. Per-rule confidence threshold; uncertain → "maybe" bundle.
- Create rules by typing a sentence → editable rule.
- Actions: move, categorize/bundle, pin, snooze, mark read, forward, auto-reply, notify, run plugin, run Shortcut. NL rules may never hard-delete or forward without confirmation.
- Run on new mail automatically; run on existing mail on demand; every rule has a preview ("would have matched 143").
- **M5 implementation:** rules live in SQLite (`rule`, ordered; CloudKit in M7). They run after the AI sorting pass that follows each sync, on Inbox mail that arrived since the last pass (`message.rulesChecked`; mail that was there before rules existed, and a mailbox's first sync, count as seen). Actions go through the normal queued triage path; matched rules merge (last category wins, only the first action that leaves the Inbox runs). Every run is recorded (`ruleRun`) with the previous category, shown in Rule History with Undo. Conditions: sender, recipient, subject, subject-or-text (contains / doesn't contain / is / begins with / ends with), category, attachments, "about …". Forward and auto-reply are deferred (they need a confirmation step).
- **"About …" conditions:** the description is embedded once; a message's stored embedding must clear a per-condition cut calibrated on your Inbox (mean + 1.5 SD of similarities, since raw scores are high for everything) before Foundation Models gives the yes/no, with your ✓/✗ examples in the prompt (~0.4 s per message on device). Without the model the cut decides; previews ask the model only about the 30 likeliest. A sentence can be drafted into a rule (guided generation), then grounded in the sentence: invented addresses and unmentioned conditions are dropped.

## 7. Search & smart folders

- Results are **newest-first**, computed in two phases: hits on the keystroke, facets right after (see [M0 results](M0-results.md) for why).
- All four layers: **faceted as-you-type** core (< 30 ms p95), **scope-aware** (current bundle/folder/thread; one key widens), **semantic** second tier (embeddings), **entity-aware** (person card on top when query matches a contact).
- Gmail-compatible operators: `from: to: has:attachment larger: before: after: category: is:pinned in:` + NL criteria.
- Danish + English stemming ("faktura" finds "fakturaer").
- Smart folders = saved searches (⌘S), live counts; built-ins: Attachments, Waiting for reply, Receipts this year.
- **M5 implementation:** extra operators `is:pinned`, `is:waiting` (the newest message in the conversation is in a Sent folder), relative dates (`after:30d`, `6w`, `3m`, `1y`, `today`, `thisweek`, `thismonth`, `thisyear`). Smart folders list conversations from any folder; triage acts where the conversation lives. Search is scoped to the category, folder or smart folder you're in (not the Inbox); ⌥⌘F widens it. A person card appears when plain words prefix-match a sender (by volume, never yourself). "Related" results: the query embedding against the stored embeddings of the newest 20 000 messages, keeping standouts (mean + 2 SD), off the main thread after typing pauses.

## 8. Spam & privacy

- Layered on top of iCloud's server filter: Authentication-Results (SPF/DKIM/DMARC/ARC), lookalike-domain & display-name spoofing, link-text/href mismatch, local classifier trained on Junk + corrections, LLM phishing explanations. **No external lookups.**
- Corrections move mail in/out of Junk on the server (trains iCloud's filter too). Uncertain → warning banner, stays in inbox.
- **Local junk filter (implemented):** token naive Bayes in the SpamBayes style (Robinson's per-token probabilities, chi-square combining over the ≤150 most telling tokens). Tokens: subject words, body words (first 4 000 characters, 3–20 letters/digits), sender address, domain, registrable domain and name words, link hosts, Tidings' phishing verdict. Counts in `junkToken`; one label per message in `junkLabel`, keyed by Message-ID across folders and accounts, with the tokens it added so a correction takes them back exactly (`v22-junk-filter`). Learned on this device only (not synced through CloudKit; each device learns from the same server Junk).
  - **Learns from:** what's in each account's Junk folder (now synced, kept out of search unless `in:Junk` or searching inside Junk); every move into Junk (spam); every move out of Junk except to Trash, "Not Junk" (fine); "It's Fine" on a warning (fine); and kept mail: Archive and your folders, and Inbox mail read and left for 3 days (fine; not your own, not Sent/Drafts/Trash). Batches of 300 junk + 600 fine per pass. Undoing your own move forgets what it taught; undoing the filter's move teaches "fine".
  - **Acts on:** new Inbox mail, first thing in the pass after each sync (spam → AI sorting → rules), once it has learned ≥ 20 junk and ≥ 50 fine. ≥ 0.95 → moved to Junk on the server (toast "Moved 1 message to Junk · Undo"; not notified, rules don't see it); 0.80–0.95, or a likely-junk message in a longer conversation → "This looks like junk" banner with Move to Junk / It's Fine. Never touched: your own mail, senders you've written to, trusted ("It's safe") senders, senders with a category rule, conversations you've written in, pinned mail, invitations. Mail present before the upgrade, and a mailbox's first sync, are not scored.
  - In Junk the reader says "This message is in Junk" (and "Tidings moved it here" when it did) with **Not Junk**; `!`, the menus and ⌘K turn into Not Junk there. Settings › General › Junk › Filter Junk (on by default; learning continues when off) shows how much it has learned.
- Remote content: strip tracking pixels/links always; auto-load images only for senders you've written to or approved (per sender or domain); "3 trackers removed" indicator. `cid:` inline images served from the message.
- Phishing (M4): Authentication-Results, brand-in-display-name (whole words), look-alike/punycode domains (incl. your correspondents' domains), link-text/href mismatch, Reply-To elsewhere → caution/danger banner with reasons, "Move to Junk" / "It's safe". Nothing moves automatically.
- Avatars: Contacts photo → BIMI logo → domain favicon → monogram. Cached per domain, toggle to disable network avatars.

## 9. Compose & send

- Rich-text editor (`NSTextView`) with Markdown-style input shortcuts; sends clean HTML + text/plain alternative. Quoted text trimmed/collapsed.
- Undo send (default 10 s local outbox), send later (via helper; late-send notice after sleep), follow-up nudges ("bring back if no reply in N days"), snippets/templates (`;keyword`, variables), signatures per identity.
- Identities: primary iCloud + custom-domain addresses (Settings → Identities). From auto-selected by receiving address. **Hide My Email** only after a live SMTP test proves it keeps the alias.
- **Sent copy:** iCloud's behaviour is undocumented, so the first send per account checks whether the server filed its own copy (by Message-ID, ~12 s); if not, Tidings APPENDs one from then on. Remembered per account.
- Sending is a persisted outbox (`outbox` table): undo window, send later, retries with backoff for 4xx/network errors, permanent failures kept with the error. Replies set `\Answered`, forwards `$Forwarded` on the original.
- Follow-up nudges and `;snippets` move to M6.

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
- **Folders:** New Folder (the + on each account's Folders header, the folder's right-click menu, Mailbox › New Folder…, ⌘K "New Folder…"), Rename…, Move To… (top level or inside another folder), Delete… (confirmation says the mail goes too, and names subfolders), and Use As Archive/Sent/Drafts (a per-device choice that wins over SPECIAL-USE and names). Folders show as a tree under their own names: on servers where everything lives under `INBOX.` (Dovecot namespaces, e.g. NordicWay) a top-level "Receipts" is `INBOX.Receipts` on the wire. Changes go straight to the server on their own connection, after the triage queue has drained; the local store, queued moves, rules that file into the folder and cached bodies follow a rename. INBOX can't be changed; special folders (Sent, Drafts, Archive, Snoozed, or a folder holding one) need a warning first. Non-ASCII names go out as modified UTF-7.
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

App-specific-password walkthrough (iCloud has no third-party OAuth/SSO: Sign in with Apple only gives identity, `XOAUTH2` is partner-only, `ATOKEN` is private). Two steps: open account.apple.com, then Paste (clipboard read only on click, format-validated, auto-connect) → sync order: INBOX headers last 30 days (usable in ~5–10 s) → those bodies + classification → older mail/folders in background with sidebar progress → optional 60-second "teach me" on ~20 ambiguous messages.

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
| **M1 · Read-only client** ✅ | sync, stream, threads, reading pane, instant faceted search |
| **M2 · Triage** ✅ (verified on local server) | Done/Pin/Snooze/Sweep, undo, keyboard, ⌘K |
| **M3 · Compose** ✅ (verified on local servers) | SMTP, outbox/undo send, identities, signatures — **daily driver** |
| **M4 · Sorting** ✅ (verified on local servers) | AI categories, bundles + schedules, spam layers, remote-content protection |
| **M4.5 · UI tightening** ✅ | Move a conversation (toolbar, right-click, drag to sidebar, M) that teaches the classifier and becomes a sender rule after two consistent moves; reply/forward/compose in the toolbar; status in the sidebar footer; sweep at the end of the list; neutral avatars, quieter bundles; previews without quoted text |
| **M4.6 · Invites** ✅ (engine tested on Linux; app not yet built) | Recognise invites/updates/cancellations/replies, invite card, RSVP by iTIP reply, calendar add/update/remove, clashes, threading by event UID |
| **M4.7 · Assistant** ✅ (CI-built; engine tested) | Auto Summarize, Auto Drafts (follow-ups), Instant Intro, Share Availability, contact sidebar |
| **M4.8 · Flow** ✅ (CI-built; engine tested) | Send and Done, pre-send check, dark message bodies, Reply Later + Answer Now, message links + Reminders/Things/Shortcuts, shortcuts sheet |
| **M5 · Rules** ✅ (engine tested; UI built, not yet clicked through) | rules incl. NL (about …, drafting from a sentence), history + undo, smart folders, scope-aware/entity/semantic search |
| **M6 · Polish** ✅ (CI-built; engine tested) | Highlights (JSON-LD + patterns, copy code ⌃⌥C), date → calendar suggestions (§5), notifications + VIPs + Focus filter, one-click unsubscribe + Senders, Read Later (reader mode), mute, attachment browser, ;snippets; auto drafts also reply to mail that asks you something; rules can forward, auto-reply, run a Shortcut |
| **M6.5 · AI categories** ✅ (CI-built; engine tested) | Categories you describe in words, sorted on device (rule judge), ✓/✗ corrections as examples; category bar above the Inbox, Tab / ⇧Tab and ⌘] / ⌘[ cycle |
| **M7 · Sync & extend** | ~~CloudKit~~ (done as iOS-2), plugin hooks hardened, MCP server |
| **iOS-1 · iPhone app** (CI-built; not yet run on a device) | Shared app code, collapsing split view, swipes (pin / Done / Snooze), pull to refresh, compose sheet with the same rich-text shortcuts, invites; connections close in the background after flushing undo-send and queued actions, BGAppRefresh catch-up |
| **iOS-2 · Same state everywhere** ✅ (engine tested; verified live in the dev container, 2026-11-26) | CloudKit sync of app state ([ADR 0006](adr/0006-cloudkit-state-sync.md)): rules, smart folders, sender rules, corrections, AI categories, trust, unsubscribes, invite answers, mutes, Reply Later / Read Later / snooze wake times, bundle schedules, notification policy, snippets. The `State` schema is deployed to Production (2026-11-26), so release builds sync too, accounts included |
| **iOS-3 · Push** | MailEngine on the server (Linux build: replace NaturalLanguage/FoundationModels/LZFSE/CF charsets behind protocols), IDLE per account, APNs for Primary/VIP/pinned, server-side send-later and snooze wake |
