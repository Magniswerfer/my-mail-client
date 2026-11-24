import Foundation
import GRDB

/// A sending identity (SPEC §9): an address you can send from, with its signature.
public struct Identity: Sendable, Codable, Hashable, Identifiable {
    public var id: String { address.lowercased() }
    public var address: String
    public var name: String
    public var signature: String

    public init(address: String, name: String, signature: String = "") {
        self.address = address
        self.name = name
        self.signature = signature
    }

    public var mailAddress: MailAddress { MailAddress(name: name.isEmpty ? nil : name, address: address) }
}

/// What a draft answers, so the original can be marked \Answered / $Forwarded once sent.
public enum ComposeKind: String, Sendable, Codable {
    case new, reply, replyAll, forward
}

/// A draft or a message on its way out.
public struct OutboxItem: Sendable, Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"

    public enum State: String, Sendable, Codable, DatabaseValueConvertible {
        case draft      // being written
        case queued     // waiting for sendAt (the undo window, or send later)
        case sending
        case failed     // permanent failure; needs the user
    }

    public var id: Int64?
    public var accountID: String
    public var state: State
    public var payload: Data
    public var sendAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var lastError: String?
    public var kind: ComposeKind
    /// Local id of the message being replied to / forwarded.
    public var originalLocalID: Int64?

    public var message: OutgoingMessage? {
        get { try? JSONDecoder().decode(OutgoingMessage.self, from: payload) }
        set { if let newValue, let data = try? JSONEncoder().encode(newValue) { payload = data } }
    }

    public init(accountID: String, message: OutgoingMessage, state: State, sendAt: Date? = nil,
                kind: ComposeKind = .new, originalLocalID: Int64? = nil) {
        self.accountID = accountID
        self.state = state
        self.payload = (try? JSONEncoder().encode(message)) ?? Data()
        self.sendAt = sendAt
        self.createdAt = Date()
        self.updatedAt = Date()
        self.attempts = 0
        self.kind = kind
        self.originalLocalID = originalLocalID
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension MailStore {
    static func registerOutboxMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v4-outbox") { db in
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("sendAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("kind", .text).notNull()
                t.column("originalLocalID", .integer)
            }
            try db.create(index: "outbox_due", on: "outbox", columns: ["state", "sendAt"])
            try db.create(table: "accountSetting") { t in
                t.column("accountID", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["accountID", "key"])
            }
        }
    }

    // MARK: Outbox

    @discardableResult
    public func save(_ item: OutboxItem) throws -> OutboxItem {
        var item = item
        item.updatedAt = Date()
        try db.write { db in
            if item.id == nil { try item.insert(db) } else { try item.update(db) }
        }
        return item
    }

    public func outboxItem(id: Int64) throws -> OutboxItem? {
        try db.read { try OutboxItem.fetchOne($0, key: id) }
    }

    public func deleteOutboxItem(id: Int64) throws {
        _ = try db.write { try OutboxItem.deleteOne($0, key: id) }
    }

    /// Everything that isn't a draft: queued, sending, failed.
    public func outbox(accountID: String? = nil) throws -> [OutboxItem] {
        try db.read { db in
            var request = OutboxItem.filter(Column("state") != OutboxItem.State.draft.rawValue)
            if let accountID { request = request.filter(Column("accountID") == accountID) }
            return try request.order(Column("sendAt")).fetchAll(db)
        }
    }

    public func drafts() throws -> [OutboxItem] {
        try db.read { try OutboxItem.filter(Column("state") == OutboxItem.State.draft.rawValue).order(Column("updatedAt").desc).fetchAll($0) }
    }

    func dueOutbox(accountID: String, now: Date = Date()) throws -> [OutboxItem] {
        try db.read {
            try OutboxItem
                .filter(Column("accountID") == accountID && Column("state") == OutboxItem.State.queued.rawValue && Column("sendAt") <= now)
                .order(Column("sendAt")).fetchAll($0)
        }
    }

    func nextOutboxSend(accountID: String) throws -> Date? {
        try db.read {
            try Date.fetchOne($0, sql: "SELECT min(sendAt) FROM outbox WHERE accountID = ? AND state = 'queued'", arguments: [accountID])
        }
    }

    /// A crash mid-send leaves rows in `sending`; put them back so they're retried.
    func resetInterruptedSends(accountID: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE outbox SET state = 'queued' WHERE accountID = ? AND state = 'sending'", arguments: [accountID])
        }
    }

    // MARK: Settings

    func setting(_ key: String, accountID: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM accountSetting WHERE accountID = ? AND key = ?", arguments: [accountID, key]) }
    }

    func setSetting(_ key: String, _ value: String, accountID: String) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO accountSetting (accountID, key, value) VALUES (?, ?, ?)", arguments: [accountID, key, value])
        }
    }
}

extension MailStore {
    /// Address suggestions for the composer: people you've exchanged mail with, most frequent first.
    public func contacts(matching query: String, limit: Int = 8) throws -> [MailAddress] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT max(fromName) AS name, lower(fromAddress) AS address, count(*) AS n FROM message
                WHERE fromAddress != '' AND (lower(fromAddress) LIKE ? OR lower(fromName) LIKE ?)
                GROUP BY lower(fromAddress) ORDER BY n DESC LIMIT ?
                """, arguments: ["%\(q)%", "%\(q)%", limit]).map {
                MailAddress(name: $0["name"], address: $0["address"])
            }
        }
    }
}
