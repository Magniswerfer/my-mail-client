import Foundation
import GRDB

/// What a rule did to one message: shown in the rule's history and enough to undo it.
public struct RuleRun: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var at: Date
    public var accountID: String
    public var messageID: Int64
    public var threadID: String
    public var subject: String
    public var sender: String
    public var ruleIDs: [String]
    public var ruleNames: [String]
    public var actions: [RuleAction]
    public var previousCategory: MailCategory
    public var previousReason: String?
    public var undoneAt: Date?
}

extension MailStore {
    static func registerRuleMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v12-rules") { db in
            try db.create(table: "rule") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .text).notNull()
            }
            try db.create(table: "ruleRun") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull()
                t.column("accountID", .text).notNull()
                t.column("messageID", .integer).notNull()
                t.column("threadID", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("ruleIDs", .text).notNull()      // JSON [String]
                t.column("ruleNames", .text).notNull()    // JSON [String]
                t.column("actions", .text).notNull()      // JSON [RuleAction]
                t.column("previousCategory", .text).notNull()
                t.column("previousReason", .text)
                t.column("undoneAt", .datetime)
            }
            try db.create(index: "ruleRun_at", on: "ruleRun", columns: ["at"])
            // Rules only see mail that arrives from now on; what's already here was "checked".
            try db.alter(table: "message") { t in
                t.add(column: "rulesChecked", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE message SET rulesChecked = 1")
        }
    }

    // MARK: Rules

    /// In order.
    public func rules() throws -> [Rule] {
        let decoder = JSONDecoder()
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM rule ORDER BY position, id").compactMap {
                try? decoder.decode(Rule.self, from: Data($0.utf8))
            }
        }
    }

    /// Replaces the whole ordered list (simple, and rules are few).
    public func saveRules(_ rules: [Rule]) throws {
        let encoder = JSONEncoder()
        try db.write { db in
            try db.execute(sql: "DELETE FROM rule")
            for (position, rule) in rules.enumerated() {
                let json = String(decoding: try encoder.encode(rule), as: UTF8.self)
                try db.execute(sql: "INSERT INTO rule (id, position, json) VALUES (?, ?, ?)", arguments: [rule.id, position, json])
            }
        }
    }

    // MARK: Which mail rules see

    /// New Inbox mail no rule pass has seen, oldest first, and the highest id looked at.
    /// Reactions aren't mail: no rules, junk screening or notifications for them.
    func ruleCandidates(accountID: String) throws -> (messages: [StoredMessage], upTo: Int64) {
        try db.read { db in
            let upTo = try Int64.fetchOne(db, sql: "SELECT max(id) FROM message WHERE rulesChecked = 0") ?? 0
            let messages = try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE rulesChecked = 0 AND id <= ? AND accountID = ? AND mailbox = 'INBOX'
                  AND reactionTo IS NULL
                ORDER BY date
                """, arguments: [upTo, accountID])
            return (messages, upTo)
        }
    }

    /// Everything up to `upTo` has been seen, wherever it is now: mail that reaches the Inbox
    /// later (moved back from Archive) isn't "new" and doesn't run rules.
    func markRulesChecked(accountID: String, upTo: Int64) throws {
        try db.write {
            try $0.execute(sql: "UPDATE message SET rulesChecked = 1 WHERE rulesChecked = 0 AND id <= ? AND accountID = ?",
                           arguments: [upTo, accountID])
        }
    }

    /// Everything in one mailbox has been seen (after its first sync).
    func markRulesChecked(accountID: String, mailbox: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE message SET rulesChecked = 1 WHERE rulesChecked = 0 AND accountID = ? AND mailbox = ?",
                           arguments: [accountID, mailbox])
        }
    }

    /// Newest Inbox mail first, for previews and "run on the Inbox now".
    public func inboxMessages(accountID: String? = nil, limit: Int = 2000) throws -> [StoredMessage] {
        try db.read { db in
            if let accountID {
                return try StoredMessage.fetchAll(db, sql: "SELECT * FROM message WHERE mailbox = 'INBOX' AND accountID = ? AND reactionTo IS NULL ORDER BY date DESC LIMIT ?",
                                                  arguments: [accountID, limit])
            }
            return try StoredMessage.fetchAll(db, sql: "SELECT * FROM message WHERE mailbox = 'INBOX' AND reactionTo IS NULL ORDER BY date DESC LIMIT ?",
                                              arguments: [limit])
        }
    }

    // MARK: History

    func recordRuleRun(accountID: String, message: StoredMessage, rules: [Rule], actions: [RuleAction]) throws -> Int64 {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        return try db.write { db in
            try db.execute(sql: """
                INSERT INTO ruleRun (at, accountID, messageID, threadID, subject, sender, ruleIDs, ruleNames, actions,
                                     previousCategory, previousReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [Date(), accountID, message.id, message.threadID ?? "", message.subject,
                                 message.fromName ?? message.fromAddress,
                                 try json(rules.map(\.id)), try json(rules.map(\.name)), try json(actions),
                                 message.category.rawValue, message.classificationReason])
            return db.lastInsertedRowID
        }
    }

    /// Newest first; one rule's runs, or all.
    public func ruleRuns(ruleID: String? = nil, limit: Int = 200) throws -> [RuleRun] {
        try db.read { db in
            var sql = "SELECT * FROM ruleRun"
            var args: [any DatabaseValueConvertible] = []
            if let ruleID {
                // JSON array of ids; an id is a UUID, so a quoted substring match is exact enough.
                sql += " WHERE ruleIDs LIKE ?"
                args.append("%\"\(ruleID)\"%")
            }
            sql += " ORDER BY at DESC, id DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? }))
                .map { Self.ruleRun(from: $0) }
        }
    }

    func ruleRun(id: Int64) throws -> RuleRun? {
        try db.read { try Row.fetchOne($0, sql: "SELECT * FROM ruleRun WHERE id = ?", arguments: [id]).map { Self.ruleRun(from: $0) } }
    }

    private static func ruleRun(from row: Row) -> RuleRun {
        let decoder = JSONDecoder()
        func decoded<T: Decodable>(_ json: String?, as type: T.Type) -> T? {
            json.flatMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
        }
        return RuleRun(id: row["id"], at: row["at"], accountID: row["accountID"], messageID: row["messageID"],
                       threadID: row["threadID"], subject: row["subject"], sender: row["sender"],
                       ruleIDs: decoded(row["ruleIDs"], as: [String].self) ?? [],
                       ruleNames: decoded(row["ruleNames"], as: [String].self) ?? [],
                       actions: decoded(row["actions"], as: [RuleAction].self) ?? [],
                       previousCategory: MailCategory(rawValue: row["previousCategory"]) ?? .primary,
                       previousReason: row["previousReason"], undoneAt: row["undoneAt"])
    }

    func markRuleRunUndone(id: Int64) throws {
        try db.write { try $0.execute(sql: "UPDATE ruleRun SET undoneAt = ? WHERE id = ?", arguments: [Date(), id]) }
    }

    /// How many messages each rule acted on since `date` (for the rules list).
    public func ruleRunCounts(since date: Date) throws -> [String: Int] {
        let decoder = JSONDecoder()
        let rows = try db.read { try String.fetchAll($0, sql: "SELECT ruleIDs FROM ruleRun WHERE at >= ? AND undoneAt IS NULL", arguments: [date]) }
        var counts: [String: Int] = [:]
        for json in rows {
            for id in (try? decoder.decode([String].self, from: Data(json.utf8))) ?? [] { counts[id, default: 0] += 1 }
        }
        return counts
    }
}
