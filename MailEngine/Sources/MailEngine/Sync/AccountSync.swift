import Foundation

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
    public var offlineWindow: TimeInterval = 30 * secondsPerDay
    /// Bigger messages get only their first `largeMessagePrefix` bytes fetched for indexing.
    public var largeMessageThreshold = 2_000_000
    public var largeMessagePrefix: UInt32 = 256_000
    /// New messages fetched and stored per round trip.
    public var batchSize = 25

    private static let secondsPerDay: TimeInterval = 86_400

    private var listeners: [UUID: AsyncStream<Event>.Continuation] = [:]
    /// Set when a triage action is queued; the loop drains before its next IDLE.
    var hasPendingWork = false
    private var wakeContinuation: AsyncStream<Void>.Continuation?

    /// Ends an IDLE in progress so queued work reaches the server now.
    func signalWork() {
        hasPendingWork = true
        wakeContinuation?.yield()
    }

    /// Draining the queue and folder changes take turns, so a queued move into a folder reaches
    /// the server before that folder is renamed or deleted (and never runs twice).
    private var serverBusy = false
    private var serverWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireServer() async {
        guard serverBusy else {
            serverBusy = true
            return
        }
        // `releaseServer` hands the turn straight to us (`serverBusy` stays true), so nobody
        // arriving in between can take it: turns go in order.
        await withCheckedContinuation { serverWaiters.append($0) }
    }

    func releaseServer() {
        if serverWaiters.isEmpty {
            serverBusy = false
        } else {
            serverWaiters.removeFirst().resume()
        }
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
    public internal(set) var lastPass: [String: MailboxPass] = [:]

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

    /// How often `run` re-syncs the mailboxes it doesn't IDLE on.
    public static let defaultPollInterval: Duration = .seconds(600)
    /// The pause before reconnecting after a failure; doubled per failure up to `maxBackoff`.
    private static let initialBackoff: Duration = .seconds(5)
    private static let maxBackoff: Duration = .seconds(300)
    /// A due snooze or poll can bring the IDLE timeout near zero; IDLE at least this long.
    private static let minimumIdle: Duration = .seconds(1)

    /// Syncs everything, then IDLEs on INBOX and re-syncs on changes. Other mailboxes are
    /// re-synced every `pollInterval`. Reconnects with backoff on errors. Runs until cancelled.
    public func run(pollInterval: Duration = defaultPollInterval) async {
        do {
            try store.resetInterruptedSends(accountID: account.id)
        } catch {
            SyncLog.info("couldn't reset interrupted sends: \(error)")
        }
        var backoff = Self.initialBackoff
        while !Task.isCancelled {
            do {
                try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
                    try await self.syncAll(session)
                    backoff = Self.initialBackoff
                    try await self.stayInStep(session, pollInterval: pollInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                SyncLog.info("sync loop: \(error); reconnecting in \(backoff)")
                emit(.failed(String(describing: error)))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, Self.maxBackoff)
            }
        }
    }

    /// The connected part of `run`: pushes local work, IDLEs on INBOX, and re-syncs what
    /// changed, until cancelled or the connection fails.
    private func stayInStep(_ session: MailSession, pollInterval: Duration) async throws {
        var lastFullSync = ContinuousClock.now
        while !Task.isCancelled {
            try await pushLocalWork(session)
            _ = try await session.select("INBOX", readOnly: true)
            // Never IDLE past the next poll, so other mailboxes really are re-synced every `pollInterval`.
            let untilPoll = pollInterval - (ContinuousClock.now - lastFullSync)
            let inboxChanged = try await idleUnlessWorkIsWaiting(session, atMost: untilPoll)
            try await pushLocalWork(session)
            if inboxChanged {
                try await syncMailbox(session, path: "INBOX", role: .inbox)
            }
            if fullSyncRequested || ContinuousClock.now - lastFullSync > pollInterval {
                fullSyncRequested = false
                try await syncAll(session)
                lastFullSync = .now
            }
        }
    }

    /// IDLEs on the selected mailbox unless queued work or a full sync is already waiting.
    /// `signalWork` and `checkNow` end it early. Returns whether the server reported a change.
    private func idleUnlessWorkIsWaiting(_ session: MailSession, atMost limit: Duration) async throws -> Bool {
        guard !hasPendingWork && !fullSyncRequested else { return false }
        emit(.idle)
        let (wake, continuation) = AsyncStream<Void>.makeStream()
        wakeContinuation = continuation
        defer { wakeContinuation = nil }
        return try await session.idle(timeout: max(Self.minimumIdle, min(idleTimeout(), limit)), wake: wake)
    }

    /// What this device owes the server, oldest promise first: due snoozes back to the Inbox,
    /// due mail sent, queued triage applied.
    func pushLocalWork(_ session: MailSession) async throws {
        try wakeDueSnoozes()
        try await sendDue(session)
        try await drain(session)
    }

    /// A short-lived catch-up for when the app can't stay connected (iOS background refresh):
    /// wakes due snoozes, sends due mail, pushes queued triage, then syncs. One connection, then done.
    public func catchUp() async throws {
        try store.resetInterruptedSends(accountID: account.id)
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.pushLocalWork(session)
            try await self.syncAll(session)
        }
    }

    /// One full pass over the interesting mailboxes, INBOX first.
    public func syncOnce() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.syncAll(session)
        }
    }

    /// IDLE until the next snooze or scheduled send is due, or the server's refresh interval,
    /// whichever is sooner.
    func idleTimeout() -> Duration {
        let candidates = [try? store.nextSnoozeWake(accountID: account.id), try? store.nextOutboxSend(accountID: account.id)]
            .compactMap { $0 }
        guard let next = candidates.min() else { return profile.idleRefresh }
        return min(profile.idleRefresh, .seconds(max(1, next.timeIntervalSinceNow)))
    }

    // MARK: All mailboxes

    func syncAll(_ session: MailSession) async throws {
        emit(.started)
        try await drain(session)
        let generation = folderGeneration
        let listing = try await session.listMailboxes()
        let roles = try await learnFolderLayout(listing, session)
        let mailboxes = mailboxesToSync(listing, roles: roles)
        // A folder changed while we listed: this listing is stale, start over.
        guard generation == folderGeneration else { fullSyncRequested = true; return }
        try forgetMailboxes(missingFrom: listing)
        for (path, role) in mailboxes {
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

    /// Remembers how the account spells folders (namespace prefix, separator) and resolves
    /// which folder plays which role.
    private func learnFolderLayout(_ listing: [MailboxListing], _ session: MailSession) async throws -> [MailboxRole: String] {
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
        return roles
    }

    /// The special mailboxes first (INBOX leading), then the user's folders.
    private func mailboxesToSync(_ listing: [MailboxListing], roles: [MailboxRole: String]) -> [(path: String, role: MailboxRole?)] {
        // Junk too: the junk filter learns from it, and you can rescue mail from it.
        let order: [MailboxRole] = [.inbox, .sent, .archive, .drafts, .junk]
        var mailboxes: [(path: String, role: MailboxRole?)] = order.compactMap { role in roles[role].map { ($0, role) } }
        // User folders too (they're part of the mail you search), but not Trash.
        for box in listing where !mailboxes.contains(where: { $0.path == box.path }) && box.path != roles[.trash]
            && box.isSelectable && !TestFence.isInsideFence(box.path) {
            mailboxes.append((box.path, nil))
        }
        if scope == .pushServer {
            mailboxes = mailboxes.filter { path, role in role == .inbox || role == .sent || Self.isSnoozedMailbox(path) }
        }
        return mailboxes
    }

    private func forgetMailboxes(missingFrom listing: [MailboxListing]) throws {
        for state in try store.mailboxStates(accountID: account.id) where !listing.contains(where: { $0.path == state.path }) {
            try store.deleteMailbox(accountID: account.id, mailbox: state.path)
        }
    }

    /// Some servers mark two folders with one SPECIAL-USE (Dovecot's default config has both
    /// "Sent" and "Sent Messages" as \Sent). Take the one that holds the mail, not just the
    /// first listed; the other stays an ordinary folder.
    func preferFullest(_ roles: inout [MailboxRole: String], listing: [MailboxListing], session: MailSession) async throws {
        for (attribute, role) in MailboxRoleResolver.specialUse {
            let candidates = listing.filter { $0.has(attribute: attribute) }
            guard candidates.count > 1 else { continue }
            var best: (path: String, count: Int)?
            for box in candidates {
                // A folder that can't be opened holds no mail we could sync.
                let count = (try? await session.select(box.path, readOnly: true).exists) ?? 0
                if best == nil || count > best!.count { best = (box.path, count) }
            }
            if let best { roles[role] = best.path }
        }
    }
}
