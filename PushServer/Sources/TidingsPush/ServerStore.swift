import Foundation
import GRDB
import MailEngine

/// The server's own small database (`server.sqlite`): paired devices, accounts with their
/// sealed passwords, and send-later hand-offs. Mail lives in a separate `MailStore`.
public final class ServerStore: Sendable {
    let db: DatabaseQueue

    public struct Device: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
        public static let databaseTableName = "device"
        public var id: String
        public var name: String
        public var tokenHash: String
        public var apnsToken: String?
        public var environment: String?
        public var createdAt: Date
        public var lastSeenAt: Date
    }

    public struct Account: Sendable, Hashable {
        public var login: String
        public var record: CloudAccountRecord
        public var sealedPassword: Data?
    }

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("tokenHash", .text).notNull().unique()
                t.column("apnsToken", .text)
                t.column("environment", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
            }
            try db.create(table: "account") { t in
                t.column("login", .text).primaryKey()
                t.column("record", .blob).notNull()
                t.column("sealedPassword", .blob)
                t.column("updatedAt", .datetime).notNull()
            }
            // A device's send-later id → the server outbox row that will send it.
            try db.create(table: "scheduled") { t in
                t.column("id", .text).primaryKey()
                t.column("login", .text).notNull()
                t.column("outboxID", .integer).notNull()
            }
        }
        try migrator.migrate(db)
    }

    // MARK: Devices

    public func addDevice(name: String, now: Date = Date()) throws -> (device: Device, token: String) {
        let token = Tokens.random()
        let device = Device(id: UUID().uuidString, name: String(name.prefix(80)), tokenHash: Tokens.hash(token), apnsToken: nil,
                            environment: nil, createdAt: now, lastSeenAt: now)
        try db.write { try device.insert($0) }
        return (device, token)
    }

    /// The device a bearer token belongs to (and marks it seen).
    public func device(token: String, now: Date = Date()) throws -> Device? {
        try db.write { db in
            guard var device = try Device.filter(Column("tokenHash") == Tokens.hash(token)).fetchOne(db) else { return nil }
            if now.timeIntervalSince(device.lastSeenAt) > 60 {
                device.lastSeenAt = now
                try device.update(db)
            }
            return device
        }
    }

    public func setPushToken(deviceID: String, token: String, environment: String) throws {
        try db.write { db in
            // A token belongs to one device: a reinstall pairs again with the same token.
            try db.execute(sql: "UPDATE device SET apnsToken = NULL WHERE apnsToken = ? AND id != ?", arguments: [token, deviceID])
            try db.execute(sql: "UPDATE device SET apnsToken = ?, environment = ? WHERE id = ?", arguments: [token, environment, deviceID])
        }
    }

    /// APNs said the token is dead (410): stop sending to it.
    public func forgetPushToken(_ token: String) throws {
        try db.write { try $0.execute(sql: "UPDATE device SET apnsToken = NULL WHERE apnsToken = ?", arguments: [token]) }
    }

    public func removeDevice(id: String) throws {
        try db.write { _ = try Device.deleteOne($0, key: id) }
    }

    public func devices() throws -> [Device] {
        try db.read { try Device.order(Column("createdAt")).fetchAll($0) }
    }

    // MARK: Accounts

    public func saveAccount(login: String, record: CloudAccountRecord, sealedPassword: Data?, now: Date = Date()) throws {
        let payload = try JSONEncoder().encode(record)
        try db.write { db in
            if let sealedPassword {
                try db.execute(sql: """
                    INSERT INTO account (login, record, sealedPassword, updatedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(login) DO UPDATE SET record = excluded.record, sealedPassword = excluded.sealedPassword, updatedAt = excluded.updatedAt
                    """, arguments: [login, payload, sealedPassword, now])
            } else {
                try db.execute(sql: """
                    INSERT INTO account (login, record, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(login) DO UPDATE SET record = excluded.record, updatedAt = excluded.updatedAt
                    """, arguments: [login, payload, now])
            }
        }
    }

    public func accounts() throws -> [Account] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT login, record, sealedPassword FROM account ORDER BY login").compactMap { row in
                guard let record = try? JSONDecoder().decode(CloudAccountRecord.self, from: row["record"] as Data) else { return nil }
                return Account(login: row["login"], record: record, sealedPassword: row["sealedPassword"])
            }
        }
    }

    public func removeAccount(login: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM account WHERE login = ?", arguments: [login])
            try db.execute(sql: "DELETE FROM scheduled WHERE login = ?", arguments: [login])
        }
    }

    // MARK: Send later

    public func setScheduled(id: String, login: String, outboxID: Int64) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO scheduled (id, login, outboxID) VALUES (?, ?, ?)", arguments: [id, login, outboxID])
        }
    }

    public func scheduled(id: String) throws -> (login: String, outboxID: Int64)? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT login, outboxID FROM scheduled WHERE id = ?", arguments: [id]).map { ($0["login"], $0["outboxID"]) }
        }
    }

    public func removeScheduled(id: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM scheduled WHERE id = ?", arguments: [id]) }
    }

    public func scheduledIDs() throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT id FROM scheduled ORDER BY id") }
    }

    public func scheduledCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM scheduled") ?? 0 }
    }
}
