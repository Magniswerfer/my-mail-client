import Foundation
import GRDB

/// A category you describe in words ("Investors: updates and questions from our investors"),
/// sorted by the on-device model (Superhuman-style split inbox, SPEC §4 "AI-defined bundles").
/// It sits beside the built-in categories: a conversation keeps its category and can also be
/// in any number of these.
public struct AICategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// What belongs: the description, its embedding cut and your ✓/✗ examples (as for rules).
    public var about: AboutCondition
    public var symbol: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, description: String, symbol: String = "sparkles",
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.about = AboutCondition(description.isEmpty ? name : description)
        self.symbol = symbol
        self.createdAt = createdAt
    }

    /// As a rule, so the rule engine's judge (embedding pre-filter + on-device model) decides.
    public var asRule: Rule {
        Rule(id: "aicategory.\(id)", name: name, conditions: [.about(about)], actions: [.notify])
    }
}

extension MailStore {
    static func registerAICategoryMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v19-ai-categories") { db in
            try db.create(table: "aiCategory") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .blob).notNull()
                // Messages above this id have not been sorted into it yet.
                t.column("checkedUpTo", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "aiCategoryMember") { t in
                t.column("categoryID", .text).notNull()
                t.column("threadID", .text).notNull()
                // 1 = you put it there, 0 = the model did; -1 = you took it out (never re-added).
                t.column("source", .integer).notNull().defaults(to: 0)
                t.column("at", .datetime).notNull()
                t.primaryKey(["categoryID", "threadID"])
            }
            try db.create(index: "aiCategoryMember_thread", on: "aiCategoryMember", columns: ["threadID"])
        }
    }

    public func aiCategories() throws -> [AICategory] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM aiCategory ORDER BY position").compactMap {
                try? JSONDecoder().decode(AICategory.self, from: $0)
            }
        }
    }

    /// Saves the list (order = tab order). New categories start unchecked, so the next pass sorts
    /// your recent Inbox into them; edited ones keep their progress.
    public func saveAICategories(_ categories: [AICategory]) throws {
        try db.write { db in
            let progress = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, checkedUpTo FROM aiCategory").map {
                ($0["id"] as String, $0["checkedUpTo"] as Int64)
            })
            try db.execute(sql: "DELETE FROM aiCategory")
            for (i, c) in categories.enumerated() {
                try db.execute(sql: "INSERT INTO aiCategory (id, position, json, checkedUpTo) VALUES (?, ?, ?, ?)",
                               arguments: [c.id, i, try JSONEncoder().encode(c), progress[c.id] ?? 0])
            }
            try db.execute(sql: "DELETE FROM aiCategoryMember WHERE categoryID NOT IN (SELECT id FROM aiCategory)")
        }
    }

    /// Re-sort from scratch (after changing what a category is about). Your own choices stay.
    public func resetAICategory(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE aiCategory SET checkedUpTo = 0 WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM aiCategoryMember WHERE categoryID = ? AND source = 0", arguments: [id])
        }
    }

    /// Inbox messages not yet sorted into `id`: new mail, or — for a new category — the most
    /// recent `backfill` of the Inbox. Oldest first; your own mail is skipped.
    public func messagesToSort(into id: String, ownAddresses: Set<String>, backfill: Int = 300, limit: Int = 200) throws
        -> [StoredMessage] {
        let own = ownAddresses.isEmpty ? [""] : ownAddresses.map { $0.lowercased() }.sorted()
        let ownSQL = own.map { _ in "?" }.joined(separator: ",")
        return try db.read { db in
            let upTo = try Int64.fetchOne(db, sql: "SELECT checkedUpTo FROM aiCategory WHERE id = ?", arguments: [id]) ?? 0
            if upTo == 0 {
                // Newest per conversation in the Inbox, most recent first, then oldest-first for processing.
                return try StoredMessage.fetchAll(db, sql: """
                    SELECT * FROM message WHERE id IN (
                        SELECT max(id) FROM message WHERE mailbox = 'INBOX' AND lower(fromAddress) NOT IN (\(ownSQL))
                        GROUP BY threadID ORDER BY max(date) DESC LIMIT ?
                    ) ORDER BY id
                    """, arguments: StatementArguments(own + [backfill] as [any DatabaseValueConvertible]))
            }
            return try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE id > ? AND mailbox = 'INBOX' AND lower(fromAddress) NOT IN (\(ownSQL))
                ORDER BY id LIMIT ?
                """, arguments: StatementArguments([upTo] + own + [limit] as [any DatabaseValueConvertible]))
        }
    }

    public func markSorted(into id: String, upTo messageID: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE aiCategory SET checkedUpTo = max(checkedUpTo, ?) WHERE id = ?", arguments: [messageID, id])
        }
    }

    /// The model's decision. Never overrides yours.
    public func assign(threadID: String, to id: String) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO aiCategoryMember (categoryID, threadID, source, at) VALUES (?, ?, 0, ?)
                ON CONFLICT(categoryID, threadID) DO NOTHING
                """, arguments: [id, threadID, Date()])
        }
    }

    /// You put it in (true) or took it out (false); sticks over the model.
    public func setMembership(threadID: String, categoryID: String, isMember: Bool) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO aiCategoryMember (categoryID, threadID, source, at) VALUES (?, ?, ?, ?)
                ON CONFLICT(categoryID, threadID) DO UPDATE SET source = excluded.source, at = excluded.at
                """, arguments: [categoryID, threadID, isMember ? 1 : -1, Date()])
        }
    }

    /// Conversations in a category (yours and the model's, minus the ones you took out).
    public func threadIDs(inAICategory id: String) throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT threadID FROM aiCategoryMember WHERE categoryID = ? AND source >= 0",
                                    arguments: [id]))
        }
    }

    /// Category ids per conversation, for the stream (one read).
    public func aiCategoryMembership() throws -> [String: Set<String>] {
        try db.read { db in
            var result: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT categoryID, threadID FROM aiCategoryMember WHERE source >= 0") {
                result[row["threadID"], default: []].insert(row["categoryID"])
            }
            return result
        }
    }
}
