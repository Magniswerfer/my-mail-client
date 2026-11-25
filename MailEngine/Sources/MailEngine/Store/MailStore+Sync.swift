import Foundation
import GRDB

/// Sync bookkeeping per mailbox.
public struct MailboxState: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mailboxState"
    public var accountID: String
    public var path: String
    public var role: MailboxRole?
    public var uidValidity: Int64?
    public var uidNext: Int64?
    public var highestModSeq: Int64?
    public var messageCount: Int
    public var lastSync: Date?
}

/// A conversation as shown in the stream: its newest message in the mailbox plus counts.
public struct ThreadSummary: Sendable, Hashable, Identifiable {
    public var id: String { threadID }
    public var threadID: String
    public var latest: StoredMessage
    public var messageCount: Int
    public var unreadCount: Int
    public var participants: [String]
    /// Any message in the conversation is \Flagged (Pin, SPEC §4).
    public var isPinned: Bool = false
    /// Marked "Reply Later" (any message carries the keyword).
    public var isReplyLater: Bool = false
    /// When the conversation entered the mailbox; for a returned snooze, when it came back.
    public var arrivedAt: Date
    public var snoozedUntil: Date?
}

extension MailStore {
    static func registerSyncMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2-sync") { db in
            try db.create(table: "mailboxState") { t in
                t.column("accountID", .text).notNull()
                t.column("path", .text).notNull()
                t.column("role", .text)
                t.column("uidValidity", .integer)
                t.column("uidNext", .integer)
                t.column("highestModSeq", .integer)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("lastSync", .datetime)
                t.primaryKey(["accountID", "path"])
            }
            try db.alter(table: "message") { t in
                t.add(column: "inReplyTo", .text)
                t.add(column: "classificationReason", .text)
            }
            try db.create(index: "message_mailbox_thread", on: "message", columns: ["accountID", "mailbox", "threadID", "sortKey"])
            try db.create(index: "message_messageID", on: "message", columns: ["messageID"])
        }
    }

    // MARK: Mailbox state

    public func mailboxStates(accountID: String) throws -> [MailboxState] {
        try db.read { try MailboxState.filter(Column("accountID") == accountID).fetchAll($0) }
    }

    public func save(_ state: MailboxState) throws {
        try db.write { try state.save($0) }
    }

    /// UID → flags for every stored message in a mailbox.
    public func knownFlags(accountID: String, mailbox: String) throws -> [UInt32: String] {
        try db.read { db in
            var result: [UInt32: String] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT uid, flags FROM message WHERE accountID = ? AND mailbox = ?",
                                           arguments: [accountID, mailbox])
            while let row = try rows.next() { result[row["uid"]] = row["flags"] }
            return result
        }
    }

    public func updateFlags(accountID: String, mailbox: String, changes: [UInt32: String]) throws {
        try db.write { db in
            for (uid, flags) in changes {
                // Snooze state follows the server keywords (set here or on another device).
                let (snoozed, until) = SnoozeKeywords.parse(flags.split(separator: " ").map(String.init))
                try db.execute(sql: """
                    UPDATE message SET flags = ?, isSnoozed = ?, snoozedUntil = ?
                    WHERE accountID = ? AND mailbox = ? AND uid = ?
                    """, arguments: [flags, snoozed, until, accountID, mailbox, uid])
            }
        }
    }

    func uids(localIDs: Set<Int64>, mailbox: String) throws -> Set<UInt32> {
        guard !localIDs.isEmpty else { return [] }
        let args: [(any DatabaseValueConvertible)?] = [mailbox] + localIDs.map { $0 }
        return try db.read { db in
            Set(try UInt32.fetchAll(db, sql: """
                SELECT uid FROM message WHERE mailbox = ? AND id IN (\(localIDs.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(args)))
        }
    }

    public func deleteMessages(accountID: String, mailbox: String, uids: [UInt32]) throws {
        let ids = try db.read { db in
            try uids.compactMap {
                try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountID = ? AND mailbox = ? AND uid = ?",
                                   arguments: [accountID, mailbox, $0])
            }
        }
        try delete(ids: ids)
    }

    public func deleteMailbox(accountID: String, mailbox: String) throws {
        let ids = try db.read {
            try Int64.fetchAll($0, sql: "SELECT id FROM message WHERE accountID = ? AND mailbox = ?", arguments: [accountID, mailbox])
        }
        try delete(ids: ids)
        try db.write {
            try $0.execute(sql: "DELETE FROM mailboxState WHERE accountID = ? AND path = ?", arguments: [accountID, mailbox])
        }
    }

    // MARK: Threads

    /// Thread key: the root of `References`, else `In-Reply-To`, else the message's own id.
    /// Children carry the root id in References, so a thread converges regardless of arrival order.
    /// An existing message with one of these ids wins, which also links replies whose client
    /// dropped References.
    public func threadID(for parsed: ParsedMessage, fallback: String, accountID: String? = nil) throws -> String {
        // Google and others send updates and cancellations without References; the event UID
        // ties them (and your replies) to the original invitation.
        if let uid = parsed.invite?.uid {
            let known = try db.read { db in
                try String.fetchOne(db, sql: """
                    SELECT threadID FROM message WHERE inviteUID = ? AND (? IS NULL OR accountID = ?)
                    AND threadID IS NOT NULL ORDER BY date LIMIT 1
                    """, arguments: [uid, accountID, accountID])
            }
            if let known { return known }
        }
        let candidates = parsed.references + parsed.inReplyTo
        if !candidates.isEmpty {
            let known = try db.read { db in
                try String.fetchOne(db, sql: """
                    SELECT threadID FROM message WHERE messageID IN (\(candidates.map { _ in "?" }.joined(separator: ",")))
                    AND threadID IS NOT NULL LIMIT 1
                    """, arguments: StatementArguments(candidates))
            }
            if let known { return known }
            return candidates[0]
        }
        return parsed.messageID ?? fallback
    }

    /// The stream: newest-first threads that have a message in `mailbox`.
    /// `ownAddresses` are left out of `participants`, so a thread reads "Anna", not "Anna, Magnus".
    public func threads(mailbox: String, accountID: String? = nil, ownAddresses: Set<String> = [], limit: Int = 500) throws -> [ThreadSummary] {
        try db.read { db in
            var args: [any DatabaseValueConvertible] = [mailbox]
            var accountFilter = ""
            if let accountID { accountFilter = "AND accountID = ?"; args.append(accountID) }
            // A snoozed conversation that came back sorts by when it came back (surfacedAt).
            let latestRows = try Row.fetchAll(db, sql: """
                SELECT m.*, t.arrived AS arrived FROM message m JOIN (
                    SELECT threadID, max(sortKey) AS k, max(coalesce(surfacedAt, date)) AS arrived FROM message
                    WHERE mailbox = ? \(accountFilter) GROUP BY threadID
                ) t ON m.sortKey = t.k
                ORDER BY t.arrived DESC LIMIT \(limit)
                """, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? }))
            let latest = try latestRows.map { try StoredMessage(row: $0) }
            var arrived: [String: Date] = [:]
            for row in latestRows { if let t: String = row["threadID"] { arrived[t] = row["arrived"] } }
            return try Self.summaries(latest: latest, arrived: arrived, ownAddresses: ownAddresses, db: db)
        }
    }

    /// Conversations for search results and smart folders: each represented by the given
    /// message (the newest that matched), wherever it is, newest first as given.
    public func threads(representedBy messageIDs: [Int64], ownAddresses: Set<String> = []) throws -> [ThreadSummary] {
        guard !messageIDs.isEmpty else { return [] }
        return try db.read { db in
            let byID = Dictionary(uniqueKeysWithValues: try StoredMessage.fetchAll(db, keys: messageIDs).compactMap { m in m.id.map { ($0, m) } })
            let latest = messageIDs.compactMap { byID[$0] }
            return try Self.summaries(latest: latest, arrived: [:], ownAddresses: ownAddresses, db: db)
        }
    }

    /// Thread rows for the given newest messages: counts, people, pin/snooze/Reply Later.
    static func summaries(latest: [StoredMessage], arrived: [String: Date], ownAddresses: Set<String>, db: Database) throws -> [ThreadSummary] {
        do {
            let threadIDs = latest.compactMap(\.threadID)
            guard !threadIDs.isEmpty else { return [] }
            var counts: [String: (Int, Int, [String])] = [:]
            var extras: [String: (pinned: Bool, snoozed: Date?, replyLater: Bool)] = [:]
            // An empty IN () is invalid SQL; a never-matching placeholder keeps the query uniform.
            let own = ownAddresses.isEmpty ? [""] : ownAddresses.map { $0.lowercased() }
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadID, count(*) AS n, sum(instr(flags, '\\Seen') = 0) AS unread,
                       max(instr(flags, '\\Flagged') > 0) AS pinned, max(snoozedUntil) AS snoozed,
                       max(instr(flags, '\(replyLaterKeyword)') > 0) AS replyLater,
                       group_concat(DISTINCT CASE WHEN lower(fromAddress) IN (\(own.map { _ in "?" }.joined(separator: ",")))
                                                  THEN NULL ELSE coalesce(fromName, fromAddress) END) AS people
                FROM message WHERE threadID IN (\(threadIDs.map { _ in "?" }.joined(separator: ",")))
                GROUP BY threadID
                """, arguments: StatementArguments(own + threadIDs))
            for row in rows {
                let people = (row["people"] as String?)?.split(separator: ",").map(String.init) ?? []
                counts[row["threadID"]] = (row["n"], row["unread"] ?? 0, people)
                extras[row["threadID"]] = ((row["pinned"] as Int? ?? 0) == 1, row["snoozed"], (row["replyLater"] as Int? ?? 0) == 1)
            }
            return latest.map { m in
                let key = m.threadID ?? ""
                let c = counts[key] ?? (1, m.flags.contains("\\Seen") ? 0 : 1, [m.fromName ?? m.fromAddress])
                let e = extras[key] ?? (m.flags.contains("\\Flagged"), m.snoozedUntil, m.flags.contains(replyLaterKeyword))
                return ThreadSummary(threadID: key, latest: m, messageCount: c.0, unreadCount: c.1, participants: c.2,
                                     isPinned: e.pinned, isReplyLater: e.replyLater, arrivedAt: arrived[key] ?? m.date,
                                     snoozedUntil: e.snoozed)
            }
        }
    }

    /// All messages of a thread across mailboxes (incl. Sent), oldest first.
    public func messages(inThread threadID: String) throws -> [StoredMessage] {
        try db.read {
            try StoredMessage.fetchAll($0, sql: "SELECT * FROM message WHERE threadID = ? ORDER BY date", arguments: [threadID])
        }
    }

    public func message(id: Int64) throws -> StoredMessage? {
        try db.read { try StoredMessage.fetchOne($0, key: id) }
    }

    /// By Message-ID (for tidings:// links); the copy in the Inbox wins over Sent/Archive.
    public func message(messageID: String) throws -> StoredMessage? {
        let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return try db.read {
            try StoredMessage.fetchOne($0, sql: """
                SELECT * FROM message WHERE messageID = ? ORDER BY mailbox = 'INBOX' DESC, date DESC LIMIT 1
                """, arguments: [id])
        }
    }

    public func counts(accountID: String) throws -> [String: Int] {
        try db.read { db in
            var result: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT mailbox, count(*) AS n FROM message WHERE accountID = ? GROUP BY mailbox", arguments: [accountID]) {
                result[row["mailbox"]] = row["n"]
            }
            return result
        }
    }
}
