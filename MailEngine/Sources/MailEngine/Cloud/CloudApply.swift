import Foundation
import GRDB

extension MailStore {
    enum ApplyOutcome { case applied, deferred }

    // MARK: Applying what other devices changed

    /// Applies incoming records and deletions. A local change that's newer and not yet sent
    /// wins (it goes up next); records about mail or accounts this device doesn't have yet
    /// wait in `cloudPending` and are retried after each mail sync.
    @discardableResult
    public func applyCloudChanges(saves: [StateRecord], deletions: [(type: String, key: String)],
                                  accounts: CloudAccounts) throws -> CloudApplyReport {
        var report = CloudApplyReport()
        for record in saves {
            if let local = try localOutbox(type: record.type, key: record.key), local.modifiedAt > record.modifiedAt {
                report.skipped += 1
                continue
            }
            switch try apply(record, accounts: accounts, report: &report) {
            case .applied:
                try db.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO cloudShadow (type, key, payload) VALUES (?, ?, ?)",
                                   arguments: [record.type, record.key, record.payload])
                    try db.execute(sql: "DELETE FROM cloudOutbox WHERE type = ? AND key = ?", arguments: [record.type, record.key])
                    try db.execute(sql: "DELETE FROM cloudPending WHERE type = ? AND key = ?", arguments: [record.type, record.key])
                }
                report.applied += 1
                report.changedTypes.insert(record.type)
            case .deferred:
                try db.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO cloudPending (type, key, payload, modifiedAt) VALUES (?, ?, ?, ?)",
                                   arguments: [record.type, record.key, record.payload, record.modifiedAt])
                    try db.execute(sql: "DELETE FROM cloudOutbox WHERE type = ? AND key = ?", arguments: [record.type, record.key])
                }
                report.deferred += 1
            }
        }
        for deletion in deletions {
            // A local save of the same record that isn't sent yet wins over a deletion.
            if let local = try localOutbox(type: deletion.type, key: deletion.key), local.payload != nil {
                report.skipped += 1
                continue
            }
            if deletion.type == StateRecordType.account.rawValue { report.removedAccounts.insert(deletion.key) }
            try remove(type: deletion.type, key: deletion.key, accounts: accounts)
            try db.write { db in
                for table in ["cloudShadow", "cloudOutbox", "cloudPending"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE type = ? AND key = ?", arguments: [deletion.type, deletion.key])
                }
            }
            report.applied += 1
            report.changedTypes.insert(deletion.type)
        }
        return report
    }

    /// Retries records that were waiting for mail or an account (after each mail sync).
    @discardableResult
    public func applyPendingCloudChanges(accounts: CloudAccounts) throws -> CloudApplyReport {
        let pending = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT type, key, payload, modifiedAt FROM cloudPending").map {
                StateRecord(type: $0["type"], key: $0["key"], payload: $0["payload"], modifiedAt: $0["modifiedAt"])
            }
        }
        guard !pending.isEmpty else { return CloudApplyReport() }
        return try applyCloudChanges(saves: pending, deletions: [], accounts: accounts)
    }

    private func localOutbox(type: String, key: String) throws -> (payload: Data?, modifiedAt: Date)? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT payload, modifiedAt FROM cloudOutbox WHERE type = ? AND key = ?", arguments: [type, key])
                .map { ($0["payload"] as Data?, $0["modifiedAt"] as Date) }
        }
    }

    private func shadowPayload(type: String, key: String) throws -> Data? {
        try db.read { try Data.fetchOne($0, sql: "SELECT payload FROM cloudShadow WHERE type = ? AND key = ?", arguments: [type, key]) }
    }

    /// Local threads holding any of these Message-IDs.
    private func threadIDs(holding messageIDs: [String], accountID: String? = nil) throws -> [String] {
        guard !messageIDs.isEmpty else { return [] }
        return try db.read { db in
            var sql = "SELECT DISTINCT threadID FROM message WHERE threadID IS NOT NULL AND messageID IN (\(messageIDs.map { _ in "?" }.joined(separator: ",")))"
            var args: [any DatabaseValueConvertible] = messageIDs
            if let accountID { sql += " AND accountID = ?"; args.append(accountID) }
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? }))
        }
    }

    private static func split(_ key: String) -> (String, String)? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        return (String(key[..<bar]), String(key[key.index(after: bar)...]))
    }

    private func apply(_ record: StateRecord, accounts: CloudAccounts, report: inout CloudApplyReport) throws -> ApplyOutcome {
        guard let type = StateRecordType(rawValue: record.type) else { return .applied }   // from a newer version: ignore
        let key = record.key
        switch type {
        case .rule:
            let p = try CloudJSON.value(RulePayload.self, record.payload)
            var list = try rules().filter { $0.id != p.rule.id }
            list.insert(p.rule, at: min(max(0, p.position), list.count))
            try saveRules(list)
        case .smartFolder:
            let p = try CloudJSON.value(FolderPayload.self, record.payload)
            var list = try smartFolders().filter { $0.id != p.folder.id }
            list.insert(p.folder, at: min(max(0, p.position), list.count))
            try saveSmartFolders(list)
        case .aiCategory:
            let p = try CloudJSON.value(AICategoryPayload.self, record.payload)
            var list = try aiCategories().filter { $0.id != p.category.id }
            list.insert(p.category, at: min(max(0, p.position), list.count))
            try saveAICategories(list)
        case .senderRule:
            let p = try CloudJSON.value(SenderRulePayload.self, record.payload)
            guard let category = MailCategory(rawValue: p.category) else { return .applied }
            _ = try remember(category: category, forSender: key)
        case .imageTrust:
            try trustImages(from: key)
        case .trustedSender:
            try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO trustedSender (address, createdAt) VALUES (?, ?)", arguments: [key, Date()]) }
        case .unsubscribed:
            let p = try CloudJSON.value(UnsubscribedPayload.self, record.payload)
            try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO unsubscribed (address, at, method) VALUES (?, ?, ?)",
                                          arguments: [key, p.at, p.method]) }
        case .inviteResponse:
            let p = try CloudJSON.value(InvitePayload.self, record.payload)
            guard let (login, uid) = Self.split(key), let accountID = accounts.idByLogin[login],
                  let status = CalendarInvite.ParticipationStatus(rawValue: p.status) else { return .deferred }
            try recordInviteResponse(InviteResponse(accountID: accountID, uid: uid, sequence: p.sequence, status: status, respondedAt: p.respondedAt))
        case .mute:
            let p = try CloudJSON.value(ConversationPayload.self, record.payload)
            let threads = try threadIDs(holding: p.messageIDs)
            guard !threads.isEmpty else { return .deferred }
            for thread in threads { try mute(threadID: thread) }
        case .messageState:
            guard let (login, messageID) = Self.split(key) else { return .applied }
            try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO messageState (account, messageID, payload, modifiedAt) VALUES (?, ?, ?, ?)",
                                          arguments: [login, messageID, record.payload, record.modifiedAt]) }
            // Kept even before the mail arrives; re-applied after every mail sync.
            _ = try reassertMessageStates(accounts: accounts)
        case .correction:
            let p = try CloudJSON.value(CorrectionPayload.self, record.payload)
            guard let (login, messageID) = Self.split(key), let accountID = accounts.idByLogin[login],
                  let category = MailCategory(rawValue: p.category) else { return .deferred }
            let ids = try db.read { try Int64.fetchAll($0, sql: "SELECT id FROM message WHERE accountID = ? AND messageID = ?",
                                                       arguments: [accountID, messageID]) }
            guard !ids.isEmpty else { return .deferred }
            try setCategory(category, reason: .youMovedThisConversation(category), ids: ids)
        case .aiChoice:
            let p = try CloudJSON.value(AIChoicePayload.self, record.payload)
            let threads = try threadIDs(holding: p.messageIDs)
            guard !threads.isEmpty else { return .deferred }
            for thread in threads { try setMembership(threadID: thread, categoryID: p.categoryID, isMember: p.isMember) }
        case .setting:
            report.settings[key] = record.payload
        case .account:
            report.accounts[key] = record.payload
        }
        return .applied
    }

    private func remove(type rawType: String, key: String, accounts: CloudAccounts) throws {
        guard let type = StateRecordType(rawValue: rawType) else { return }
        switch type {
        case .rule: try saveRules(try rules().filter { $0.id != key })
        case .smartFolder: try saveSmartFolders(try smartFolders().filter { $0.id != key })
        case .aiCategory: try saveAICategories(try aiCategories().filter { $0.id != key })
        case .senderRule: try forgetSenderRule(key)
        case .imageTrust: try db.write { try $0.execute(sql: "DELETE FROM imageTrust WHERE sender = ?", arguments: [key]) }
        case .trustedSender: try db.write { try $0.execute(sql: "DELETE FROM trustedSender WHERE address = ?", arguments: [key]) }
        case .unsubscribed: try db.write { try $0.execute(sql: "DELETE FROM unsubscribed WHERE address = ?", arguments: [key]) }
        case .inviteResponse:
            if let (login, uid) = Self.split(key), let accountID = accounts.idByLogin[login] {
                try forgetInviteResponse(accountID: accountID, uid: uid)
            }
        case .mute:
            let ids = try shadowPayload(type: rawType, key: key).flatMap { try? CloudJSON.value(ConversationPayload.self, $0).messageIDs } ?? [key]
            for thread in try threadIDs(holding: ids) { try unmute(threadID: thread) }
        case .messageState:
            guard let (login, messageID) = Self.split(key) else { return }
            try db.write { try $0.execute(sql: "DELETE FROM messageState WHERE account = ? AND messageID = ?", arguments: [login, messageID]) }
            try applyMessageState(MessageStatePayload(), login: login, messageID: messageID, accounts: accounts)
        case .correction:
            break   // the other device moved it back; its new category arrives as its own correction, if any
        case .aiChoice:
            let p = try shadowPayload(type: rawType, key: key).flatMap { try? CloudJSON.value(AIChoicePayload.self, $0) }
            guard let p else { return }
            for thread in try threadIDs(holding: p.messageIDs) {
                try db.write { try $0.execute(sql: "DELETE FROM aiCategoryMember WHERE categoryID = ? AND threadID = ? AND source != 0",
                                              arguments: [p.categoryID, thread]) }
            }
        case .setting, .account:
            break
        }
    }

    // MARK: Message state (Reply Later, Read Later, snooze wake times)

    /// After a triage action changed these messages: record their Reply Later / Read Later /
    /// snooze state as the truth on this device.
    func noteMessageState(localIDs: [Int64], login: String) throws {
        guard !localIDs.isEmpty else { return }
        let messages = try db.read { try StoredMessage.fetchAll($0, keys: localIDs) }
        try db.write { db in
            for m in messages {
                guard let messageID = m.messageID else { continue }
                let state = MessageStatePayload(replyLater: m.flags.contains(replyLaterKeyword),
                                                readLater: m.flags.contains(readLaterKeyword),
                                                snoozed: m.isSnoozed, snoozeUntil: m.isSnoozed ? m.snoozedUntil : nil)
                if state.isEmpty {
                    try db.execute(sql: "DELETE FROM messageState WHERE account = ? AND messageID = ?", arguments: [login.lowercased(), messageID])
                } else {
                    try db.execute(sql: "INSERT OR REPLACE INTO messageState (account, messageID, payload, modifiedAt) VALUES (?, ?, ?, ?)",
                                   arguments: [login.lowercased(), messageID, try CloudJSON.data(state), Date()])
                }
            }
        }
    }

    /// Puts recorded message state back onto local flags (a mail sync from a server that drops
    /// our keywords takes them off again). Local only: nothing is sent to the server.
    @discardableResult
    public func reassertMessageStates(accounts: CloudAccounts) throws -> Int {
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT account, messageID, payload FROM messageState") }
        var changed = 0
        for row in rows {
            guard let state = try? CloudJSON.value(MessageStatePayload.self, row["payload"]) else { continue }
            changed += try applyMessageState(state, login: row["account"], messageID: row["messageID"], accounts: accounts)
        }
        return changed
    }

    @discardableResult
    private func applyMessageState(_ state: MessageStatePayload, login: String, messageID: String, accounts: CloudAccounts) throws -> Int {
        guard let accountID = accounts.idByLogin[login.lowercased()] else { return 0 }
        return try db.write { db in
            var changed = 0
            for row in try Row.fetchAll(db, sql: "SELECT id, mailbox, flags, isSnoozed, snoozedUntil FROM message WHERE accountID = ? AND messageID = ?",
                                        arguments: [accountID, messageID]) {
                var flags = Set((row["flags"] as String).split(separator: " ").map(String.init))
                let before = flags
                if state.replyLater { flags.insert(replyLaterKeyword) } else { flags.remove(replyLaterKeyword) }
                if state.readLater { flags.insert(readLaterKeyword) } else { flags.remove(readLaterKeyword) }
                if flags != before {
                    try db.execute(sql: "UPDATE message SET flags = ? WHERE id = ?", arguments: [flags.sorted().joined(separator: " "), row["id"] as Int64])
                    changed += 1
                }
                // The wake time matters where the mail is in Snoozed (the move itself is IMAP).
                if AccountSync.isSnoozedMailbox(row["mailbox"] as String), state.snoozed,
                   !(row["isSnoozed"] as Bool) || (row["snoozedUntil"] as Date?) != state.snoozeUntil {
                    try db.execute(sql: "UPDATE message SET isSnoozed = 1, snoozedUntil = ? WHERE id = ?", arguments: [state.snoozeUntil, row["id"] as Int64])
                    changed += 1
                }
            }
            return changed
        }
    }
}
