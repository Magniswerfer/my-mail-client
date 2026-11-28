import Foundation
import GRDB

// App state sync (ADR 0006). The engine knows what state there is, what changed since it was
// last in sync, and how to apply what other devices changed. Moving records to and from
// CloudKit is the app's job (CKSyncEngine), so all of this works and is tested without it.

/// One piece of synced state: a type, a key that means the same thing on every device, and
/// a JSON payload.
public struct StateRecord: Codable, Sendable, Hashable {
    public var type: String
    public var key: String
    public var payload: Data
    public var modifiedAt: Date

    public init(type: String, key: String, payload: Data, modifiedAt: Date) {
        self.type = type
        self.key = key
        self.payload = payload
        self.modifiedAt = modifiedAt
    }
}

public enum StateRecordType: String, CaseIterable, Sendable {
    case rule, smartFolder, senderRule, imageTrust, trustedSender, unsubscribed, inviteResponse
    case mute, messageState, correction, aiCategory, aiChoice, setting
    /// "Use as Archive/Sent/Drafts", keyed by login and role.
    case folderRole
    /// An account's settings (servers, addresses, identities), keyed by login. Never a password:
    /// that travels in iCloud Keychain.
    case account
    /// A signature (with its embedded images), keyed by its id.
    case signature
    /// Which signature is used when (one record, key "settings").
    case signatureSettings
    /// What you taught the highlights per sender (one record, key "training").
    case highlightTraining
}

/// A local change waiting to go to the cloud.
public enum CloudChange: Sendable, Hashable {
    case save(StateRecord)
    case delete(type: String, key: String)

    public var type: String { switch self { case .save(let r): r.type; case .delete(let t, _): t } }
    public var key: String { switch self { case .save(let r): r.key; case .delete(_, let k): k } }
}

/// What applying incoming changes did.
public struct CloudApplyReport: Sendable {
    public var applied = 0
    /// Waiting for mail or an account this device doesn't have yet.
    public var deferred = 0
    /// Older than an unsent local change, which wins.
    public var skipped = 0
    /// App settings that changed (the app writes them to its preferences).
    public var settings: [String: Data] = [:]
    /// Accounts another device added or changed, by login (decode with `CloudAccountRecord`).
    public var accounts: [String: Data] = [:]
    /// Logins of accounts another device removed.
    public var removedAccounts: Set<String> = []
    public var changedTypes: Set<String> = []
    public init() {}
}

/// Accounts across devices: local ids are random per device, login addresses aren't.
public struct CloudAccounts: Sendable {
    let loginByID: [String: String]
    let idByLogin: [String: String]

    public init(_ accounts: [(id: String, login: String)]) {
        loginByID = Dictionary(accounts.map { ($0.id, $0.login.lowercased()) }, uniquingKeysWith: { a, _ in a })
        idByLogin = Dictionary(accounts.map { ($0.login.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
    }
}

/// An account as it syncs: everything needed to add it on another device except its local id
/// and its password.
public struct CloudAccountRecord: Codable, Sendable, Hashable {
    public var displayName: String
    public var endpoint: IMAPEndpoint
    public var addresses: [String]
    public var smtp: SMTPEndpoint?
    public var identities: [Identity]?

    public init(_ account: AccountConfig) {
        displayName = account.displayName
        endpoint = account.endpoint
        addresses = account.addresses
        smtp = account.smtp
        identities = account.identities
    }

    /// The account on this device, under a local id.
    public func account(id: String = UUID().uuidString) -> AccountConfig {
        AccountConfig(id: id, displayName: displayName, endpoint: endpoint, addresses: addresses, smtp: smtp, identities: identities)
    }

    /// Stable JSON (sorted keys), so an unchanged account never looks changed.
    public var payload: Data { (try? CloudJSON.data(self)) ?? Data() }

    public init(payload: Data) throws { self = try CloudJSON.value(CloudAccountRecord.self, payload) }
}

// MARK: - Payloads (stable JSON: sorted keys, dates as seconds)

struct CloudJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
    static func data<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    static func value<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try decoder.decode(type, from: data) }
}

struct RulePayload: Codable { var position: Int; var rule: Rule }
struct FolderPayload: Codable { var position: Int; var folder: SmartFolder }
struct SenderRulePayload: Codable { var category: String }
struct NothingPayload: Codable {}
struct FolderRolePayload: Codable { var path: String }
struct UnsubscribedPayload: Codable { var method: String; var at: Date }
struct InvitePayload: Codable { var sequence: Int; var status: String; var respondedAt: Date }
struct ConversationPayload: Codable { var messageIDs: [String] }
struct CorrectionPayload: Codable { var category: String }
struct AICategoryPayload: Codable { var position: Int; var category: AICategory }
struct AIChoicePayload: Codable { var categoryID: String; var isMember: Bool; var messageIDs: [String] }
public struct MessageStatePayload: Codable, Sendable, Hashable {
    public var replyLater = false
    public var readLater = false
    public var snoozed = false
    public var snoozeUntil: Date?
    var isEmpty: Bool { !replyLater && !readLater && !snoozed }
}

/// The synced state being gathered: type → key → payload.
struct CloudSnapshot {
    static let signatureSettingsKey = "settings"
    static let highlightTrainingKey = "training"

    private(set) var records: [String: [String: Data]] = [:]

    mutating func put(_ type: StateRecordType, _ key: String, _ payload: Data) {
        records[type.rawValue, default: [:]][key] = payload
    }
}

// MARK: - Store

extension MailStore {
    static func registerCloudMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v21-cloud-state") { db in
            // What this device last knew to be in the cloud, per record.
            try db.create(table: "cloudShadow") { t in
                t.column("type", .text).notNull()
                t.column("key", .text).notNull()
                t.column("payload", .blob).notNull()
                t.primaryKey(["type", "key"])
            }
            // Local changes not yet confirmed by the cloud (payload NULL: a deletion).
            try db.create(table: "cloudOutbox") { t in
                t.column("type", .text).notNull()
                t.column("key", .text).notNull()
                t.column("payload", .blob)
                t.column("modifiedAt", .datetime).notNull()
                t.primaryKey(["type", "key"])
            }
            // Incoming records that wait for mail or an account this device doesn't have yet.
            try db.create(table: "cloudPending") { t in
                t.column("type", .text).notNull()
                t.column("key", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.primaryKey(["type", "key"])
            }
            // The transport's own state (CKSyncEngine's serialization).
            try db.create(table: "cloudMeta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .blob).notNull()
            }
            // Reply Later, Read Later and snooze wake times: the truth on this device, re-applied
            // onto flags after every mail sync (iCloud drops our keywords; ADR 0006).
            try db.create(table: "messageState") { t in
                t.column("account", .text).notNull()     // login address
                t.column("messageID", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.primaryKey(["account", "messageID"])
            }
        }
    }

    /// The tables that hold rows per synced record (type, key).
    static let cloudRecordTables = ["cloudShadow", "cloudOutbox", "cloudPending"]

    public func cloudMeta(_ key: String) throws -> Data? {
        try db.read { try Data.fetchOne($0, sql: "SELECT value FROM cloudMeta WHERE key = ?", arguments: [key]) }
    }

    public func setCloudMeta(_ key: String, _ value: Data?) throws {
        try db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO cloudMeta (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM cloudMeta WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: Snapshot: all synced state as records

    /// type → key → payload, for everything that syncs. `settings`: the app's own preferences.
    /// `accountRecords`: the app's accounts by login (`CloudAccountRecord.payload`).
    func cloudSnapshot(accounts: CloudAccounts, settings: [String: Data],
                       accountRecords: [String: Data] = [:]) throws -> [String: [String: Data]] {
        var snapshot = CloudSnapshot()
        for (login, payload) in accountRecords { snapshot.put(.account, login.lowercased(), payload) }
        try snapshotOrderedLists(into: &snapshot)
        try db.read { db in
            try Self.snapshotSenderState(db, into: &snapshot)
            try Self.snapshotConversationState(db, accounts: accounts, into: &snapshot)
            try Self.snapshotAccountState(db, accounts: accounts, into: &snapshot)
        }
        try snapshotSingletons(into: &snapshot)
        for (key, value) in settings { snapshot.put(.setting, key, value) }
        return snapshot.records
    }

    /// Rules, smart folders, AI categories and signatures, each with its position in the list.
    private func snapshotOrderedLists(into snapshot: inout CloudSnapshot) throws {
        for (i, rule) in try rules().enumerated() {
            snapshot.put(.rule, rule.id, try CloudJSON.data(RulePayload(position: i, rule: rule)))
        }
        for (i, folder) in try smartFolders().enumerated() {
            snapshot.put(.smartFolder, folder.id, try CloudJSON.data(FolderPayload(position: i, folder: folder)))
        }
        for (i, category) in try aiCategories().enumerated() {
            snapshot.put(.aiCategory, category.id, try CloudJSON.data(AICategoryPayload(position: i, category: category)))
        }
        for (i, signature) in try signatures().enumerated() {
            snapshot.put(.signature, signature.id, try CloudJSON.data(SignaturePayload(position: i, signature: signature)))
        }
    }

    /// State keyed by a sender's address.
    private static func snapshotSenderState(_ db: Database, into snapshot: inout CloudSnapshot) throws {
        let nothing = try CloudJSON.data(NothingPayload())
        for row in try Row.fetchAll(db, sql: "SELECT address, category FROM senderRule") {
            snapshot.put(.senderRule, row["address"], try CloudJSON.data(SenderRulePayload(category: row["category"])))
        }
        for sender in try String.fetchAll(db, sql: "SELECT sender FROM imageTrust") { snapshot.put(.imageTrust, sender, nothing) }
        for address in try String.fetchAll(db, sql: "SELECT address FROM trustedSender") { snapshot.put(.trustedSender, address, nothing) }
        for row in try Row.fetchAll(db, sql: "SELECT address, method, at FROM unsubscribed") {
            snapshot.put(.unsubscribed, row["address"], try CloudJSON.data(UnsubscribedPayload(method: row["method"], at: row["at"])))
        }
    }

    /// State about messages and conversations, keyed by Message-IDs (the same on every device).
    private static func snapshotConversationState(_ db: Database, accounts: CloudAccounts,
                                                  into snapshot: inout CloudSnapshot) throws {
        for row in try Row.fetchAll(db, sql: "SELECT accountID, uid, sequence, status, respondedAt FROM inviteResponse") {
            guard let login = accounts.loginByID[row["accountID"]] else { continue }
            snapshot.put(.inviteResponse, "\(login)|\(row["uid"] as String)",
                         try CloudJSON.data(InvitePayload(sequence: row["sequence"], status: row["status"], respondedAt: row["respondedAt"])))
        }
        for threadID in try String.fetchAll(db, sql: "SELECT threadID FROM mutedThread") {
            let ids = try messageIDs(inThread: threadID, db)
            guard let root = ids.first else { continue }
            snapshot.put(.mute, root, try CloudJSON.data(ConversationPayload(messageIDs: ids)))
        }
        for row in try Row.fetchAll(db, sql: "SELECT account, messageID, payload FROM messageState") {
            snapshot.put(.messageState, "\(row["account"] as String)|\(row["messageID"] as String)", row["payload"])
        }
        // "Move this conversation" corrections (the classifier's strongest labels).
        for row in try Row.fetchAll(db, sql: """
            SELECT accountID, messageID, category FROM message
            WHERE classificationReason LIKE 'moved|%' AND messageID IS NOT NULL
            """) {
            guard let login = accounts.loginByID[row["accountID"]] else { continue }
            snapshot.put(.correction, "\(login)|\(row["messageID"] as String)", try CloudJSON.data(CorrectionPayload(category: row["category"])))
        }
        // Your ✓/✗ in AI categories (not the model's own picks).
        for row in try Row.fetchAll(db, sql: "SELECT categoryID, threadID, source FROM aiCategoryMember WHERE source != 0") {
            let ids = try messageIDs(inThread: row["threadID"], db)
            guard let root = ids.first else { continue }
            let categoryID: String = row["categoryID"]
            snapshot.put(.aiChoice, "\(categoryID)|\(root)",
                         try CloudJSON.data(AIChoicePayload(categoryID: categoryID, isMember: (row["source"] as Int) > 0, messageIDs: ids)))
        }
    }

    /// Per-account choices, keyed by login.
    private static func snapshotAccountState(_ db: Database, accounts: CloudAccounts, into snapshot: inout CloudSnapshot) throws {
        // Folders you chose for a role ("role.archive" → "INBOX.Done"); empty means none.
        for row in try Row.fetchAll(db, sql: "SELECT accountID, key, value FROM accountSetting WHERE key LIKE 'role.%' AND value != ''") {
            guard let login = accounts.loginByID[row["accountID"]] else { continue }
            let role = String((row["key"] as String).dropFirst("role.".count))
            snapshot.put(.folderRole, "\(login)|\(role)", try CloudJSON.data(FolderRolePayload(path: row["value"])))
        }
    }

    /// One-record types, left out while they're still at their defaults.
    private func snapshotSingletons(into snapshot: inout CloudSnapshot) throws {
        let signatureSettings = try signatureSettings()
        if signatureSettings != SignatureSettings() {
            snapshot.put(.signatureSettings, CloudSnapshot.signatureSettingsKey, try CloudJSON.data(signatureSettings))
        }
        let highlightTraining = try highlightTraining()
        if !highlightTraining.rules.isEmpty {
            snapshot.put(.highlightTraining, CloudSnapshot.highlightTrainingKey, try CloudJSON.data(highlightTraining))
        }
    }

    /// At most this many of a conversation's Message-IDs travel with a mute or an AI choice.
    static let conversationMessageIDLimit = 40

    /// A conversation's Message-IDs, oldest first (its first one is its key across devices).
    static func messageIDs(inThread threadID: String, _ db: Database) throws -> [String] {
        var seen = Set<String>()
        return try String.fetchAll(db, sql: """
            SELECT messageID FROM message WHERE threadID = ? AND messageID IS NOT NULL ORDER BY date LIMIT ?
            """, arguments: [threadID, conversationMessageIDLimit]).filter { seen.insert($0).inserted }
    }

    // MARK: Collecting local changes

    /// The date of a change to state that existed before it was ever synced: older than
    /// anything in the cloud, so on a device joining an account that already syncs, the
    /// cloud's version wins.
    static let neverSyncedChangeDate = Date(timeIntervalSince1970: 1)

    /// Compares the state now with what was last in sync, and queues the differences.
    @discardableResult
    public func collectCloudChanges(accounts: CloudAccounts, settings: [String: Data] = [:],
                                    accountRecords: [String: Data] = [:], now: Date = Date()) throws -> Int {
        let current = try cloudSnapshot(accounts: accounts, settings: settings, accountRecords: accountRecords)
        return try db.write { db in
            var shadow: [String: [String: Data]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT type, key, payload FROM cloudShadow") {
                shadow[row["type"], default: [:]][row["key"]] = row["payload"]
            }
            // A nil payload is a queued deletion.
            var outbox: [String: [String: Data?]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT type, key, payload FROM cloudOutbox") {
                outbox[row["type"], default: [:]][row["key"]] = row["payload"] as Data?
            }
            var queued = 0
            for (type, records) in current {
                for (key, payload) in records {
                    let synced = shadow[type]?[key]
                    if synced == payload {
                        // Back to what the cloud has: nothing to send.
                        if outbox[type]?[key] != nil { try Self.deleteCloudRow(db, from: "cloudOutbox", type: type, key: key) }
                        continue
                    }
                    if let pending = outbox[type]?[key], pending == payload { continue }
                    try Self.queueCloudChange(db, type: type, key: key, payload: payload,
                                              at: synced == nil ? Self.neverSyncedChangeDate : now)
                    queued += 1
                }
            }
            for (type, records) in shadow {
                for key in records.keys where current[type]?[key] == nil {
                    if case .some(nil) = outbox[type]?[key] { continue }   // its deletion is queued already
                    try Self.queueCloudChange(db, type: type, key: key, payload: nil, at: now)
                    queued += 1
                }
            }
            return queued
        }
    }

    /// `payload` nil queues a deletion.
    private static func queueCloudChange(_ db: Database, type: String, key: String, payload: Data?, at date: Date) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO cloudOutbox (type, key, payload, modifiedAt) VALUES (?, ?, ?, ?)",
                       arguments: [type, key, payload, date])
    }

    /// Removes one record's row from a cloud bookkeeping table.
    static func deleteCloudRow(_ db: Database, from table: String, type: String, key: String) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE type = ? AND key = ?", arguments: [type, key])
    }

    /// Queued local changes, oldest first.
    public func pendingCloudChanges(limit: Int = 400) throws -> [CloudChange] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT type, key, payload, modifiedAt FROM cloudOutbox ORDER BY modifiedAt LIMIT ?",
                             arguments: [limit]).map { Self.cloudChange(outboxRow: $0, type: $0["type"], key: $0["key"]) }
        }
    }

    /// The local version of one record, for a save the transport is about to send.
    public func pendingCloudRecord(type: String, key: String) throws -> CloudChange? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT payload, modifiedAt FROM cloudOutbox WHERE type = ? AND key = ?",
                             arguments: [type, key]).map { Self.cloudChange(outboxRow: $0, type: type, key: key) }
        }
    }

    private static func cloudChange(outboxRow row: Row, type: String, key: String) -> CloudChange {
        guard let payload = row["payload"] as Data? else { return .delete(type: type, key: key) }
        return .save(StateRecord(type: type, key: key, payload: payload, modifiedAt: row["modifiedAt"]))
    }

    /// The cloud has this version now.
    public func cloudSaved(_ record: StateRecord) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM cloudOutbox WHERE type = ? AND key = ? AND payload = ?",
                           arguments: [record.type, record.key, record.payload])
            try db.execute(sql: "INSERT OR REPLACE INTO cloudShadow (type, key, payload) VALUES (?, ?, ?)",
                           arguments: [record.type, record.key, record.payload])
        }
    }

    /// The cloud deleted it (our deletion went through).
    public func cloudDeleted(type: String, key: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM cloudOutbox WHERE type = ? AND key = ? AND payload IS NULL", arguments: [type, key])
            try db.execute(sql: "DELETE FROM cloudShadow WHERE type = ? AND key = ?", arguments: [type, key])
        }
    }

    /// Forget everything about the cloud (signed out of iCloud, or sync turned off): the next
    /// time sync runs, local state is offered again and the cloud's wins where it has some.
    public func resetCloudState() throws {
        try db.write { db in
            for table in Self.cloudRecordTables + ["cloudMeta"] { try db.execute(sql: "DELETE FROM \(table)") }
        }
    }
}

// MARK: - The push server's copy of your state (ADR 0007)

extension MailStore {
    /// What the push server needs to decide on notifications and wake snoozes: rules (for
    /// "Notify me"), sender rules and corrections (categories), mutes, snooze wake times
    /// (`messageState`), Use As folders and settings (the notification policy). Accounts go
    /// up separately, with their password.
    public static let pushStateTypes: Set<String> = Set([
        StateRecordType.rule, .senderRule, .correction, .mute, .messageState, .folderRole, .trustedSender, .setting,
    ].map(\.rawValue))

    /// Everything of `types` as records, for a device to upload in one piece.
    public func stateSnapshot(types: Set<String> = MailStore.pushStateTypes, accounts: CloudAccounts,
                              settings: [String: Data] = [:], now: Date = Date()) throws -> [StateRecord] {
        try cloudSnapshot(accounts: accounts, settings: settings)
            .filter { types.contains($0.key) }
            .flatMap { type, records in
                records.map { StateRecord(type: type, key: $0.key, payload: $0.value, modifiedAt: now) }
            }
            .sorted { ($0.type, $0.key) < ($1.type, $1.key) }
    }

    /// Makes this store's state of `types` match `records` (a device's whole snapshot): applies
    /// what changed and removes what's gone, through the same path as CloudKit changes, so
    /// state for mail that isn't here yet waits and is applied after a sync.
    @discardableResult
    public func applyStateSnapshot(_ records: [StateRecord], types: Set<String> = MailStore.pushStateTypes,
                                   accounts: CloudAccounts) throws -> CloudApplyReport {
        let records = records.filter { types.contains($0.type) }
        var known: [String: [String: Data]] = [:]
        try db.read { db in
            for table in ["cloudShadow", "cloudPending"] {
                for row in try Row.fetchAll(db, sql: "SELECT type, key, payload FROM \(table)") {
                    let type: String = row["type"]
                    guard types.contains(type) else { continue }
                    known[type, default: [:]][row["key"]] = row["payload"]
                }
            }
        }
        let saves = records.filter { known[$0.type]?[$0.key] != $0.payload }
        let incoming = Dictionary(grouping: records, by: \.type).mapValues { Set($0.map(\.key)) }
        let deletions = known.flatMap { type, keys in
            keys.keys.filter { incoming[type]?.contains($0) != true }.map { (type: type, key: $0) }
        }
        return try applyCloudChanges(saves: saves, deletions: deletions, accounts: accounts)
    }

    /// The payload last applied for one record (say the synced notification policy).
    public func appliedState(type: String, key: String) throws -> Data? {
        try db.read {
            try Data.fetchOne($0, sql: "SELECT payload FROM cloudShadow WHERE type = ? AND key = ?", arguments: [type, key])
        }
    }
}
