import Foundation
import Testing
@testable import MailEngine

/// Two devices (two stores, different local account ids, same login) and a fake cloud.
@Suite struct CloudStateTests {
    final class FakeCloud {
        var records: [String: StateRecord] = [:]     // "type/key"
        /// Sends a device's queued changes; returns what other devices should fetch.
        func push(_ store: MailStore) throws {
            for change in try store.pendingCloudChanges() {
                switch change {
                case .save(let r):
                    if let existing = records["\(r.type)/\(r.key)"], existing.modifiedAt > r.modifiedAt {
                        continue    // the server keeps the newer one; the device learns it on fetch
                    }
                    records["\(r.type)/\(r.key)"] = r
                    try store.cloudSaved(r)
                case .delete(let type, let key):
                    records["\(type)/\(key)"] = nil
                    try store.cloudDeleted(type: type, key: key)
                }
            }
        }
        func pull(into store: MailStore, accounts: CloudAccounts, deleted: [(String, String)] = []) throws -> CloudApplyReport {
            try store.applyCloudChanges(saves: Array(records.values), deletions: deleted.map { ($0.0, $0.1) }, accounts: accounts)
        }
    }

    struct Device {
        let store: MailStore
        let accountID: String
        var accounts: CloudAccounts { CloudAccounts([(accountID, "Magnus@Tidings.test")]) }

        init(_ accountID: String) throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-cloud-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
            self.accountID = accountID
            try store.save(MailboxState(accountID: accountID, path: "INBOX", role: .inbox, uidValidity: 1, uidNext: nil,
                                        highestModSeq: nil, messageCount: 0, lastSync: nil))
        }

        func receive(_ uid: UInt32, messageID: String, thread: String, mailbox: String = "INBOX", category: MailCategory = .advertising) throws {
            var m = StoredMessage(accountID: accountID, mailbox: mailbox, uid: uid, messageID: messageID, threadID: thread,
                                  subject: "S\(uid)", fromAddress: "news@shop.dk", date: Date().addingTimeInterval(Double(uid)))
            m.category = category
            try store.upsert([(m, "S\(uid)")])
        }

        func message(_ messageID: String) throws -> StoredMessage? {
            try store.db.read { try StoredMessage.fetchOne($0, sql: "SELECT * FROM message WHERE messageID = ?", arguments: [messageID]) }
        }
    }

    // MARK: Accounts

    static let work = AccountConfig(
        id: "mac-local-id", displayName: "Work",
        endpoint: IMAPEndpoint(host: "imap.example.com", port: 993, useTLS: true, username: "Me@Example.com"),
        addresses: ["me@example.com"],
        smtp: SMTPEndpoint(host: "smtp.example.com", port: 587, security: .startTLS, username: "me@example.com"),
        identities: [Identity(address: "me@example.com", name: "Magnus", signature: "M")])

    static func records(_ accounts: [AccountConfig]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.login, CloudAccountRecord($0).payload) })
    }

    @Test func anAccountAddedOnOneDeviceArrivesOnTheOtherWithoutItsLocalID() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: Self.records([Self.work]))
        try cloud.push(mac.store)
        // No password and no local id in the record: only what's needed to set it up again.
        let sent = try #require(cloud.records.values.first { $0.type == StateRecordType.account.rawValue })
        #expect(sent.key == Self.work.login.lowercased())
        let text = String(decoding: sent.payload, as: UTF8.self)
        #expect(!text.contains("mac-local-id"))

        let report = try cloud.pull(into: phone.store, accounts: phone.accounts)
        let payload = try #require(report.accounts[Self.work.login.lowercased()])
        let arrived = try CloudAccountRecord(payload: payload).account(id: "phone-local-id")
        #expect(arrived.id == "phone-local-id")
        #expect(arrived.displayName == "Work")
        #expect(arrived.endpoint == Self.work.endpoint)
        #expect(arrived.smtp == Self.work.smtp)
        #expect(arrived.identities == Self.work.identities)

        // The phone now has it too: nothing to send back.
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts, accountRecords: Self.records([arrived])) == 0)
    }

    @Test func anUnchangedAccountIsNotSentAgainButAnEditIs() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account")
        try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: Self.records([Self.work]))
        try cloud.push(mac.store)
        #expect(try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: Self.records([Self.work])) == 0)
        var renamed = Self.work
        renamed.identities = [Identity(address: "me@example.com", name: "Magnus H. Kaspersen", signature: "M")]
        #expect(try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: Self.records([renamed])) == 1)
    }

    @Test func removingAnAccountRemovesItOnTheOtherDevice() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: Self.records([Self.work]))
        try cloud.push(mac.store)
        _ = try cloud.pull(into: phone.store, accounts: phone.accounts)

        // Gone from the Mac's list: its deletion goes up and the phone hears about it.
        try mac.store.collectCloudChanges(accounts: mac.accounts, accountRecords: [:])
        let deletion = try #require(try mac.store.pendingCloudChanges().first)
        #expect(deletion == .delete(type: StateRecordType.account.rawValue, key: Self.work.login.lowercased()))
        try cloud.push(mac.store)
        let report = try cloud.pull(into: phone.store, accounts: phone.accounts,
                                    deleted: [(StateRecordType.account.rawValue, Self.work.login.lowercased())])
        #expect(report.removedAccounts == [Self.work.login.lowercased()])
    }

    @Test func rulesFoldersSendersAndSettingsTravelBothWays() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        let rule = Rule(name: "Shoes", conditions: [.sender(TextMatch(.endsWith, "@shoes.dk"))], actions: [.done])
        try mac.store.saveRules([rule])
        try mac.store.saveSmartFolders([SmartFolder(name: "Anna", query: "from:anna")])
        _ = try mac.store.remember(category: .newsletters, forSender: "news@shop.dk")
        try mac.store.trustImages(from: "@firma.dk")
        try mac.store.recordUnsubscribe(address: "deals@x.dk", method: "oneClick")
        #expect(try mac.store.collectCloudChanges(accounts: mac.accounts, settings: ["bundleSchedules": Data("{\"a\":1}".utf8)]) == 6)
        try cloud.push(mac.store)
        #expect(try mac.store.pendingCloudChanges().isEmpty)
        #expect(try mac.store.collectCloudChanges(accounts: mac.accounts, settings: ["bundleSchedules": Data("{\"a\":1}".utf8)]) == 0)

        let report = try cloud.pull(into: phone.store, accounts: phone.accounts)
        #expect(report.applied == 6)
        #expect(report.settings["bundleSchedules"] == Data("{\"a\":1}".utf8))
        #expect(try phone.store.rules() == [rule])
        #expect(try phone.store.smartFolders().map(\.name) == ["Anna"])
        #expect(try phone.store.senderRule(for: "news@shop.dk")?.category == .newsletters)
        #expect(try phone.store.unsubscribedAt(address: "deals@x.dk") != nil)
        // Applying doesn't echo back as a change.
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts, settings: ["bundleSchedules": Data("{\"a\":1}".utf8)]) == 0)

        // The phone deletes the rule; the Mac follows.
        try phone.store.saveRules([])
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts, settings: ["bundleSchedules": Data("{\"a\":1}".utf8)]) == 1)
        try cloud.push(phone.store)
        _ = try cloud.pull(into: mac.store, accounts: mac.accounts, deleted: [("rule", rule.id)])
        #expect(try mac.store.rules().isEmpty)
    }

    /// "Use as Archive" on the Mac: the phone uses that folder too, and "back to the server's
    /// choice" follows.
    @Test func useAsTravelsByLogin() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        for device in [mac, phone] {
            for (path, role) in [("INBOX.Archive", MailboxRole.archive), ("INBOX.Done", nil)] {
                try device.store.save(MailboxState(accountID: device.accountID, path: path, role: role, uidValidity: 1, uidNext: nil,
                                                   highestModSeq: nil, messageCount: 0, lastSync: nil))
            }
        }
        try mac.store.useFolder("INBOX.Done", for: .archive, accountID: mac.accountID)
        #expect(try mac.store.collectCloudChanges(accounts: mac.accounts, settings: [:]) == 1)
        try cloud.push(mac.store)
        #expect(try cloud.pull(into: phone.store, accounts: phone.accounts).applied == 1)
        let roles = try phone.store.mailboxStates(accountID: phone.accountID)
        #expect(roles.first { $0.role == .archive }?.path == "INBOX.Done")
        #expect(try phone.store.setting(AccountSync.roleChoiceKey(.archive), accountID: phone.accountID) == "INBOX.Done")
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts, settings: [:]) == 0, "no echo")

        // Back to the server's choice on the phone: the Mac forgets its choice too.
        try phone.store.useFolder(nil, for: .archive, accountID: phone.accountID)
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts, settings: [:]) == 1)
        try cloud.push(phone.store)
        _ = try cloud.pull(into: mac.store, accounts: mac.accounts, deleted: [("folderRole", "magnus@tidings.test|archive")])
        #expect(try mac.store.setting(AccountSync.roleChoiceKey(.archive), accountID: mac.accountID) == "")
    }

    @Test func replyLaterFollowsTheMessageEvenBeforeItArrives() async throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        try mac.receive(1, messageID: "<a@shop.dk>", thread: "t-mac")
        let sync = AccountSync(account: AccountConfig(id: mac.accountID, displayName: "M",
                                                      endpoint: IMAPEndpoint(host: "127.0.0.1", port: 1, useTLS: false, username: "magnus@tidings.test"),
                                                      addresses: ["magnus@tidings.test"]),
                               password: "x", store: mac.store, cache: MessageCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID())")))
        try await sync.perform(.replyLater, threadIDs: ["t-mac"])
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        try cloud.push(mac.store)

        // The phone hasn't synced that mail yet: the state waits, then lands with the mail.
        _ = try cloud.pull(into: phone.store, accounts: phone.accounts)
        try phone.receive(7, messageID: "<a@shop.dk>", thread: "t-phone")
        #expect(try phone.message("<a@shop.dk>")?.flags.contains(replyLaterKeyword) == false)
        try phone.store.reassertMessageStates(accounts: phone.accounts)
        #expect(try phone.message("<a@shop.dk>")?.flags.contains(replyLaterKeyword) == true)

        // A mail sync from iCloud drops the keyword again; the next re-apply restores it, and
        // nothing is broadcast as a change.
        try await phone.store.db.write { try $0.execute(sql: "UPDATE message SET flags = '' WHERE messageID = '<a@shop.dk>'") }
        try phone.store.reassertMessageStates(accounts: phone.accounts)
        #expect(try phone.message("<a@shop.dk>")?.flags.contains(replyLaterKeyword) == true)
        #expect(try phone.store.collectCloudChanges(accounts: phone.accounts) == 0)

        // Clearing it on the Mac (and undo of that) travels too.
        let change = try await sync.perform(.clearReplyLater, threadIDs: ["t-mac"])
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        try cloud.push(mac.store)
        _ = try cloud.pull(into: phone.store, accounts: phone.accounts, deleted: [("messageState", "magnus@tidings.test|<a@shop.dk>")])
        #expect(try phone.message("<a@shop.dk>")?.flags.contains(replyLaterKeyword) == false)
        if let change { try await sync.undo(change) }
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        #expect(try mac.store.pendingCloudChanges().count == 1)
    }

    @Test func mutesAndCorrectionsMatchByMessageIDAcrossDifferentThreadIDs() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        try mac.receive(1, messageID: "<root@x>", thread: "mac-thread")
        try mac.receive(2, messageID: "<reply@x>", thread: "mac-thread")
        try mac.store.mute(threadID: "mac-thread")
        let ids = try mac.store.db.read { try Int64.fetchAll($0, sql: "SELECT id FROM message WHERE messageID = '<reply@x>'") }
        try mac.store.setCategory(.primary, reason: .youMovedThisConversation(.primary), ids: ids)
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        try cloud.push(mac.store)

        try phone.receive(5, messageID: "<reply@x>", thread: "phone-thread")    // only the reply is here
        let report = try cloud.pull(into: phone.store, accounts: phone.accounts)
        #expect(report.deferred == 0)
        #expect(try phone.store.isMuted(threadID: "phone-thread"))
        #expect(try phone.message("<reply@x>")?.category == .primary)
    }

    @Test func newerLocalChangeWinsAndStateBeforeSyncDefersToTheCloud() throws {
        let cloud = FakeCloud()
        let mac = try Device("mac-account"), phone = try Device("phone-account")
        let r1 = Rule(id: "r", name: "One", conditions: [.subject(TextMatch(.contains, "a"))], actions: [.pin])
        try mac.store.saveRules([r1])
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        try cloud.push(mac.store)
        // The phone had its own older version of the rule before sync was on: the cloud's wins.
        var phoneVersion = r1
        phoneVersion.name = "Old phone copy"
        try phone.store.saveRules([phoneVersion])
        try phone.store.collectCloudChanges(accounts: phone.accounts)
        _ = try cloud.pull(into: phone.store, accounts: phone.accounts)
        #expect(try phone.store.rules().first?.name == "One")

        // An edit made after syncing is newer than the cloud's and survives an incoming copy.
        var edited = r1
        edited.name = "Edited on phone"
        try phone.store.saveRules([edited])
        try phone.store.collectCloudChanges(accounts: phone.accounts, now: Date().addingTimeInterval(60))
        let report = try cloud.pull(into: phone.store, accounts: phone.accounts)
        #expect(report.skipped == 1)
        #expect(try phone.store.rules().first?.name == "Edited on phone")
        try cloud.push(phone.store)
        _ = try cloud.pull(into: mac.store, accounts: mac.accounts)
        #expect(try mac.store.rules().first?.name == "Edited on phone")
    }
}
