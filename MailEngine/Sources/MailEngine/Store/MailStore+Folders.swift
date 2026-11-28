import Foundation
import GRDB

extension MailStore {
    /// Local side of a RENAME: `from` and everything inside it become `to…`.
    func renameMailbox(accountID: String, from: String, to: String, separator: Character?) throws {
        let sep = separator.map(String.init) ?? ""
        // Leftovers under the new name (from an earlier folder there) would clash.
        for stale in try mailboxStates(accountID: accountID) where FolderPath.isWithin(stale.path, to, separator: separator) {
            try deleteMailbox(accountID: accountID, mailbox: stale.path)
        }
        func within(_ column: String) -> String {
            "(\(column) = :from OR (:sep <> '' AND substr(\(column), 1, length(:from) + length(:sep)) = :from || :sep))"
        }
        let args: StatementArguments = ["from": from, "to": to, "sep": sep, "account": accountID]
        try db.write { db in
            try db.execute(sql: "UPDATE message SET mailbox = :to || substr(mailbox, length(:from) + 1) WHERE accountID = :account AND \(within("mailbox"))",
                           arguments: args)
            try db.execute(sql: "UPDATE mailboxState SET path = :to || substr(path, length(:from) + 1) WHERE accountID = :account AND \(within("path"))",
                           arguments: args)
            // Queued actions that still name the old folder (queued while the rename ran).
            try rewritePending(db, accountID: accountID) { path in
                FolderPath.renamed(path, from: from, to: to, separator: separator) ?? path
            }
        }
    }

    /// Queued actions moving mail out of or into a deleted folder can't run any more.
    func dropPending(accountID: String, inside path: String, separator: Character?) throws {
        try db.write { db in
            for pending in try PendingAction.filter(Column("accountID") == accountID).fetchAll(db) {
                guard case .move(let items, let target, _, _, _)? = pending.action else { continue }
                if FolderPath.isWithin(target, path, separator: separator)
                    || items.contains(where: { FolderPath.isWithin($0.fromMailbox, path, separator: separator) }) {
                    _ = try pending.delete(db)
                }
            }
        }
    }

    private func rewritePending(_ db: Database, accountID: String, _ map: (String) -> String) throws {
        for var pending in try PendingAction.filter(Column("accountID") == accountID).fetchAll(db) {
            guard case .move(let items, let target, let add, let remove, let create)? = pending.action else { continue }
            let newItems = items.map { QueuedAction.MoveItem(localID: $0.localID, fromMailbox: map($0.fromMailbox), fromUID: $0.fromUID) }
            let rewritten = QueuedAction.move(items: newItems, to: map(target), addFlags: add, removeFlags: remove, createTarget: create)
            guard rewritten != pending.action else { continue }
            pending.payload = try JSONEncoder().encode(rewritten)
            try pending.update(db)
        }
    }
}

extension MailStore {
    /// "Use as Archive": remembered for the account, and the folder takes the role now if it's
    /// already known here (from you, or from another device through iCloud).
    func useFolder(_ path: String?, for role: MailboxRole, accountID: String) throws {
        guard AccountSync.choosableRoles.contains(role) else { return }
        try setSetting(AccountSync.roleChoiceKey(role), path ?? "", accountID: accountID)
        guard let path else { return }
        try db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM mailboxState WHERE accountID = ? AND path = ?",
                                    arguments: [accountID, path]) == true else { return }
            try db.execute(sql: "UPDATE mailboxState SET role = NULL WHERE accountID = ? AND role = ?",
                           arguments: [accountID, role.rawValue])
            try db.execute(sql: "UPDATE mailboxState SET role = ? WHERE accountID = ? AND path = ?",
                           arguments: [role.rawValue, accountID, path])
        }
    }
}
