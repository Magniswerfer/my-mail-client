import Foundation

/// One configured mail account.
public struct AccountConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var endpoint: IMAPEndpoint
    /// Addresses that belong to the user (login + custom-domain identities), used to spot "sent by me".
    public var addresses: [String]

    public init(id: String = UUID().uuidString, displayName: String, endpoint: IMAPEndpoint, addresses: [String]) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.addresses = addresses
    }
}

/// Keeps the local store in step with one account. **Read-only in M1**: mailboxes are opened
/// with EXAMINE and bodies fetched with BODY.PEEK, so syncing never marks anything read.
public actor AccountSync {
    public enum Event: Sendable {
        case started
        case mailboxProgress(mailbox: String, done: Int, total: Int)
        case mailboxSynced(mailbox: String, newMessages: Int)
        case idle
        case failed(String)
    }

    public let account: AccountConfig
    public let store: MailStore
    let password: String
    let profile: ServerProfile
    let cache: MessageCache

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

    public init(account: AccountConfig, password: String, store: MailStore, cache: MessageCache, profile: ServerProfile? = nil) {
        self.account = account
        self.password = password
        self.store = store
        self.cache = cache
        self.profile = profile ?? ServerProfile.detect(host: account.endpoint.host)
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
        var backoff: Duration = .seconds(5)
        while !Task.isCancelled {
            do {
                try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
                    try await self.syncAll(session)
                    backoff = .seconds(5)
                    var lastFullSync = ContinuousClock.now
                    while !Task.isCancelled {
                        try self.wakeDueSnoozes()
                        try await self.drain(session)
                        _ = try await session.select("INBOX", readOnly: true)
                        var changed = false
                        if !self.hasPendingWork {
                            self.emit(.idle)
                            let (wake, continuation) = AsyncStream<Void>.makeStream()
                            self.setWake(continuation)
                            changed = try await session.idle(timeout: self.idleTimeout(), wake: wake)
                            self.setWake(nil)
                        }
                        try self.wakeDueSnoozes()
                        try await self.drain(session)
                        if changed {
                            try await self.syncMailbox(session, path: "INBOX", role: .inbox)
                        }
                        if ContinuousClock.now - lastFullSync > pollInterval {
                            try await self.syncAll(session)
                            lastFullSync = .now
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                emit(.failed(String(describing: error)))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
            }
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
        guard let next = try? store.nextSnoozeWake(accountID: account.id) else { return profile.idleRefresh }
        return min(profile.idleRefresh, .seconds(max(1, next.timeIntervalSinceNow)))
    }

    func syncAll(_ session: MailSession) async throws {
        emit(.started)
        try await drain(session)
        let listing = try await session.listMailboxes()
        let roles = MailboxRoleResolver.resolve(listing)
        let order: [MailboxRole] = [.inbox, .sent, .archive, .drafts]
        var paths: [(String, MailboxRole?)] = order.compactMap { role in roles[role].map { ($0, role) } }
        // User folders too (they're part of the mail you search), but not Trash or Junk.
        let skipped = Set([roles[.trash], roles[.junk]].compactMap { $0 })
        for box in listing where !paths.contains(where: { $0.0 == box.path }) && !skipped.contains(box.path)
            && !box.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame })
            && !TestFence.isInsideFence(box.path) {
            paths.append((box.path, nil))
        }
        // Forget mailboxes that disappeared on the server.
        let known = try store.mailboxStates(accountID: account.id)
        for state in known where !listing.contains(where: { $0.path == state.path }) {
            try store.deleteMailbox(accountID: account.id, mailbox: state.path)
        }
        for (path, role) in paths {
            try await syncMailbox(session, path: path, role: role)
        }
    }

    // MARK: One mailbox

    func syncMailbox(_ session: MailSession, path: String, role: MailboxRole?) async throws {
        let selected = try await session.select(path, readOnly: true)
        let saved = try store.mailboxStates(accountID: account.id).first { $0.path == path }
        if let savedValidity = saved?.uidValidity, let validity = selected.uidValidity, savedValidity != Int64(validity) {
            // UIDs are meaningless after a UIDVALIDITY change: start over for this mailbox.
            try store.deleteMailbox(accountID: account.id, mailbox: path)
        }

        // TODO(M2): use CHANGEDSINCE + VANISHED (QRESYNC) instead of a full summary pass.
        let summaries = try await session.fetchSummaries()
        let known = try store.knownFlags(accountID: account.id, mailbox: path)
        let serverUIDs = Set(summaries.map(\.uid))
        // Leave alone whatever a queued triage action is about to change: its source message is
        // still on the server here, and its local row already shows the result.
        let inFlight = try store.inFlight(accountID: account.id, mailbox: path)
        let inFlightUIDs = try store.uids(localIDs: inFlight.localIDs, mailbox: path)

        let vanished = known.keys.filter { !serverUIDs.contains($0) && $0 < provisionalUIDBase && !inFlightUIDs.contains($0) }
        if !vanished.isEmpty { try store.deleteMessages(accountID: account.id, mailbox: path, uids: vanished) }

        var flagChanges: [UInt32: String] = [:]
        for s in summaries where !inFlightUIDs.contains(s.uid) {
            let flags = s.flags.sorted().joined(separator: " ")
            if let old = known[s.uid], old != flags { flagChanges[s.uid] = flags }
        }
        if !flagChanges.isEmpty { try store.updateFlags(accountID: account.id, mailbox: path, changes: flagChanges) }

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
                items.append(try makeMessage(summary: summary, data: data, mailbox: path, validity: selected.uidValidity))
                if isComplete, let date = items.last?.message.date, Date().timeIntervalSince(date) < offlineWindow {
                    try? cache.write(data, account: account.id, mailbox: path, validity: selected.uidValidity ?? 0, uid: summary.uid)
                }
            }
            try store.upsert(items)
            done += batch.count
            emit(.mailboxProgress(mailbox: path, done: done, total: new.count))
        }

        try store.save(MailboxState(
            accountID: account.id, path: path, role: role,
            uidValidity: selected.uidValidity.map(Int64.init), uidNext: selected.uidNext.map(Int64.init),
            highestModSeq: selected.highestModSeq.map { Int64(bitPattern: $0) },
            messageCount: summaries.count, lastSync: Date()
        ))
        emit(.mailboxSynced(mailbox: path, newMessages: new.count))
    }

    func makeMessage(summary: MessageSummary, data: Data, mailbox: String, validity: UInt32?) throws -> (message: StoredMessage, plainText: String) {
        let parsed = MIMEParser.parse(data)
        let decision = SignalClassifier.classify(parsed, userAddresses: Set(account.addresses.map { $0.lowercased() }))
        let from = parsed.from.first
        let threadID = try store.threadID(for: parsed, fallback: "\(account.id)/\(mailbox)/\(validity ?? 0)/\(summary.uid)")
        var message = StoredMessage(
            accountID: account.id, mailbox: mailbox, uid: summary.uid, messageID: parsed.messageID,
            threadID: threadID, subject: parsed.subject.isEmpty ? "(no subject)" : parsed.subject,
            fromName: from?.name, fromAddress: from?.address ?? "",
            recipients: (parsed.to + parsed.cc).map(\.description).joined(separator: ", "),
            date: parsed.date ?? summary.internalDate ?? Date(),
            flags: summary.flags.sorted().joined(separator: " "), size: summary.size,
            hasAttachments: parsed.attachments.contains { !$0.isInline },
            category: decision.category
        )
        message.inReplyTo = parsed.inReplyTo.first
        message.classificationReason = decision.reason
        (message.isSnoozed, message.snoozedUntil) = SnoozeKeywords.parse(summary.flags)
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
