import Foundation
import GRDB

/// Muted conversations (SPEC §11): new messages in them skip the Inbox and never notify.
/// Kept by thread id, on this device (CloudKit in M7).
extension MailStore {
    static func registerMuteMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v14-muted-threads") { db in
            try db.create(table: "mutedThread") { t in
                t.column("threadID", .text).primaryKey()
                t.column("mutedAt", .datetime).notNull()
            }
        }
    }

    public func mute(threadID: String) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO mutedThread (threadID, mutedAt) VALUES (?, ?)", arguments: [threadID, Date()]) }
    }

    public func unmute(threadID: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM mutedThread WHERE threadID = ?", arguments: [threadID]) }
    }

    public func isMuted(threadID: String) throws -> Bool {
        try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM mutedThread WHERE threadID = ?)", arguments: [threadID]) ?? false }
    }

    public func mutedThreadIDs() throws -> Set<String> {
        Set(try db.read { try String.fetchAll($0, sql: "SELECT threadID FROM mutedThread") })
    }
}
