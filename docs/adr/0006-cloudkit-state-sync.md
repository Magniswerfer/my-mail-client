# 0006 · App state sync through CloudKit

**Status:** accepted · 2026-11-26 · implements iOS-2 and the CloudKit part of M7; builds on [ADR 0002](0002-inbox-state-cloudkit-plus-imap.md)

## Context
ADR 0002 made CloudKit the source of truth for state with no IMAP meaning. It wasn't built yet, and on 2026-11-25 we learned that iCloud accepts our `$Tidings…` keywords on ordinary Inbox mail but doesn't store them ([research notes](../research/icloud-imap.md)). Since then Reply Later, Read Later and snooze wake times live only on the Mac that set them, and the iPhone app sees none of your rules, smart folders, sender rules, mutes or settings.

## Decision

### What syncs, and what doesn't
| Syncs (CloudKit) | Stays per device | Stays IMAP |
|---|---|---|
| Rules, smart folders, sender rules ("always for this sender"), conversation moves (corrections), AI categories and their ✓/✗, image trust, trusted senders, unsubscribed senders, invite answers, muted conversations, Reply Later, Read Later, snooze wake times, bundle schedules, notification policy and VIPs, snippets, dismissed suggestions (Auto Drafts, calendar) | Messages, bodies, the FTS index, embeddings, classifier weights (retrained locally from the synced corrections), the outbox, the pending-action queue, mailbox state, rule history, account passwords (Keychain), "does this server keep keywords" | Done → Archive, Snooze → `Snoozed` folder, Junk, read, pinned (`\Flagged`), sent/replied flags; keywords stay as a mirror where the server keeps them |

### Shape
- One custom zone (`TidingsState`) in the **private** database of `iCloud.hk.gnus.tidings`, owned by the Creative Oak ApS team (493257NQK3). The dev copy (`hk.gnus.tidings.dev`) uses its own container, `iCloud.hk.gnus.tidings.dev`, so test data never meets real state.
- **CKSyncEngine** (macOS 14 / iOS 17) does the transport: batching, change tokens, push-triggered fetches, retries and account changes. It lives in the app, because CloudKit doesn't exist on Linux and `MailEngine` must stay buildable there (ADR 0003).
- `MailEngine` owns everything else and stays testable without CloudKit:
  - **State records:** `StateRecord(type, key, fields, modifiedAt)`, where fields are Codable JSON.
  - **Change log:** a local table of pending saves and deletes. Every mutation that should sync writes to it in the same transaction as the change.
  - **Incoming changes:** `apply(_ incoming:)` reconciles incoming records with local state.
  - The app's CKSyncEngine delegate only moves records between the change log and CloudKit.
- **Keys** are stable across devices, never local ids:
  - an account is its login address, lowercased;
  - a message is account + `Message-ID`;
  - a conversation is the Message-IDs of its messages at the time, matched on arrival;
  - rules, smart folders and categories use their UUIDs;
  - a sender is their address, lowercased.
- **State for mail not here yet:** it's kept in a pending table and applied when the message arrives in a sync. This covers a new device, or mail synced before the state record arrived.

### Conflicts
Record-level last writer wins, by the record's own `modifiedAt` (the device clock), falling back to the server's change tag. State records are small and mostly owned by one action, such as a rule edit or a Reply Later toggle, so merging inside a record isn't worth its complexity. Deletions are tombstones until CloudKit confirms them.

### Keywords and IMAP
For message state, CloudKit wins. An incoming Reply Later or Read Later sets the local flag, and is pushed to IMAP only where the server keeps keywords (`serverKeepsKeywords`). A Snooze moves the mail on the device that snoozed it; other devices see the move through IMAP and the wake time through CloudKit.

### Privacy
Only state syncs, never mail content: Message-IDs, addresses, rule text and settings. It goes to your own private database, readable only by your Apple ID. The app works with sync off or iCloud unavailable, and a toggle in Settings turns it off.

## Consequences
- The Mac app needs team signing (Apple Development, team 493257NQK3), an iCloud container and push entitlements, so ad-hoc signing ends. Builds need Xcode signed in to that team, and command-line builds use `-allowProvisioningUpdates`.
- Agents test sync logic against the engine's change log and a fake transport. The live CloudKit round trip runs in the dev container, which is still your Apple ID's iCloud, so you run it, as with live mail.
- Moving the container to another team later loses its data, so it's decided now.
- CloudKit quotas are generous for this size: kilobytes per record, thousands of records.

## Turning it on (status 2026-11-26)
The engine layer and the app's CKSyncEngine bridge are in place and inert: the app only uses CloudKit when its signature carries the iCloud entitlement for the container named in Info.plist. Creating the containers needs the Creative Oak developer account to accept Apple's latest Program License Agreement (Apple refused provisioning until then). After that:
1. In `App/project.yml`, add to both apps' `info.properties`: `TidingsCloudContainer: $(TIDINGS_CLOUD_CONTAINER)`.
2. Add to the Mac entitlements: `com.apple.developer.icloud-container-identifiers: [$(TIDINGS_CLOUD_CONTAINER)]`, `com.apple.developer.icloud-services: [CloudKit]`, `com.apple.developer.aps-environment: development`.
3. Give the iPhone app an entitlements file (`Tidings/iOS/TidingsMobile.entitlements`, excluded from the Mac sources) with the same container and services, and `aps-environment: development`.
4. Run `xcodegen generate`, then build the dev copy with `-allowProvisioningUpdates`. That registers `iCloud.hk.gnus.tidings.dev`. The first real build registers `iCloud.hk.gnus.tidings`.
5. Deploy the schema (the `State` record type) to production in the CloudKit console before a release build.
