import Foundation
import GRDB

/// More than one account in one store: removing one, and conversations that live in several.
extension MailStore {
    /// Removes everything this device stored for one account: its mail (and search index,
    /// embeddings), folders, outbox and drafts, queued actions, settings, rule history, date
    /// suggestions, follow-up drafts, invite answers and Reply Later / snooze state, plus the
    /// summaries, mutes and AI-category picks of conversations that only it held.
    ///
    /// iCloud-synced state is left alone in iCloud: other devices may still have the account.
    /// Records that disappear from this device's snapshot because of the removal are dropped
    /// from the sync shadow, so they don't go up as deletions. If the account is added again,
    /// they come back from iCloud like on a new device.
    public func deleteAccount(_ accountID: String, cloudAccounts: CloudAccounts) throws {
        let before = try cloudSnapshot(accounts: cloudAccounts, settings: [:])
        let login = cloudAccounts.loginByID[accountID]
        try db.write { db in
            let threads = try String.fetchAll(db, sql: """
                SELECT DISTINCT threadID FROM message WHERE accountID = ? AND threadID IS NOT NULL
                """, arguments: [accountID])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid IN (SELECT sortKey FROM message WHERE accountID = ?)",
                           arguments: [accountID])
            try db.execute(sql: "DELETE FROM embedding WHERE messageID IN (SELECT id FROM message WHERE accountID = ?)",
                           arguments: [accountID])
            try db.execute(sql: "DELETE FROM message WHERE accountID = ?", arguments: [accountID])
            for table in ["mailboxState", "outbox", "accountSetting", "pendingAction", "ruleRun", "eventSuggestion",
                          "autoDraft", "inviteResponse"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [accountID])
            }
            if let login {
                // Only when no other account on this device signs in with the same login.
                let shared = cloudAccounts.loginByID.contains { $0.key != accountID && $0.value == login }
                if !shared { try db.execute(sql: "DELETE FROM messageState WHERE account = ?", arguments: [login]) }
            }
            // Conversations that lived only in this account.
            let gone = try threads.filter {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE threadID = ?", arguments: [$0]) == 0
            }
            for chunk in stride(from: 0, to: gone.count, by: 500).map({ Array(gone[$0..<min($0 + 500, gone.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for table in ["threadDigest", "mutedThread", "aiCategoryMember"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE threadID IN (\(marks))", arguments: StatementArguments(chunk))
                }
            }
        }
        // Keep iCloud as it is: what vanished here is not a deletion.
        let after = try cloudSnapshot(accounts: cloudAccounts, settings: [:])
        try db.write { db in
            for (type, records) in before {
                for key in records.keys where after[type]?[key] == nil {
                    try db.execute(sql: "DELETE FROM cloudShadow WHERE type = ? AND key = ?", arguments: [type, key])
                }
            }
        }
    }

    /// For each conversation, the accounts that have a message of it in `mailbox` (any folder
    /// when nil). A message sent to two of your addresses is one conversation in the unified
    /// Inbox but lives in both accounts, so Done and friends have to happen in each.
    public func accountIDs(threadIDs: [String], mailbox: String? = nil) throws -> [String: Set<String>] {
        guard !threadIDs.isEmpty else { return [:] }
        return try db.read { db in
            var result: [String: Set<String>] = [:]
            for chunk in stride(from: 0, to: threadIDs.count, by: 500).map({ Array(threadIDs[$0..<min($0 + 500, threadIDs.count)]) }) {
                var sql = "SELECT DISTINCT threadID, accountID FROM message WHERE threadID IN (\(chunk.map { _ in "?" }.joined(separator: ",")))"
                var args: [any DatabaseValueConvertible] = chunk
                if let mailbox { sql += " AND mailbox = ?"; args.append(mailbox) }
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? })) {
                    result[row["threadID"], default: []].insert(row["accountID"])
                }
            }
            return result
        }
    }

    /// How many messages each account has in the store (Settings › Accounts).
    public func messageCounts() throws -> [String: Int] {
        try db.read { db in
            var result: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT accountID, count(*) AS n FROM message GROUP BY accountID") {
                result[row["accountID"]] = row["n"]
            }
            return result
        }
    }
}
