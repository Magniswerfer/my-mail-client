import Foundation
import Logging
import MailEngine

/// The server's core (ADR 0007): one `AccountSync` per account in push-only scope (IDLE on
/// INBOX, Sent and Snoozed polled), a notification pass after each INBOX sync, alerts to every
/// paired device, and the snooze wake-ups and send-later mail the engine already knows how
/// to do. It changes nothing else on the mail server.
public actor PushEngine {
    public nonisolated let config: ServerConfig
    public nonisolated let store: ServerStore
    public nonisolated let mail: MailStore
    let cache: MessageCache
    let secrets: SecretBox
    let sender: any PushSender
    let logger: Logger

    struct Watcher {
        var sync: AccountSync
        var task: Task<Void, Never>
        var events: Task<Void, Never>
    }

    var watchers: [String: Watcher] = [:]
    var statuses: [String: PushAPI.AccountStatus] = [:]
    /// Pushes sent so far (for the status call and tests).
    public private(set) var sentCount = 0

    public static let policyKey = "notificationPolicy.v1"
    /// More than this from one pass become one "N new messages" alert, as on the phone.
    static let burstLimit = 4

    public init(config: ServerConfig, sender: any PushSender, logger: Logger) throws {
        self.config = config
        self.sender = sender
        self.logger = logger
        let dir = config.dataDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ServerStore(path: dir.appendingPathComponent("server.sqlite").path)
        mail = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        cache = MessageCache(directory: dir.appendingPathComponent("cache", isDirectory: true), limitBytes: 64 << 20)
        secrets = try SecretBox(base64: config.masterKey)
    }

    // MARK: Running

    public func start() throws {
        for account in try store.accounts() { try startWatcher(account) }
        logger.info("push engine started", metadata: ["accounts": "\(watchers.count)", "push": "\(sender.isConfigured)"])
    }

    public func stop() async {
        for login in Array(watchers.keys) { await stopWatcher(login) }
        await sender.shutdown()
    }

    func accountConfig(_ account: ServerStore.Account) -> AccountConfig {
        account.record.account(id: account.login)
    }

    var cloudAccounts: CloudAccounts {
        CloudAccounts(((try? store.accounts()) ?? []).map { (id: $0.login, login: $0.login) })
    }

    private func startWatcher(_ account: ServerStore.Account) throws {
        guard let sealed = account.sealedPassword else {
            statuses[account.login] = .init(login: account.login, hasPassword: false, state: "no password", lastSync: nil, error: nil)
            return
        }
        let password = try secrets.open(sealed)
        let sync = AccountSync(account: accountConfig(account), password: password, store: mail, cache: cache, scope: .pushServer)
        let login = account.login
        let poll = config.pollInterval
        // Subscribe before the loop starts, or a fast first sync is over before anyone listens.
        let (started, ready) = AsyncStream<Void>.makeStream()
        let events = Task { [weak self] in
            let stream = await sync.events()
            ready.finish()
            for await event in stream { await self?.handle(event, login: login) }
        }
        let task = Task {
            for await _ in started {}
            await sync.run(pollInterval: poll)
        }
        watchers[login] = Watcher(sync: sync, task: task, events: events)
        statuses[login] = .init(login: login, hasPassword: true, state: "connecting", lastSync: statuses[login]?.lastSync, error: nil)
    }

    private func stopWatcher(_ login: String) async {
        guard let watcher = watchers.removeValue(forKey: login) else { return }
        watcher.task.cancel()
        await watcher.task.value
        watcher.events.cancel()
    }

    // MARK: Events

    func handle(_ event: AccountSync.Event, login: String) async {
        switch event {
        case .started:
            statuses[login]?.state = "syncing"
        case .mailboxSynced(let mailbox, _):
            if mailbox.caseInsensitiveCompare("INBOX") == .orderedSame { await notifyNewMail(login: login) }
        case .idle:
            statuses[login]?.state = "idle"
            statuses[login]?.lastSync = Date()
            statuses[login]?.error = nil
            await notifyNewMail(login: login)
        case .failed(let message):
            statuses[login]?.state = "failed"
            statuses[login]?.error = message
            // The server's own words (an IMAP response or a connection error): never a password.
            logger.warning("account sync failed", metadata: ["account": "\(Self.redacted(login))",
                                                             "error": "\(String(message.prefix(300)))"])
        case .snoozesWoke(let ids):
            await notifyWoke(ids, login: login)
        case .sent(let outboxID):
            try? store.removeScheduled(outboxID: outboxID, login: login)
        case .sendFailed:
            logger.warning("scheduled send failed", metadata: ["account": "\(Self.redacted(login))"])
        case .mailboxProgress, .sending:
            break
        }
    }

    var policy: NotificationPolicy {
        guard let data = try? mail.appliedState(type: StateRecordType.setting.rawValue, key: Self.policyKey),
              let policy = try? JSONDecoder().decode(NotificationPolicy.self, from: data) else { return NotificationPolicy() }
        return policy
    }

    func notifyNewMail(login: String) async {
        guard let sync = watchers[login]?.sync else { return }
        do {
            // State that waited for this mail (a mute, a snooze time) first.
            try mail.applyPendingCloudChanges(accounts: cloudAccounts)
            let found = try await sync.notificationPass(policy: policy)
            guard !found.isEmpty else { return }
            logger.info("new mail to notify", metadata: ["account": "\(Self.redacted(login))", "count": "\(found.count)"])
            if found.count > Self.burstLimit {
                let senders = Array(Set(found.map(\.sender))).sorted().prefix(4).joined(separator: ", ")
                await broadcast(Push(title: "\(found.count) new messages", body: senders, titleKey: "push.burst",
                                     titleArgs: ["\(found.count)"], threadID: nil, collapseID: nil, category: nil,
                                     info: [PushAPI.PayloadKey.kind: "mail", PushAPI.PayloadKey.account: login]))
                return
            }
            for n in found {
                var info = [PushAPI.PayloadKey.kind: "mail", PushAPI.PayloadKey.account: login]
                info[PushAPI.PayloadKey.messageID] = n.messageID
                await broadcast(Push(title: n.sender, body: n.subject.isEmpty ? "—" : n.subject, threadID: n.threadID,
                                     collapseID: n.messageID.map { PushAPI.collapseID(account: login, messageID: $0) },
                                     category: "mail", info: info))
            }
        } catch {
            logger.error("notification pass failed: \(error)")
        }
    }

    func notifyWoke(_ ids: [Int64], login: String) async {
        let messages = ids.compactMap { try? mail.message(id: $0) }
        var seen = Set<String>()
        for m in messages.sorted(by: { $0.date > $1.date }) where seen.insert(m.threadID ?? "\(m.id ?? 0)").inserted {
            var info = [PushAPI.PayloadKey.kind: "wake", PushAPI.PayloadKey.account: login]
            info[PushAPI.PayloadKey.messageID] = m.messageID
            await broadcast(Push(title: "Back in your Inbox", body: "\(m.fromName ?? m.fromAddress): \(m.subject)",
                                 titleKey: "Back in your Inbox", threadID: m.threadID,
                                 collapseID: m.messageID.map { "wake-" + PushAPI.collapseID(account: login, messageID: $0) },
                                 category: "mail", info: info))
        }
    }

    func broadcast(_ push: Push) async {
        let devices = (try? store.devices()) ?? []
        for device in devices {
            guard let token = device.apnsToken else { continue }
            let environment = PushAPI.PushEnvironment(rawValue: device.environment ?? "") ?? .production
            switch await sender.send(push, to: token, environment: environment) {
            case .sent:
                sentCount += 1
            case .deviceGone:
                logger.info("push token gone; forgetting it", metadata: ["device": "\(device.id)"])
                try? store.forgetPushToken(token)
            case .failed(let reason):
                logger.warning("push failed: \(reason)", metadata: ["device": "\(device.id)"])
            }
        }
    }

    /// Logs carry who, never what: `ma…@icloud.com`.
    static func redacted(_ login: String) -> String {
        guard let at = login.firstIndex(of: "@") else { return "…" }
        return String(login[..<at].prefix(2)) + "…" + String(login[at...])
    }

    // MARK: API operations

    public enum OperationError: Error, Equatable {
        case badRequest(String)
        case notFound
        case conflict(String)
    }

    public func upsertAccount(login rawLogin: String, _ upload: PushAPI.AccountUpload) async throws {
        let login = rawLogin.lowercased()
        guard login.contains("@") else { throw OperationError.badRequest("login must be an address") }
        let endpoint = upload.record.endpoint
        if !endpoint.useTLS && !config.plaintextHosts.contains(endpoint.host.lowercased()) {
            throw OperationError.badRequest("IMAP without TLS is only allowed to the local test server")
        }
        if let password = upload.password, password.isEmpty { throw OperationError.badRequest("empty password") }
        let sealed = try upload.password.map(secrets.seal)
        let existing = try store.accounts().first { $0.login == login }
        guard sealed != nil || existing?.sealedPassword != nil else {
            throw OperationError.badRequest("the server needs its app-specific password for this account")
        }
        try store.saveAccount(login: login, record: upload.record, sealedPassword: sealed)
        // Restart only when something the connection depends on changed.
        if sealed != nil || existing?.record != upload.record || watchers[login] == nil {
            await stopWatcher(login)
            if let account = try store.accounts().first(where: { $0.login == login }) { try startWatcher(account) }
        }
    }

    public func removeAccount(login rawLogin: String) async throws {
        let login = rawLogin.lowercased()
        let accounts = cloudAccounts
        await stopWatcher(login)
        try mail.deleteAccount(login, cloudAccounts: accounts)
        cache.removeAccount(login)
        try store.removeAccount(login: login)
        statuses[login] = nil
    }

    @discardableResult
    public func applyState(_ records: [StateRecord]) async throws -> CloudApplyReport {
        let report = try mail.applyStateSnapshot(records, accounts: cloudAccounts)
        // A new snooze time or rule: let each connection look again now instead of after its IDLE.
        if report.changedTypes.contains(StateRecordType.messageState.rawValue) {
            for watcher in watchers.values { await watcher.sync.checkNow() }
        }
        return report
    }

    public func schedule(id: String, _ send: PushAPI.ScheduledSend) async throws {
        let login = send.account.lowercased()
        guard let sync = watchers[login]?.sync else { throw OperationError.badRequest("unknown account") }
        if try store.scheduled(id: id) != nil { _ = try await cancelScheduled(id: id) }
        let item = try await sync.queue(send.message, sendAt: send.sendAt, kind: send.kind)
        guard let outboxID = item.id else { throw OperationError.conflict("not queued") }
        try store.setScheduled(id: id, login: login, outboxID: outboxID)
    }

    /// False when it's already sending or sent (too late).
    public func cancelScheduled(id: String) async throws -> Bool {
        guard let (login, outboxID) = try store.scheduled(id: id) else { throw OperationError.notFound }
        guard let sync = watchers[login]?.sync else {
            try store.removeScheduled(id: id)
            return true
        }
        guard try await sync.cancelSend(id: outboxID) != nil else { return false }
        try mail.deleteOutboxItem(id: outboxID)
        try store.removeScheduled(id: id)
        return true
    }

    public func status() throws -> PushAPI.ServerStatus {
        let accounts = try store.accounts().map { account in
            statuses[account.login] ?? .init(login: account.login, hasPassword: account.sealedPassword != nil,
                                              state: "stopped", lastSync: nil, error: nil)
        }
        return PushAPI.ServerStatus(version: PushServerVersion.current, pushConfigured: sender.isConfigured,
                                    devices: try store.devices().count, scheduled: try store.scheduledCount(), accounts: accounts)
    }
}

public enum PushServerVersion {
    public static let current = "0.1.0"
}

extension ServerStore {
    func removeScheduled(outboxID: Int64, login: String) throws {
        try db.write {
            try $0.execute(sql: "DELETE FROM scheduled WHERE outboxID = ? AND login = ?", arguments: [outboxID, login])
        }
    }
}
