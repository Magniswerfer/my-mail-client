import Foundation
import GRDB

/// A saved search in the sidebar (SPEC §7), with a live count.
public struct SmartFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// A search query (same syntax as the search field), or a built-in `special:` query.
    public var query: String
    public var symbol: String

    public init(id: String = UUID().uuidString, name: String, query: String, symbol: String = "folder.badge.gearshape") {
        self.id = id
        self.name = name
        self.query = query
        self.symbol = symbol
    }

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    /// Attachments, Waiting for reply, Receipts this year. Names are localized by the app.
    public static func builtIns(now: Date = Date(), calendar: Calendar = .current) -> [SmartFolder] {
        let year = calendar.component(.year, from: now)
        return [
            SmartFolder(id: "builtin.readLater", name: "Read Later", query: SmartFolder.readLaterQuery, symbol: "book"),
            SmartFolder(id: "builtin.attachments", name: "Attachments", query: "has:attachment", symbol: "paperclip"),
            SmartFolder(id: "builtin.waiting", name: "Waiting for Reply", query: SmartFolder.waitingQuery, symbol: "hourglass"),
            SmartFolder(id: "builtin.receipts", name: "Receipts This Year", query: "category:transactions after:\(year)-01-01",
                        symbol: "creditcard"),
        ]
    }

    public static let waitingQuery = "special:waiting"
    public static let readLaterQuery = "special:readLater"
}

extension MailStore {
    static func registerSmartFolderMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v14-smart-folders") { db in
            try db.create(table: "smartFolder") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .blob).notNull()
            }
        }
    }

    public func smartFolders() throws -> [SmartFolder] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM smartFolder ORDER BY position").compactMap {
                try? JSONDecoder().decode(SmartFolder.self, from: $0)
            }
        }
    }

    public func saveSmartFolders(_ folders: [SmartFolder]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM smartFolder")
            for (i, f) in folders.enumerated() where !f.isBuiltIn {
                try db.execute(sql: "INSERT INTO smartFolder (id, position, json) VALUES (?, ?, ?)",
                               arguments: [f.id, i, try JSONEncoder().encode(f)])
            }
        }
    }

    /// Conversations where you wrote last to someone else within `maxDays` (newest first).
    public func waitingForReplyThreadIDs(ownAddresses: Set<String>, maxDays: Int = 45, now: Date = Date(), limit: Int = 300) throws -> [String] {
        let own = Set(ownAddresses.map { $0.lowercased() })
        guard !own.isEmpty else { return [] }
        let oldest = now.addingTimeInterval(-Double(maxDays) * 86_400)
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.threadID, m.recipients FROM message m JOIN (
                    SELECT threadID, max(date) AS d FROM message WHERE threadID IS NOT NULL GROUP BY threadID
                ) t ON m.threadID = t.threadID AND m.date = t.d
                WHERE lower(m.fromAddress) IN (\(own.map { _ in "?" }.joined(separator: ",")))
                  AND m.date >= ?
                  AND m.mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('drafts', 'trash', 'junk'))
                ORDER BY m.date DESC LIMIT ?
                """, arguments: StatementArguments(own.sorted() + [oldest, limit] as [any DatabaseValueConvertible]))
        }
        var seen = Set<String>()
        return rows.compactMap { row -> String? in
            guard let thread: String = row["threadID"], seen.insert(thread).inserted else { return nil }
            let others = AddressParser.parse(row["recipients"] ?? "").filter { !own.contains($0.address.lowercased()) }
            return others.isEmpty || others.contains(where: { SignatureInfo.looksAutomated($0.address) }) ? nil : thread
        }
    }

    /// Conversation ids for message ids (search hits → conversations).
    public func threadIDs(forMessageIDs ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT threadID FROM message WHERE threadID IS NOT NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
        }
    }

    // MARK: Semantic search

    /// The messages whose stored embeddings are closest to `vector`, among the most recent
    /// `window` embedded messages (bounded memory and time on big mailboxes).
    public func nearest(to vector: [Float], limit: Int = 20, minimumScore: Float = 0.35, window: Int = 20_000,
                        excluding: Set<Int64> = []) throws -> [(id: Int64, score: Float)] {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.messageID AS id, e.vector AS v FROM embedding e JOIN message m ON m.id = e.messageID
                ORDER BY m.date DESC LIMIT ?
                """, arguments: [window])
        }
        var scored: [(id: Int64, score: Float)] = []
        for row in rows {
            let id: Int64 = row["id"]
            guard !excluding.contains(id), let data: Data = row["v"] else { continue }
            let score = VectorMath.cosine(vector, Self.halfFloats(data))
            if score >= minimumScore { scored.append((id, score)) }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Float16 blobs as written by the refinement pass.
    static func halfFloats(_ data: Data) -> [Float] {
        #if arch(x86_64) && os(macOS)
        // No Float16 on Intel Macs (Tidings targets Apple silicon; keep the build working anyway).
        return []
        #else
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
        #endif
    }
}
