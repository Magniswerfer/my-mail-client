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

/// What sync must not touch yet in one mailbox: source UIDs of queued moves, and rows with
/// queued changes (their local state already shows the result).
struct InFlightChanges {
    var sourceUIDs: Set<UInt32> = []
    var localIDs: Set<Int64> = []

    /// Real (non-provisional) source UIDs: messages still on the server that a queued move takes out.
    var serverSourceUIDs: Set<UInt32> { sourceUIDs.filter { $0 < provisionalUIDBase } }
}

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
        try db.read { try snapshotsIn($0, localIDs: localIDs) }
    }

    func snapshotsIn(_ db: Database, localIDs: [Int64]) throws -> [MessageSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT id, mailbox, uid, flags, surfacedAt, snoozedUntil FROM message
            WHERE id IN (\(localIDs.sqlPlaceholders))
            """, arguments: StatementArguments(localIDs)).map {
            MessageSnapshot(localID: $0["id"], mailbox: $0["mailbox"], uid: $0["uid"], flags: $0["flags"],
                            surfacedAt: $0["surfacedAt"], snoozedUntil: $0["snoozedUntil"])
        }
    }

    /// Messages of the given threads in one mailbox (e.g. the INBOX part of a conversation).
    public func localIDs(threadIDs: [String], mailbox: String?, accountID: String) throws -> [Int64] {
        guard !threadIDs.isEmpty else { return [] }
        return try db.read { db in
            var sql = "SELECT id FROM message WHERE accountID = ? AND threadID IN (\(threadIDs.sqlPlaceholders))"
            var args: [any DatabaseValueConvertible] = [accountID] + threadIDs
            if let mailbox { sql += " AND mailbox = ?"; args.append(mailbox) }
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? }))
        }
    }

    /// The conversations these messages belong to.
    func threadIDs(localIDs: [Int64]) throws -> [String] {
        guard !localIDs.isEmpty else { return [] }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT threadID FROM message WHERE id IN (\(localIDs.sqlPlaceholders))",
                                arguments: StatementArguments(localIDs))
        }
    }

    func locations(localIDs: [Int64]) throws -> [(mailbox: String, uid: UInt32)] {
        guard !localIDs.isEmpty else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: "SELECT mailbox, uid FROM message WHERE id IN (\(localIDs.sqlPlaceholders))",
                             arguments: StatementArguments(localIDs)).map { ($0["mailbox"], $0["uid"]) }
        }
    }

    // MARK: Optimistic local changes

    /// The placeholder UID a moved row carries until the server reports the real one; unique
    /// per row because it comes from the row id.
    static func provisionalUID(forRow id: Int64) -> UInt32 {
        provisionalUIDBase + UInt32(truncatingIfNeeded: id & Int64(~provisionalUIDBase))
    }

    /// Applies a move locally: the row moves now, with a provisional UID until the server answers.
    func applyLocalMove(localIDs: [Int64], to mailbox: String, flagsAdd: [String], flagsRemove: [String],
                        surfacedAt: Date?? = nil, snooze: (Bool, Date?)? = nil, in db: Database) throws {
        for id in localIDs {
            guard let row = try Row.fetchOne(db, sql: "SELECT flags FROM message WHERE id = ?", arguments: [id]) else { continue }
            let flags = Self.edit(flags: row["flags"], add: flagsAdd, remove: flagsRemove)
            try db.execute(sql: "UPDATE message SET mailbox = ?, uid = ?, flags = ? WHERE id = ?",
                           arguments: [mailbox, Self.provisionalUID(forRow: id), flags, id])
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

    /// An undone move: the row's snooze and surfacing state as before, whatever the flags say now.
    func restoreSnoozeState(_ snapshot: MessageSnapshot, in db: Database) throws {
        try db.execute(sql: "UPDATE message SET surfacedAt = ?, snoozedUntil = ?, isSnoozed = ? WHERE id = ?",
                       arguments: [snapshot.surfacedAt, snapshot.snoozedUntil,
                                   snapshot.flags.contains(SnoozeKeywords.marker), snapshot.localID])
    }

    /// Rows queued for a folder that the server spells differently (`Snoozed` → `INBOX.Snoozed`)
    /// follow the server's spelling.
    func relabelMailbox(accountID: String, from old: String, to new: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE message SET mailbox = ? WHERE accountID = ? AND mailbox = ?",
                           arguments: [new, accountID, old])
        }
    }

    /// Replaces provisional UIDs with the server's (from COPYUID). Without a mapping, or if sync
    /// already stored the destination copy, the placeholder row is dropped and sync refetches it.
    func applyMoveResult(accountID: String, target: String, items: [QueuedAction.MoveItem], mapping: [UInt32: UInt32]) throws {
        try db.write { db in
            for item in items {
                if let newUID = mapping[item.fromUID],
                   try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountID = ? AND mailbox = ? AND uid = ?",
                                      arguments: [accountID, target, newUID]) == nil {
                    try db.execute(sql: "UPDATE message SET uid = ? WHERE id = ?", arguments: [newUID, item.localID])
                } else {
                    try deleteRowsIn(db, ids: [item.localID])
                }
            }
        }
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

    func deletePending(id: Int64) throws {
        _ = try db.write { try PendingAction.deleteOne($0, key: id) }
    }

    func savePending(_ pending: PendingAction) throws {
        try db.write { try pending.update($0) }
    }

    func inFlight(accountID: String, mailbox: String) throws -> InFlightChanges {
        var inFlight = InFlightChanges()
        for pending in try pendingActions(accountID: accountID) {
            switch pending.action {
            case .move(let items, _, _, _, _):
                for item in items {
                    if item.fromMailbox == mailbox { inFlight.sourceUIDs.insert(item.fromUID) }
                    inFlight.localIDs.insert(item.localID)
                }
            case .flags(let localIDs, _, _):
                inFlight.localIDs.formUnion(localIDs)
            case nil: break
            }
        }
        return inFlight
    }

    // MARK: Snoozes

    public func dueSnoozes(accountID: String, now: Date = Date()) throws -> [Int64] {
        try db.read {
            try Int64.fetchAll($0, sql: """
                SELECT id FROM message WHERE accountID = ? AND isSnoozed = 1 AND snoozedUntil IS NOT NULL AND snoozedUntil <= ?
                """, arguments: [accountID, now])
        }
    }

    /// Snoozed conversations that come back after `now`, soonest first (one row per conversation).
    public func upcomingSnoozes(after now: Date = Date(), limit: Int = 20) throws -> [StoredMessage] {
        try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE id IN (
                    SELECT max(id) FROM message WHERE isSnoozed = 1 AND snoozedUntil > ? AND reactionTo IS NULL GROUP BY threadID
                ) ORDER BY snoozedUntil LIMIT ?
                """, arguments: [now, limit])
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

extension QueuedAction {
    /// The messages this change touches.
    var localIDs: Set<Int64> {
        switch self {
        case .move(let items, _, _, _, _): Set(items.map(\.localID))
        case .flags(let ids, _, _): Set(ids)
        }
    }
}
