import Foundation
import GRDB

/// A saved search shown in the sidebar with a live count (SPEC §7). The query is ordinary
/// search syntax, so anything you can type in search can be a smart folder.
public struct SmartFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var query: String
    public var symbol: String

    public init(id: String = UUID().uuidString, name: String, query: String, symbol: String = "folder.badge.gearshape") {
        self.id = id
        self.name = name
        self.query = query
        self.symbol = symbol
    }

    /// Built in, always there (the app shows their names in your language).
    public static let attachments = SmartFolder(id: "builtin.attachments", name: "Attachments", query: "has:attachment", symbol: "paperclip")
    public static let waitingForReply = SmartFolder(id: "builtin.waiting", name: "Waiting for Reply", query: "is:waiting after:30d",
                                                    symbol: "hourglass")
    public static let receiptsThisYear = SmartFolder(id: "builtin.receipts", name: "Receipts This Year",
                                                     query: "category:transactions after:thisyear", symbol: "receipt")
    public static let builtIn = [attachments, waitingForReply, receiptsThisYear]

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }
}

extension MailStore {
    static func registerSmartFolderMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v13-smart-folders") { db in
            try db.create(table: "smartFolder") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("symbol", .text).notNull()
            }
        }
    }

    /// Your saved searches, in order (the built-in ones aren't stored).
    public func smartFolders() throws -> [SmartFolder] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM smartFolder ORDER BY position, name").map {
                SmartFolder(id: $0["id"], name: $0["name"], query: $0["query"], symbol: $0["symbol"])
            }
        }
    }

    public func saveSmartFolders(_ folders: [SmartFolder]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM smartFolder")
            for (position, f) in folders.enumerated() where !f.isBuiltIn {
                try db.execute(sql: "INSERT INTO smartFolder (id, position, name, query, symbol) VALUES (?, ?, ?, ?, ?)",
                               arguments: [f.id, position, f.name, f.query, f.symbol])
            }
        }
    }
}
