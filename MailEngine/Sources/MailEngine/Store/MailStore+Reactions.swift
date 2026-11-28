import Foundation
import GRDB

/// One person's reaction to a message ("👍 Anna").
public struct MailReaction: Sendable, Hashable {
    public var emoji: String
    public var fromAddress: String
    public var fromName: String
    public var date: Date
    /// Sent from one of the `ownAddresses` passed to `reactions(toMessageIDs:ownAddresses:)`.
    public var isMine: Bool

    public init(emoji: String, fromAddress: String, fromName: String, date: Date, isMine: Bool) {
        self.emoji = emoji
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.date = date
        self.isMine = isMine
    }
}

extension MailStore {
    static func registerReactionMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v24-reactions") { db in
            try db.alter(table: "message") { t in
                t.add(column: "reactionTo", .text)
                t.add(column: "reactionEmoji", .text)
                t.add(column: "reactionsDisallowed", .boolean).notNull().defaults(to: false)
            }
            // Few messages are reactions: a partial index stays tiny.
            try db.execute(sql: "CREATE INDEX message_reactionTo ON message(reactionTo) WHERE reactionTo IS NOT NULL")
        }
    }

    /// Reactions leave the full-text index (search no longer filters them with a join).
    /// Registered last: it came after v26.
    static func registerReactionIndexMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v27-reactions-unindexed") { db in
            try db.execute(sql: """
                DELETE FROM message_fts WHERE rowid IN (SELECT sortKey FROM message WHERE reactionTo IS NOT NULL)
                """)
        }
    }

    /// The reactions to these messages, keyed by the reacted-to Message-ID (as given, without
    /// angle brackets), oldest first. Each sender counts once: their latest reaction wins, and a
    /// removal takes theirs away. The same reaction filed in several mailboxes counts once.
    public func reactions(toMessageIDs messageIDs: [String], ownAddresses: Set<String> = []) throws -> [String: [MailReaction]] {
        let ids = Array(Set(messageIDs.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }
        let own = Set(ownAddresses.map { $0.lowercased() })
        let rows = try db.read { db in
            try stride(from: 0, to: ids.count, by: 500).flatMap { start -> [Row] in
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                return try Row.fetchAll(db, sql: """
                    SELECT reactionTo, reactionEmoji, fromAddress, fromName, date FROM message
                    WHERE reactionTo IS NOT NULL AND reactionTo IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY date, id
                    """, arguments: StatementArguments(chunk))
            }
        }
        // target → sender → their latest reaction (an empty emoji after a removal).
        var latest: [String: [String: MailReaction]] = [:]
        for row in rows {
            let target: String = row["reactionTo"]
            let address: String = row["fromAddress"]
            let key = address.lowercased()
            let date: Date = row["date"]
            if let current = latest[target]?[key], current.date > date { continue }
            let emoji: String = row["reactionEmoji"] ?? ""
            let name: String = row["fromName"] ?? ""
            latest[target, default: [:]][key] = MailReaction(emoji: emoji, fromAddress: address, fromName: name.isEmpty ? address : name,
                                                             date: date, isMine: own.contains(key))
        }
        var result: [String: [MailReaction]] = [:]
        for (target, senders) in latest {
            let kept = senders.values.filter { !$0.emoji.isEmpty }.sorted { $0.date < $1.date }
            if !kept.isEmpty { result[target] = kept }
        }
        return result
    }
}
