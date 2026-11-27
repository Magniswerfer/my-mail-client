import Foundation

/// One configured mail account.
public struct AccountConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var endpoint: IMAPEndpoint
    /// Addresses that belong to the user (login + custom-domain identities), used to spot "sent by me".
    public var addresses: [String]
    /// Outgoing server; nil means the provider default (iCloud: smtp.mail.me.com:587).
    /// Optional (like `identities`) so accounts saved before M3 still decode.
    public var smtp: SMTPEndpoint?
    public var identities: [Identity]?

    public init(id: String = UUID().uuidString, displayName: String, endpoint: IMAPEndpoint, addresses: [String],
                smtp: SMTPEndpoint? = nil, identities: [Identity]? = nil) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.addresses = addresses
        self.smtp = smtp
        self.identities = identities
    }

    /// Identities to send from; falls back to the account's addresses.
    public var sendingIdentities: [Identity] {
        if let identities, !identities.isEmpty { return identities }
        return addresses.map { Identity(address: $0, name: "") }
    }

    /// The identity a reply should come from: whichever of mine the original was sent to (SPEC §9).
    public func identity(replyingTo parsed: ParsedMessage) -> Identity {
        let received = Set((parsed.to + parsed.cc).map { $0.address.lowercased() })
        return sendingIdentities.first { received.contains($0.address.lowercased()) } ?? sendingIdentities.first
            ?? Identity(address: endpoint.username, name: "")
    }
}

/// Which mailboxes a sync keeps.
public enum SyncScope: Sendable, Hashable {
    /// Everything you can search: INBOX, Sent, Archive, Drafts, Junk and your folders (the apps).
    case everything
    /// What the push server needs (ADR 0007): INBOX (new mail), Sent ("have I written to them",
    /// replies to mail you're waiting on) and Snoozed (wake-ups). No bodies are cached.
    case pushServer
}

/// Keeps the local store in step with one account. **Read-only in M1**: mailboxes are opened
/// with EXAMINE and bodies fetched with BODY.PEEK, so syncing never marks anything read.
public actor AccountSync {
    public enum Event: Sendable {
        case started
        case mailboxProgress(mailbox: String, done: Int, total: Int)
        case mailboxSynced(mailbox: String, newMessages: Int)
        case idle
        /// Connecting or syncing failed; the account retries with a pause.
        case failed(String)
        /// The server refused a queued change (a move, a flag): the connection is fine. Sent each
        /// pass it's refused, including the last, when it's given up.
        case changeRefused(String)
        case sending(outboxID: Int64)
        case sent(outboxID: Int64)
        case sendFailed(outboxID: Int64, message: String)
        /// Snoozed conversations whose time came; they're on their way back to the Inbox.
        case snoozesWoke(messageIDs: [Int64])
    }

    public let account: AccountConfig
    public let store: MailStore
    let password: String
    let profile: ServerProfile
    let cache: MessageCache
    public let scope: SyncScope

    /// Messages newer than this are fetched in full and kept in the cache tier.
    public var offlineWindow: TimeInterval = 30 * 86_400
    /// Bigger messages get only their first `largeMessagePrefix` bytes fetched for indexing.
    public var largeMessageThreshold = 2_000_000
    public var largeMessagePrefix: UInt32 = 256_000
    public var batchSize = 25

    private var listeners: [UUID: AsyncStream<Event>.Continuation] = [:]
    /// Set when a triage action is queued; the loop drains before its next IDLE.
    var hasPendingWork = false
    private var wakeContinuation: AsyncStream<Void>.Continuation?

    /// Ends an IDLE in progress so queued work reaches the server now.
    func signalWork() {
        hasPendingWork = true
        wakeContinuation?.yield()
    }

    private func setWake(_ continuation: AsyncStream<Void>.Continuation?) { wakeContinuation = continuation }

    /// Draining the queue and folder changes take turns, so a queued move into a folder reaches
    /// the server before that folder is renamed or deleted (and never runs twice).
    private var serverBusy = false
    private var serverWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireServer() async {
        while serverBusy {
            await withCheckedContinuation { serverWaiters.append($0) }
        }
        serverBusy = true
    }

    func releaseServer() {
        serverBusy = false
        if !serverWaiters.isEmpty { serverWaiters.removeFirst().resume() }
    }

    /// Bumped by every folder change: a sync pass that listed folders before it stops and
    /// starts over rather than syncing a folder that was just renamed or deleted.
    var folderGeneration = 0

    /// How a mailbox's sync read the server (see `syncMailbox`).
    public enum MailboxPass: Sendable, Hashable {
        /// Nothing changed on the server: nothing fetched.
        case skipped
        /// Changes since the saved MODSEQ; `vanished` when the server listed expunges (QRESYNC),
        /// `uidCheck` when the UID sets had to be compared.
        case changes(vanished: Bool, uidCheck: Bool)
        /// The whole message list.
        case full
    }
    /// The most recent pass per mailbox path.
    public private(set) var lastPass: [String: MailboxPass] = [:]

    /// "Check for new mail": ends an IDLE in progress and re-syncs every mailbox now, not just
    /// INBOX (the others otherwise wait for the next `pollInterval`).
    var fullSyncRequested = false
    public func checkNow() {
        fullSyncRequested = true
        wakeContinuation?.yield()
    }

    public init(account: AccountConfig, password: String, store: MailStore, cache: MessageCache, profile: ServerProfile? = nil,
                scope: SyncScope = .everything) {
        self.account = account
        self.password = password
        self.store = store
        self.cache = cache
        self.profile = profile ?? ServerProfile.detect(host: account.endpoint.host)
        self.scope = scope
        if scope == .pushServer { offlineWindow = 0 }
    }

    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    func emit(_ event: Event) {
        for continuation in listeners.values { continuation.yield(event) }
    }

    // MARK: Running

    /// Syncs everything, then IDLEs on INBOX and re-syncs on changes. Other mailboxes are
    /// re-synced every `pollInterval`. Reconnects with backoff on errors. Runs until cancelled.
    public func run(pollInterval: Duration = .seconds(600)) async {
        try? store.resetInterruptedSends(accountID: account.id)
        var backoff: Duration = .seconds(5)
        while !Task.isCancelled {
            do {
                try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
                    try await self.syncAll(session)
                    backoff = .seconds(5)
                    var lastFullSync = ContinuousClock.now
                    while !Task.isCancelled {
                        try self.wakeDueSnoozes()
                        try await self.sendDue(session)
                        try await self.drain(session)
                        _ = try await session.select("INBOX", readOnly: true)
                        var changed = false
                        if !self.hasPendingWork && !self.fullSyncRequested {
                            self.emit(.idle)
                            let (wake, continuation) = AsyncStream<Void>.makeStream()
                            self.setWake(continuation)
                            // Never IDLE past the next poll, so other mailboxes really are re-synced every `pollInterval`.
                            let untilPoll = pollInterval - (ContinuousClock.now - lastFullSync)
                            changed = try await session.idle(timeout: max(.seconds(1), min(self.idleTimeout(), untilPoll)), wake: wake)
                            self.setWake(nil)
                        }
                        try self.wakeDueSnoozes()
                        try await self.sendDue(session)
                        try await self.drain(session)
                        if changed {
                            try await self.syncMailbox(session, path: "INBOX", role: .inbox)
                        }
                        if self.fullSyncRequested || ContinuousClock.now - lastFullSync > pollInterval {
                            self.fullSyncRequested = false
                            try await self.syncAll(session)
                            lastFullSync = .now
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                SyncLog.info("sync loop: \(error); reconnecting in \(backoff)")
                emit(.failed(String(describing: error)))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
            }
        }
    }

    /// A short-lived catch-up for when the app can't stay connected (iOS background refresh):
    /// wakes due snoozes, sends due mail, pushes queued triage, then syncs. One connection, then done.
    public func catchUp() async throws {
        try store.resetInterruptedSends(accountID: account.id)
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try self.wakeDueSnoozes()
            try await self.sendDue(session)
            try await self.drain(session)
            try await self.syncAll(session)
        }
    }

    /// One full pass over the interesting mailboxes, INBOX first.
    public func syncOnce() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.syncAll(session)
        }
    }

    /// IDLE until the next snooze is due or the server's refresh interval, whichever is sooner.
    func idleTimeout() -> Duration {
        let candidates = [try? store.nextSnoozeWake(accountID: account.id), try? store.nextOutboxSend(accountID: account.id)]
            .compactMap { $0 }
        guard let next = candidates.min() else { return profile.idleRefresh }
        return min(profile.idleRefresh, .seconds(max(1, next.timeIntervalSinceNow)))
    }

    func syncAll(_ session: MailSession) async throws {
        emit(.started)
        try await drain(session)
        let generation = folderGeneration
        let listing = try await session.listMailboxes()
        _ = try await personalPrefix(session, listing: listing)
        if let separator = Self.hierarchySeparator(in: listing) {
            try store.setSetting(Self.separatorKey, String(separator), accountID: account.id)
        }
        var roles = MailboxRoleResolver.resolve(listing)
        try await preferFullest(&roles, listing: listing, session: session)
        try applyRoleChoices(&roles, listing: listing)
        // Trash isn't synced: remember where it is, so Move to Trash goes there.
        for role in [MailboxRole.trash, .junk, .archive] {
            try store.setSetting(Self.roleKey(role), roles[role] ?? "", accountID: account.id)
        }
        // Junk too: the junk filter learns from it, and you can rescue mail from it.
        let order: [MailboxRole] = [.inbox, .sent, .archive, .drafts, .junk]
        var paths: [(String, MailboxRole?)] = order.compactMap { role in roles[role].map { ($0, role) } }
        // User folders too (they're part of the mail you search), but not Trash.
        let skipped = Set([roles[.trash]].compactMap { $0 })
        for box in listing where !paths.contains(where: { $0.0 == box.path }) && !skipped.contains(box.path)
            && !box.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame })
            && !TestFence.isInsideFence(box.path) {
            paths.append((box.path, nil))
        }
        if scope == .pushServer {
            paths = paths.filter { path, role in role == .inbox || role == .sent || Self.isSnoozedMailbox(path) }
        }
        // A folder changed while we listed: this listing is stale, start over.
        guard generation == folderGeneration else { fullSyncRequested = true; return }
        // Forget mailboxes that disappeared on the server.
        let known = try store.mailboxStates(accountID: account.id)
        for state in known where !listing.contains(where: { $0.path == state.path }) {
            try store.deleteMailbox(accountID: account.id, mailbox: state.path)
        }
        for (path, role) in paths {
            guard generation == folderGeneration else { fullSyncRequested = true; return }
            do {
                try await syncMailbox(session, path: path, role: role)
            } catch let error as MailSessionError where generation != folderGeneration {
                // Renamed or deleted under us (the SELECT failed): the next pass sorts it out.
                SyncLog.info("sync of \(path) stopped by a folder change: \(error.description)")
                fullSyncRequested = true
                return
            }
        }
    }

    // MARK: One mailbox

    /// Some servers mark two folders with one SPECIAL-USE (Dovecot's default config has both
    /// "Sent" and "Sent Messages" as \Sent). Take the one that holds the mail, not just the
    /// first listed; the other stays an ordinary folder.
    func preferFullest(_ roles: inout [MailboxRole: String], listing: [MailboxListing], session: MailSession) async throws {
        for (attribute, role) in MailboxRoleResolver.specialUse {
            let candidates = listing.filter { box in box.attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame } }
            guard candidates.count > 1 else { continue }
            var best: (path: String, count: Int)?
            for box in candidates {
                let count = (try? await session.select(box.path, readOnly: true).exists) ?? 0
                if best == nil || count > best!.count { best = (box.path, count) }
            }
            if let best { roles[role] = best.path }
        }
    }

    /// Syncs one mailbox, reading as little as the server allows (RFC 7162):
    /// - **unchanged** (same UIDNEXT, MESSAGES and HIGHESTMODSEQ as last time, and the local copy
    ///   agrees on the count): nothing is fetched;
    /// - **QRESYNC**: `UID FETCH 1:* (…) (CHANGEDSINCE n VANISHED)` brings new mail, flag changes and
    ///   expunges in one round trip;
    /// - **CONDSTORE**: the same without VANISHED; when the counts say something was expunged,
    ///   a `UID SEARCH` finds what;
    /// - otherwise, or the first time, or after a UIDVALIDITY change: the full message list.
    func syncMailbox(_ session: MailSession, path: String, role: MailboxRole?) async throws {
        let selected = try await session.select(path, readOnly: true)
        try readAllAfterKeywordPolicyChange()
        var saved = try store.mailboxStates(accountID: account.id).first { $0.path == path }
        // A mailbox's first sync (a new account or device, or the server reset its UIDs) brings in
        // mail that was already there, not mail that just arrived: rules don't run on it.
        let firstSync = saved?.uidValidity == nil || saved?.uidValidity != selected.uidValidity.map(Int64.init)
        if let savedValidity = saved?.uidValidity, let validity = selected.uidValidity, savedValidity != Int64(validity) {
            // UIDs are meaningless after a UIDVALIDITY change: start over for this mailbox.
            try store.deleteMailbox(accountID: account.id, mailbox: path)
            saved = nil
        }

        // Leave alone whatever a queued triage action is about to change: its source message is
        // still on the server here, and its local row already shows the result.
        let inFlight = try store.inFlight(accountID: account.id, mailbox: path)
        let inFlightUIDs = try store.uids(localIDs: inFlight.localIDs, mailbox: path)

        // MODSEQ to fetch changes since; nil means a full pass.
        let since: UInt64? = {
            guard session.resyncMode != .none, !firstSync, let saved, let old = saved.highestModSeq,
                  let now = selected.highestModSeq, selected.uidValidity != nil else { return nil }
            let oldModSeq = UInt64(bitPattern: old)
            return oldModSeq <= now ? oldModSeq : nil
        }()

        if let since, let saved, since == selected.highestModSeq,
           saved.uidNext == selected.uidNext.map(Int64.init), saved.messageCount == selected.exists,
           try expectedServerCount(path: path, inFlight: inFlight) == selected.exists {
            var touched = saved
            touched.lastSync = Date()
            try store.save(touched)
            SyncLog.info("sync \(path): unchanged (modseq \(since)), skipped")
            lastPass[path] = .skipped
            emit(.mailboxSynced(mailbox: path, newMessages: 0))
            return
        }

        let summaries: [MessageSummary]
        let known: [UInt32: String]
        var vanished: [UInt32]
        var heldBack = false   // an in-flight message changed on the server: look at it again next time
        if let since {
            var changes: MailboxChanges
            if session.resyncMode == .qresync {
                do {
                    changes = try await session.fetchChanges(since: since, vanished: true)
                } catch let error as MailSessionError {
                    // A server that advertises QRESYNC but refuses VANISHED: use CONDSTORE from now on.
                    SyncLog.info("sync \(path): VANISHED refused (\(error.description)), using CONDSTORE")
                    session.resyncMode = .condStore
                    changes = try await session.fetchChanges(since: since, vanished: false)
                }
            } else {
                changes = try await session.fetchChanges(since: since, vanished: false)
            }
            var found = changes.summaries
            var gone = try changes.vanished.map { try store.knownUIDs(accountID: account.id, mailbox: path, in: $0) } ?? []
            var knownChanged = try store.knownFlags(accountID: account.id, mailbox: path, uids: found.map(\.uid))

            // Does the server's count match what we'd have after applying this? If not, something
            // was expunged that we weren't told about (CONDSTORE has no VANISHED), or the local copy
            // drifted: compare UID sets, which also brings back anything missing.
            let stored = try store.serverMessageCount(accountID: account.id, mailbox: path)
            let arriving = found.filter { knownChanged[$0.uid] == nil && !inFlight.sourceUIDs.contains($0.uid) }.count
            let leaving = inFlight.sourceUIDs.filter { uid in uid < provisionalUIDBase && changes.vanished?.contains(uid) != true }.count
            let expected = stored - gone.count + arriving + leaving
            let serverCount = changes.exists ?? selected.exists
            var how = changes.vanished == nil ? "CONDSTORE" : "QRESYNC"
            lastPass[path] = .changes(vanished: changes.vanished != nil, uidCheck: expected != serverCount)
            if expected != serverCount {
                let onServer = try await session.allUIDs()
                let local = try store.knownFlags(accountID: account.id, mailbox: path)
                gone = local.keys.filter { $0 < provisionalUIDBase && !onServer.contains($0) }
                let seen = Set(found.map(\.uid))
                let missing = onServer.ranges.lazy.flatMap { $0 }.filter {
                    local[$0] == nil && !seen.contains($0) && !inFlight.sourceUIDs.contains($0)
                }
                if !missing.isEmpty {
                    found += try await session.fetchSummaries(uids: Array(missing))
                }
                knownChanged = local
                how += " + UID check (expected \(expected), server has \(serverCount))"
            }
            SyncLog.info("sync \(path): \(how) since \(since): \(found.count) changed, \(gone.count) gone")
            summaries = found
            known = knownChanged
            vanished = gone
        } else {
            summaries = try await session.fetchSummaries()
            lastPass[path] = .full
            known = try store.knownFlags(accountID: account.id, mailbox: path)
            let serverUIDs = Set(summaries.map(\.uid))
            vanished = known.keys.filter { !serverUIDs.contains($0) && $0 < provisionalUIDBase }
        }
        if vanished.contains(where: inFlightUIDs.contains) {
            heldBack = true
            vanished.removeAll(where: inFlightUIDs.contains)
        }
        if !vanished.isEmpty { try store.deleteMessages(accountID: account.id, mailbox: path, uids: vanished) }
        if summaries.contains(where: { inFlightUIDs.contains($0.uid) }) { heldBack = true }

        var flagChanges: [UInt32: String] = [:]
        // On a server that doesn't store our keywords, its flags never have them: keep ours.
        let keepOurKeywords = serverKeepsKeywords() == false
        for s in summaries where !inFlightUIDs.contains(s.uid) {
            guard let old = known[s.uid] else { continue }
            var serverFlags = s.flags
            let ours = old.split(separator: " ").map(String.init).filter { Self.isOwnKeyword($0) && !serverFlags.contains($0) }
            if !ours.isEmpty {
                if keepOurKeywords {
                    serverFlags += ours
                } else {
                    SyncLog.info("server dropped \(ours) on \(path) uid \(s.uid): was [\(old)] now [\(s.flags.sorted().joined(separator: " "))] modseq \(s.modSeq.map(String.init) ?? "-")")
                }
            }
            let flags = serverFlags.sorted().joined(separator: " ")
            if old != flags { flagChanges[s.uid] = flags }
        }
        if !flagChanges.isEmpty { try store.updateFlags(accountID: account.id, mailbox: path, changes: flagChanges) }

        // Domains you correspond with: protected from look-alikes, never flagged themselves.
        let trustedDomains = (try? store.correspondentDomains(ownAddresses: Set(account.addresses))) ?? []

        // New messages, newest first, so the top of the stream fills in immediately.
        let new = summaries.filter { known[$0.uid] == nil && !inFlight.sourceUIDs.contains($0.uid) }.sorted { $0.uid > $1.uid }
        var done = 0
        for batch in stride(from: 0, to: new.count, by: batchSize).map({ Array(new[$0..<min($0 + batchSize, new.count)]) }) {
            try Task.checkCancellation()
            let small = batch.filter { $0.size <= largeMessageThreshold }.map(\.uid)
            let large = batch.filter { $0.size > largeMessageThreshold }.map(\.uid)
            var raw = try await session.fetchRaw(uids: small)
            if !large.isEmpty {
                raw.merge(try await session.fetchRaw(uids: large, maxBytes: largeMessagePrefix)) { a, _ in a }
            }
            var items: [(message: StoredMessage, plainText: String)] = []
            for summary in batch {
                guard let data = raw[summary.uid] else { continue }
                let isComplete = summary.size <= largeMessageThreshold
                items.append(try makeMessage(summary: summary, data: data, mailbox: path, validity: selected.uidValidity,
                                             trustedDomains: trustedDomains))
                if isComplete, let date = items.last?.message.date, Date().timeIntervalSince(date) < offlineWindow {
                    try? cache.write(data, account: account.id, mailbox: path, validity: selected.uidValidity ?? 0, uid: summary.uid)
                }
            }
            try store.upsert(items)
            done += batch.count
            emit(.mailboxProgress(mailbox: path, done: done, total: new.count))
        }

        if firstSync {
            try store.markRulesChecked(accountID: account.id, mailbox: path)
        }

        // The state is from the SELECT, before anything above: whatever changed since then is
        // fetched again next time, never missed. A held-back message keeps the old MODSEQ.
        try store.save(MailboxState(
            accountID: account.id, path: path, role: role,
            uidValidity: selected.uidValidity.map(Int64.init), uidNext: selected.uidNext.map(Int64.init),
            highestModSeq: heldBack ? saved?.highestModSeq : selected.highestModSeq.map { Int64(bitPattern: $0) },
            messageCount: selected.exists, lastSync: Date()
        ))
        emit(.mailboxSynced(mailbox: path, newMessages: new.count))
    }

    static let keywordPolicySyncedKey = "keepsKeywordsAtLastSync"

    /// Whether a sync keeps our keywords against the server (`serverKeepsKeywords`) decides the
    /// flags of messages that didn't change on the server, which an incremental sync never looks
    /// at again: when that changes, every mailbox is read in full once.
    func readAllAfterKeywordPolicyChange() throws {
        let now = serverKeepsKeywords().map { $0 ? "true" : "false" } ?? ""
        let synced = try store.setting(Self.keywordPolicySyncedKey, accountID: account.id)
        guard synced != now else { return }
        if synced != nil {
            try store.forgetModSeq(accountID: account.id, mailboxes: Set(try store.mailboxStates(accountID: account.id).map(\.path)))
        }
        try store.setSetting(Self.keywordPolicySyncedKey, now, accountID: account.id)
    }

    /// How many messages the server should hold in this mailbox if the local copy is right:
    /// the stored ones, plus those a queued move is about to take out (their rows already left).
    func expectedServerCount(path: String, inFlight: (sourceUIDs: Set<UInt32>, localIDs: Set<Int64>)) throws -> Int {
        try store.serverMessageCount(accountID: account.id, mailbox: path)
            + inFlight.sourceUIDs.filter { $0 < provisionalUIDBase }.count
    }

    func makeMessage(summary: MessageSummary, data: Data, mailbox: String, validity: UInt32?,
                     trustedDomains: Set<String> = []) throws -> (message: StoredMessage, plainText: String) {
        let parsed = MIMEParser.parse(data)
        let (category, reason) = MessageClassifier(store: store).classify(parsed, userAddresses: Set(account.addresses.map { $0.lowercased() }))
        let from = parsed.from.first
        let threadID = try store.threadID(for: parsed, fallback: "\(account.id)/\(mailbox)/\(validity ?? 0)/\(summary.uid)",
                                          accountID: account.id)
        var message = StoredMessage(
            accountID: account.id, mailbox: mailbox, uid: summary.uid, messageID: parsed.messageID,
            threadID: threadID, subject: parsed.subject.isEmpty ? "(no subject)" : parsed.subject,
            fromName: from?.name, fromAddress: from?.address ?? "",
            recipients: (parsed.to + parsed.cc).map(\.description).joined(separator: ", "),
            date: parsed.date ?? summary.internalDate ?? Date(),
            flags: summary.flags.sorted().joined(separator: " "), size: summary.size,
            hasAttachments: parsed.attachments.contains { !$0.isInline },
            category: category
        )
        message.inReplyTo = parsed.inReplyTo.first
        if let reaction = parsed.reaction {
            message.reactionTo = reaction.target
            message.reactionEmoji = reaction.emoji
        }
        message.reactionsDisallowed = parsed.reactionsDisallowed
        message.attachmentList = parsed.attachments.filter { !$0.isInline }
        let highlights = HighlightExtractor.extract(parsed)
        message.highlights = highlights.isEmpty ? nil : highlights
        if let invite = parsed.invite {
            message.invite = invite
            message.inviteUID = invite.uid
            // Your own answer, sent from here or any other client, shows on the invite.
            if invite.method == .reply, let sender = from?.address,
               account.addresses.contains(where: { $0.caseInsensitiveCompare(sender) == .orderedSame }),
               let answer = invite.attendees.first {
                try? store.recordInviteResponse(InviteResponse(
                    accountID: account.id, uid: invite.uid, sequence: invite.sequence,
                    status: answer.status, respondedAt: parsed.date ?? Date()))
            }
        }
        message.classificationReason = reason.encoded
        (message.isSnoozed, message.snoozedUntil) = SnoozeKeywords.parse(summary.flags)
        let sender = parsed.from.first?.address ?? ""
        let mine = account.addresses.contains { $0.caseInsensitiveCompare(sender) == .orderedSame }
        if !mine, !(try store.isTrustedSender(sender)) {
            let risk = PhishingCheck.evaluate(parsed, trustedDomains: trustedDomains)
            message.riskLevel = risk.level
            message.riskReasons = risk.reasons.isEmpty ? nil : risk.encodedReasons
        }
        return (message, parsed.plainText)
    }

    // MARK: Reading

    /// The raw message for the reading pane: from the cache tier, else fetched (read-only) and cached.
    public func rawMessage(_ message: StoredMessage) async throws -> Data {
        let state = try store.mailboxStates(accountID: account.id).first { $0.path == message.mailbox }
        let validity = UInt32(state?.uidValidity ?? 0)
        if let cached = cache.read(account: account.id, mailbox: message.mailbox, validity: validity, uid: message.uid) {
            return cached
        }
        let data = try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            _ = try await session.select(message.mailbox, readOnly: true)
            return try await session.fetchRaw(uids: [message.uid])[message.uid]
        }
        guard let data else { throw MailSessionError.commandFailed(command: "FETCH", detail: "message is gone from the server") }
        try? cache.write(data, account: account.id, mailbox: message.mailbox, validity: validity, uid: message.uid)
        return data
    }
}

/// Tier 2 (ADR 0001): raw messages on disk, size-capped with least-recently-used eviction.
public struct MessageCache: Sendable {
    public let directory: URL
    public var limitBytes: Int

    public init(directory: URL, limitBytes: Int = 2 << 30) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(account: String, mailbox: String, validity: UInt32, uid: UInt32) -> URL {
        let safeMailbox = mailbox.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "box"
        return directory.appendingPathComponent("\(account)/\(safeMailbox)/\(validity)-\(uid).eml")
    }

    public func read(account: String, mailbox: String, validity: UInt32, uid: UInt32) -> Data? {
        let url = url(account: account, mailbox: mailbox, validity: validity, uid: uid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch for LRU.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func write(_ data: Data, account: String, mailbox: String, validity: UInt32, uid: UInt32) throws {
        let url = url(account: account, mailbox: mailbox, validity: validity, uid: uid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes every cached message of one account (it was removed).
    public func removeAccount(_ account: String) {
        guard !account.isEmpty, !account.contains("/"), account != "..", account != "." else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(account, isDirectory: true))
    }

    /// Evicts least-recently-used files until the cache fits `limitBytes`.
    public func trim() throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int, Date)] = []
        var total = 0
        for case let url as URL in enumerator where url.pathExtension == "eml" {
            let values = try url.resourceValues(forKeys: Set(keys))
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > limitBytes else { return }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= limitBytes { break }
        }
    }
}
