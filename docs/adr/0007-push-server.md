# 0007 · An always-on push server (iOS-3)

**Status:** accepted · 2026-11-26 · implements iOS-3; builds on [ADR 0003](0003-headless-engine.md) and [ADR 0006](0006-cloudkit-state-sync.md)

> Magnus decided the open questions on 2026-11-26: a separate app-specific password, pairing-secret registration and an uploaded server profile, as recommended. The host is a Coolify server still to be chosen, so the deploy notes stay generic.

## Context
The iPhone only learns about new mail while Tidings is open, plus whatever BGAppRefresh gives it. iOS can't hold an IMAP connection in the background, so there is no real push. Snooze wake-ups and send-later times on the iPhone are local notifications that ask you to open the app (`WakeReminders`). On the Mac, the login-item helper does this work, but only while the Mac is awake.

ADR 0003 kept `MailEngine` headless so it could run on a server. This ADR decides what that server does, where it runs, and how it gets what it needs without CloudKit.

## Decision

### What the server does
- It runs `tidings-server`, a Linux executable built on `MailEngine`.
- **It watches mail.** It holds one IMAP IDLE connection per account on INBOX, re-IDLEd at least every 25 minutes (the iCloud limit). A second, short-lived connection polls Sent and `Snoozed` every few minutes. That is at most 2 of iCloud's 3 connections, which leaves room for the Mac and the iPhone.
- **It notifies.** It syncs headers with the normal `AccountSync`, but only for INBOX, Sent and Snoozed, into its own GRDB store on a persistent volume. It sorts new mail with the Linux classifier (below), applies the notification policy, and sends an APNs alert for each message that passes.
- **It wakes snoozes.** At a snooze's wake time it moves the message from `Snoozed` back to INBOX, using the engine's MOVE-less COPY + `\Deleted` + `UID EXPUNGE` path, then pushes "Back in your Inbox". Devices see the move through IMAP. A device whose own timer fires later finds the message already in INBOX and does nothing.
- **It sends send-later mail.** Mail scheduled beyond the undo window is handed to the server, which sends it through SMTP at its time. The engine's existing Sent-copy logic then files the copy.
- **It changes nothing else.** It moves no mail to Junk and runs no rule actions. Sorting, Junk and rules stay on the devices, so the server and the devices can never fight over a message. The server only reads mail, plus the two jobs the devices hand it.

### Linux classifier
Neither NaturalLanguage embeddings nor Foundation Models exist on Linux. The server's "Primary" therefore comes from these, in this order:
1. Layer 1 signals: `List-Unsubscribe`, `Precedence`, known ESPs, transactional patterns, and "have I written to them", which works because the server syncs Sent.
2. Your sender rules and corrections.
3. Your structured rules (sender, subject, category and so on). "About …" rules and AI categories need the on-device model, so the server skips them.

Where layer 1 says "a person", the server notifies. This is coarser than the iPhone's own sorting. In practice, a little more mail from real people may notify, and almost no bulk mail will.

### Building the engine on Linux
Each Apple-only API goes behind a small protocol with a Linux fallback. The app keeps the Apple implementation.

| Apple API | Used for | Linux fallback |
|---|---|---|
| NaturalLanguage (`NLContextualEmbedding`) | layer-2 embeddings, related search | `TextEmbedder` returns nil. No layer 2; related search is off. |
| FoundationModels | layer 3, rules, Assistant | Already behind `canImport`. Stays off. |
| Accelerate (`vDSP`) | dot products, normalisation | Plain Swift loops (`VectorMath`). |
| `NSData.compressed(using: .lzfse)` | tier-1 body text | `BodyCodec`. Linux stores zlib (via `FoundationEssentials`/system zlib) or plain text, tagged by a header byte so either side reads both. The store is per host, so this never crosses machines. |
| `CFStringConvertIANACharSetNameToEncoding` | MIME charsets | `CharsetDecoder`: a table for the common charsets (UTF-8, ISO-8859-x, Windows-125x, KOI8-R), with `iconv` for the rest. |
| `NSDataDetector` | calendar date suggestions | Off on Linux; the scanner reports nothing. Date suggestions are a device feature. |
| `Security` (probe only) | Keychain password | `tidings-probe` reads `TIDINGS_PASSWORD` on Linux. |

A new CI job builds and tests the engine on `ubuntu-latest` in the official `swift:6.2` image. Integration tests skip there, as they do on macOS CI.

### Packages
- `MailEngine` stays dependency-light. The server is a separate package, `PushServer/`, that depends on `MailEngine` by path. The app's package graph never pulls in server libraries.
- **HTTP:** Hummingbird 2, a small SwiftNIO-based server, the same NIO stack the engine already uses.
- **APNs:** APNSwift (swift-server-community), using token auth: a `.p8` key with ES256 JWTs over HTTP/2.
- **Encryption at rest:** swift-crypto.

### Notifications
- Each alert has the sender as its title and the subject as its body. The preview line is left out, which keeps less mail content in Apple's push path.
- `thread-id` is the conversation, so iOS groups alerts by thread.
- The category is the existing `MailNotifier` one, so Done and Mark as Read work from the lock screen.
- `apns-collapse-id` is a hash of the account and Message-ID.
- When the server is paired, the iPhone stops posting its own new-mail notifications and uses the same identifier, so nothing is shown twice. The Mac keeps notifying locally, because the server doesn't register Macs.
- **Payload privacy:** a plain alert passes sender and subject through Apple's push service, as every mail provider's push does. A later option is to encrypt the payload and decrypt it in a Notification Service Extension. That needs a new extension target, so it's out of scope for iOS-3.

### Security
- The server listens on HTTPS only, behind Coolify's proxy.
- Every API call needs a device bearer token. Tokens are stored hashed (SHA-256) and can be revoked one device at a time.
- IMAP and SMTP passwords are encrypted with AES-GCM under a master key from the environment. They are written once, never returned by the API, and never logged.
- Logs carry account ids and counts. They never carry addresses, subjects or bodies.

### Decisions (taken 2026-11-26)

1. **Credentials — decided: a separate app password.** The server gets its own iCloud app-specific password, named "Tidings Push". You enter it once in the app's Push settings. It goes over TLS to the server and nowhere else: not the Keychain, not CloudKit. The server stores it AES-GCM-encrypted in its SQLite database on the Coolify volume, under `TIDINGS_MASTER_KEY`, a Coolify secret. A leaked volume or backup reveals nothing without that key. Revoking "Tidings Push" at account.apple.com cuts the server off without touching your devices.
   *Not chosen:* reuse the account's existing password from iCloud Keychain and upload it automatically (no setup, but it can't be revoked separately); or put the credentials only in Coolify environment variables (no upload API, but clumsy with several accounts).
2. **Hosting.** Coolify, as ADR 0003 suggests: one container, a persistent volume for `/data`, and a public HTTPS domain. Magnus picks the server and domain at deploy time; the deploy notes are host-agnostic.
3. **Apple push key.** Magnus creates an APNs auth key in the Creative Oak team (493257NQK3), under Certificates, Identifiers & Profiles › Keys › Apple Push Notifications service. The `.p8` file goes in Coolify as `APNS_KEY_P8`, with `APNS_KEY_ID` and `APNS_TEAM_ID=493257NQK3`. The topic is `hk.gnus.tidings`. The server picks the sandbox or production endpoint per device from what the device reports. Debug builds use sandbox, TestFlight and release use production.
4. **Device registration — decided: a pairing secret.**
   - The server starts with `TIDINGS_PAIRING_SECRET`, a Coolify secret.
   - In Settings › Notifications › Push Server you enter the server URL and the secret once.
   - The secret is stored as a synchronizable Keychain item, so your other iPhone or iPad pairs itself.
   - Pairing (`POST /v1/devices`) returns a per-device token. The device then `PUT`s its APNs token and environment whenever iOS gives it a new one.
   - *Not chosen:* Sign in with Apple, with the server allow-listing your Apple user id (no secret to copy, but more moving parts); or one static token shared by all devices.
5. **Which mail notifies, and how the server learns your policy.** The server can't read CloudKit's private database without a short-lived web token for your Apple ID, which makes it a poor fit for an unattended server.
   - *Decided:* the app uploads a **server profile** whenever its synced state changes. The profile holds your notification policy, VIPs, mutes, rules, sender rules, corrections and snooze wake times. Pinned needs no upload, because it is `\Flagged` on IMAP. Send-later items go up on their own (below). Any of your devices can upload, and last writer wins, as in ADR 0006. The rules are SPEC §10's: Primary from people, VIPs, pinned, replies to conversations where you wrote last, and rules marked Notify.
   - *Not chosen:* the server notifies on every new INBOX message that layer 1 calls a person, with no policy (simple, noisier); or a silent push lets the iPhone decide (iOS throttles silent pushes and may not wake the app, so not recommended).

### Send-later hand-off
- When the server is paired and has the account, an outbox item due more than 5 minutes from now is uploaded with its account and time (`PUT /v1/scheduled/{id}`). The upload carries the composed message, which the server builds and sends like any outbox item. The device marks the item `.remote`, a new `OutboxItem.State` that only the server sends.
- Editing or cancelling the item deletes it on the server first.
- If the upload fails, the device keeps the item and today's behaviour applies.
- The server's own outbox does the sending, so its usual `sending` state and retry rules apply: a retry never sends twice.
- The device asks for the ids the server still holds (`GET /v1/scheduled`) when it returns to the foreground, and drops the `.remote` items that have gone out.
- Agents test this against Mailpit only.

## Consequences
- An always-on process holds your mail password and reads your INBOX headers. It runs on a server you control, and its password can be revoked by itself.
- iCloud allows 3 connections per account. The server uses 1–2, which leaves 1–2 for the Mac and the iPhone together. The iPhone closes its connections in the background, so in practice the Mac and the server share the allowance.
- On Linux the engine loses layer 2 and 3 sorting, related search and date suggestions. Nothing changes on the devices.
- The app gains a Push section in Settings (server URL, pairing, status, the server's app-specific password per account) and ⌘K actions for pairing and unpairing.
- Testing: the server's IMAP side runs against the local Dovecot, and SMTP against Mailpit. APNs is a protocol, so tests use a recording fake. A real push to a device needs Magnus's key and phone.

## As built (2026-11-26)
- **The profile is the ADR 0006 state records.** The device uploads `MailStore.stateSnapshot` (`PUT /v1/state`), which is its whole state of `MailStore.pushStateTypes`. The server applies it with `applyStateSnapshot`: it diffs the snapshot against what it last applied and runs the result through the same `applyCloudChanges` path CloudKit uses. Records about mail the server doesn't have yet wait in `cloudPending`, and are applied after each sync. The upload is the whole state every time, which keeps it simple and self-healing; it is kilobytes. The upload runs a moment after any change that would go to CloudKit, and when another device's change arrives through CloudKit.
- **Engine hooks.**
  - `SyncScope.pushServer` syncs only INBOX, Sent and Snoozed, and caches no bodies.
  - `AccountSync.notificationPass(policy:)` evaluates rules and the policy without acting: no rule actions, no junk moves, no learning. A rule's category counts for the decision only. Mail a rule would file away stays quiet unless the rule says Notify.
  - A new `snoozesWoke` event lets the server say "Back in your Inbox".
  - IDLE now never outlasts `pollInterval`, so Sent and Snoozed really are re-synced on time. This applies to the apps too, at their 10-minute interval.
- **Localisation in pushes.** The "Back in your Inbox" and "N new messages" (`push.burst`) titles go as `title-loc-key`, so the phone shows them in its own language. Sender and subject go as written.
- **Tests.** The server's end-to-end tests use APNSwift's `APNSTestServer`, a fake APNs, with the real APNs client. They pass on macOS and on Linux (`swift:6.2-noble`, host network) against the local Dovecot and Mailpit:
  - new Primary mail pushes, and bulk mail doesn't;
  - a snooze wakes with no device running;
  - send-later goes out, and a cancelled one doesn't.
- **Not verified yet.** A real APNs delivery and the iPhone side on a device both need Magnus's key, server and phone.

