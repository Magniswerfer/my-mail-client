import Foundation
import GRDB

/// A server change waiting to be applied, persisted so it survives quits and crashes.
public enum QueuedAction: Codable, Sendable, Hashable {
    /// Move messages from their source location. Flags are changed on the source first,
    /// so keywords (e.g. the snooze wake time) travel with the message.
    case move(items: [MoveItem], to: String, addFlags: [String], removeFlags: [String], createTarget: Bool)
    /// Change flags on messages wherever they currently are.
    case flags(localIDs: [Int64], add: [String], remove: [String])

    public struct MoveItem: Codable, Sendable, Hashable {
        public var localID: Int64
        public var fromMailbox: String
        public var fromUID: UInt32
    }
}

public struct PendingAction: Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pendingAction"
    public var id: Int64?
    public var accountID: String
    public var changeID: String
    public var payload: Data
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public var action: QueuedAction? { try? JSONDecoder().decode(QueuedAction.self, from: payload) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A message row's triage-relevant state, captured before a change so it can be undone.
public struct MessageSnapshot: Sendable, Hashable, Codable {
    public var localID: Int64
    public var mailbox: String
    public var uid: UInt32
    public var flags: String
    public var surfacedAt: Date?
    public var snoozedUntil: Date?
}

/// UIDs at or above this are local placeholders for messages whose move hasn't reached the server.
public let provisionalUIDBase: UInt32 = 0xF000_0000

extension MailStore {
    static func registerTriageMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v3-triage") { db in
            try db.alter(table: "message") { t in
                t.add(column: "surfacedAt", .datetime)
                t.add(column: "snoozedUntil", .datetime)
                t.add(column: "isSnoozed", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "pendingAction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).notNull()
                t.column("changeID", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
            try db.create(index: "message_snooze", on: "message", columns: ["isSnoozed", "snoozedUntil"])
        }
    }

    // MARK: Snapshots

    public func snapshots(localIDs: [Int64]) throws -> [MessageSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, mailbox, uid, flags, surfacedAt, snoozedUntil FROM message
                WHERE id IN (\(localIDs.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(localIDs)).map {
                MessageSnapshot(localID: $0["id"], mailbox: $0["mailbox"], uid: $0["uid"], flags: $0["flags"],
                                surfacedAt: $0["surfacedAt"], snoozedUntil: $0["snoozedUntil"])
            }
        }
    }

    /// Messages of the given threads in one mailbox (e.g. the INBOX part of a conversation).
    public func localIDs(threadIDs: [String], mailbox: String?, accountID: String) throws -> [Int64] {
        guard !threadIDs.isEmpty else { return [] }
        return try db.read { db in
            var sql = "SELECT id FROM message WHERE accountID = ? AND threadID IN (\(threadIDs.map { _ in "?" }.joined(separator: ",")))"
            var args: [any DatabaseValueConvertible] = [accountID] + threadIDs
            if let mailbox { sql += " AND mailbox = ?"; args.append(mailbox) }
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? }))
        }
    }

    // MARK: Optimistic local changes

    /// Applies a move locally: the row moves now, with a provisional UID until the server answers.
    func applyLocalMove(localIDs: [Int64], to mailbox: String, flagsAdd: [String], flagsRemove: [String],
                        surfacedAt: Date?? = nil, snooze: (Bool, Date?)? = nil, in db: Database) throws {
        for id in localIDs {
            guard let row = try Row.fetchOne(db, sql: "SELECT flags FROM message WHERE id = ?", arguments: [id]) else { continue }
            let flags = Self.edit(flags: row["flags"], add: flagsAdd, remove: flagsRemove)
            try db.execute(sql: "UPDATE message SET mailbox = ?, uid = ?, flags = ? WHERE id = ?",
                           arguments: [mailbox, provisionalUIDBase + UInt32(truncatingIfNeeded: id & 0x0FFF_FFFF), flags, id])
            if let surfacedAt {
                try db.execute(sql: "UPDATE message SET surfacedAt = ? WHERE id = ?", arguments: [surfacedAt, id])
            }
            if let (isSnoozed, until) = snooze {
                try db.execute(sql: "UPDATE message SET isSnoozed = ?, snoozedUntil = ? WHERE id = ?", arguments: [isSnoozed, until, id])
            }
        }
    }

    func applyLocalFlags(localIDs: [Int64], add: [String], remove: [String], in db: Database) throws {
        for id in localIDs {
            guard let current = try String.fetchOne(db, sql: "SELECT flags FROM message WHERE id = ?", arguments: [id]) else { continue }
            try db.execute(sql: "UPDATE message SET flags = ? WHERE id = ?",
                           arguments: [Self.edit(flags: current, add: add, remove: remove), id])
        }
    }

    func restore(_ snapshot: MessageSnapshot, in db: Database) throws {
        try db.execute(sql: """
            UPDATE message SET mailbox = ?, uid = ?, flags = ?, surfacedAt = ?, snoozedUntil = ?, isSnoozed = ? WHERE id = ?
            """, arguments: [snapshot.mailbox, snapshot.uid, snapshot.flags, snapshot.surfacedAt, snapshot.snoozedUntil,
                             snapshot.snoozedUntil != nil || snapshot.flags.contains(SnoozeKeywords.marker), snapshot.localID])
    }

    static func edit(flags: String, add: [String], remove: [String]) -> String {
        var set = Set(flags.split(separator: " ").map(String.init))
        set.subtract(remove)
        set.formUnion(add)
        return set.sorted().joined(separator: " ")
    }

    // MARK: Queue

    func enqueue(_ action: QueuedAction, accountID: String, changeID: String, in db: Database) throws {
        var pending = PendingAction(accountID: accountID, changeID: changeID, payload: try JSONEncoder().encode(action),
                                    createdAt: Date(), attempts: 0)
        try pending.insert(db)
    }

    public func pendingActions(accountID: String) throws -> [PendingAction] {
        try db.read {
            try PendingAction.filter(Column("accountID") == accountID).order(Column("id")).fetchAll($0)
        }
    }

    /// What sync must not touch yet: source UIDs of queued moves, and rows with queued flag changes.
    func inFlight(accountID: String, mailbox: String) throws -> (sourceUIDs: Set<UInt32>, localIDs: Set<Int64>) {
        var uids = Set<UInt32>()
        var ids = Set<Int64>()
        for pending in try pendingActions(accountID: accountID) {
            switch pending.action {
            case .move(let items, _, _, _, _):
                for item in items {
                    if item.fromMailbox == mailbox { uids.insert(item.fromUID) }
                    ids.insert(item.localID)
                }
            case .flags(let localIDs, _, _):
                ids.formUnion(localIDs)
            case nil: break
            }
        }
        return (uids, ids)
    }

    // MARK: Snoozes

    public func dueSnoozes(accountID: String, now: Date = Date()) throws -> [Int64] {
        try db.read {
            try Int64.fetchAll($0, sql: """
                SELECT id FROM message WHERE accountID = ? AND isSnoozed = 1 AND snoozedUntil IS NOT NULL AND snoozedUntil <= ?
                """, arguments: [accountID, now])
        }
    }

    public func nextSnoozeWake(accountID: String) throws -> Date? {
        try db.read {
            try Date.fetchOne($0, sql: "SELECT min(snoozedUntil) FROM message WHERE accountID = ? AND isSnoozed = 1",
                              arguments: [accountID])
        }
    }
}

/// Snooze state is mirrored into IMAP keywords so it survives a fresh install and reaches other
/// clients (verified to persist on iCloud in M0, ADR 0002).
public enum SnoozeKeywords {
    public static let marker = "$TidingsSnoozed"
    static let wakePrefix = "$TidingsWake-"

    public static func keywords(until: Date?) -> [String] {
        guard let until else { return [marker] }
        return [marker, wakePrefix + String(Int(until.timeIntervalSince1970))]
    }

    public static func all(in flags: [String]) -> [String] {
        flags.filter { $0 == marker || $0.hasPrefix(wakePrefix) }
    }

    /// Reads (isSnoozed, wake date) back from server flags.
    public static func parse(_ flags: [String]) -> (Bool, Date?) {
        guard flags.contains(marker) else { return (false, nil) }
        let wake = flags.first { $0.hasPrefix(wakePrefix) }
            .flatMap { TimeInterval($0.dropFirst(wakePrefix.count)) }
            .map { Date(timeIntervalSince1970: $0) }
        return (true, wake)
    }
}
