import Foundation
import Testing
@testable import MailEngine

/// The push server's side of the engine (ADR 0007): deciding on notifications without acting,
/// and taking a device's state snapshot.
@Suite struct PushPassTests {
    let me = "magnus@tidings.test"

    func fixture() throws -> (AccountSync, MailStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-push-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        for (path, role) in [("INBOX", MailboxRole.inbox), ("Sent Messages", .sent)] {
            try store.save(MailboxState(accountID: "a", path: path, role: role, uidValidity: 1, uidNext: nil, highestModSeq: nil,
                                        messageCount: 0, lastSync: nil))
        }
        let account = AccountConfig(id: "a", displayName: "Test",
                                    endpoint: IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: me),
                                    addresses: [me])
        let sync = AccountSync(account: account, password: "x", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), scope: .pushServer)
        return (sync, store)
    }

    func message(_ uid: UInt32, thread: String, from: String, subject: String = "Hej", category: MailCategory = .primary) -> StoredMessage {
        var m = StoredMessage(accountID: "a", mailbox: "INBOX", uid: uid, messageID: "m\(uid)@x", threadID: thread, subject: subject,
                              fromName: nil, fromAddress: from, recipients: me, date: Date().addingTimeInterval(-60))
        m.category = category
        return m
    }

    @Test func notifiesPeopleAndNotifyRulesWithoutChangingAnything() async throws {
        let (sync, store) = try fixture()
        try store.saveRules([
            Rule(name: "Deals I want", conditions: [.sender(TextMatch(.contains, "deals@"))], actions: [.notify]),
            Rule(name: "Boss is an update", conditions: [.sender(TextMatch(.equals, "boss@firma.dk"))], actions: [.setCategory(.updates)]),
            Rule(name: "File receipts", conditions: [.subject(TextMatch(.contains, "Kvittering"))], actions: [.done]),
        ])
        try store.upsert([
            message(1, thread: "anna", from: "anna@firma.dk"),
            message(2, thread: "ad", from: "deals@shop.dk", category: .advertising),
            message(3, thread: "boss", from: "boss@firma.dk"),
            message(4, thread: "news", from: "news@paper.dk", category: .newsletters),
            message(5, thread: "receipt", from: "anna@firma.dk", subject: "Kvittering"),
        ].map { ($0, $0.subject) })
        let flagsBefore = try store.inboxMessages().map(\.flags)

        let found = try await sync.notificationPass(policy: NotificationPolicy())
        #expect(Set(found.map(\.threadID)) == ["anna", "ad"])
        #expect(found.first { $0.threadID == "ad" }?.reason == .rule("Deals I want"))

        // Nothing moved, nothing recorded, and the same mail isn't offered twice.
        #expect(try store.inboxMessages().count == 5)
        #expect(try store.inboxMessages().map(\.flags) == flagsBefore)
        #expect(try store.ruleRuns().isEmpty)
        #expect(try await sync.notificationPass(policy: NotificationPolicy()).isEmpty)
    }

    @Test func aSnapshotAppliesAndLaterRemovesState() throws {
        let device = try fixture().1
        let server = try fixture().1
        let accounts = CloudAccounts([(id: "a", login: me)])
        try device.saveRules([Rule(name: "Notify", conditions: [.sender(TextMatch(.contains, "x"))], actions: [.notify])])
        try device.upsert([message(1, thread: "t", from: "anna@firma.dk")].map { ($0, $0.subject) })
        try device.mute(threadID: "t")
        var policy = NotificationPolicy()
        policy.vips = ["anna@firma.dk"]
        let settings = ["notificationPolicy.v1": try JSONEncoder().encode(policy)]
        try server.upsert([message(1, thread: "server-thread", from: "anna@firma.dk")].map { ($0, $0.subject) })

        let snapshot = try device.stateSnapshot(accounts: accounts, settings: settings)
        #expect(Set(snapshot.map(\.type)) == ["rule", "mute", "setting"])
        let report = try server.applyStateSnapshot(snapshot, accounts: accounts)
        #expect(report.applied == 3)
        #expect(try server.rules().map(\.name) == ["Notify"])
        #expect(try server.isMuted(threadID: "server-thread"))
        let stored = try #require(try server.appliedState(type: "setting", key: "notificationPolicy.v1"))
        #expect(try JSONDecoder().decode(NotificationPolicy.self, from: stored).vips == ["anna@firma.dk"])

        // The same snapshot again changes nothing; one without the rule removes it.
        #expect(try server.applyStateSnapshot(snapshot, accounts: accounts).applied == 0)
        try server.applyStateSnapshot(snapshot.filter { $0.type != "rule" }, accounts: accounts)
        #expect(try server.rules().isEmpty)
        #expect(try server.isMuted(threadID: "server-thread"))
    }

    @Test func handedOffMailIsNeverSentFromHereButCanBeTakenBack() async throws {
        let (sync, store) = try fixture()
        let message = OutgoingMessage(from: MailAddress(name: nil, address: me), to: [MailAddress(name: nil, address: "a@x.dk")],
                                      subject: "Later", text: "Hej")
        let item = try await sync.queue(message, sendAt: Date().addingTimeInterval(-1))
        let id = try #require(item.id)
        try await sync.markHandedOff(id: id)
        #expect(try store.outboxItem(id: id)?.state == .remote)
        #expect(try store.dueOutbox(accountID: "a").isEmpty, "the server sends it, not this device")
        #expect(try store.outbox().map(\.id) == [id], "still listed as scheduled")
        #expect(try await sync.cancelSend(id: id)?.state == .draft)
    }
}

