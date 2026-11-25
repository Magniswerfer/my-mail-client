import Foundation
import Testing
@testable import MailEngine

@Suite struct NotificationPolicyTests {
    let me = "magnus@tidings.test"

    func store() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-notify-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        for (path, role) in [("INBOX", MailboxRole.inbox), ("Sent Messages", .sent)] {
            try s.save(MailboxState(accountID: "a", path: path, role: role, uidValidity: 1, uidNext: nil, highestModSeq: nil,
                                    messageCount: 0, lastSync: nil))
        }
        return s
    }

    func message(_ uid: UInt32, thread: String, mailbox: String = "INBOX", from: String, to: String = "magnus@tidings.test",
                 minutesAgo: Double, category: MailCategory = .primary, flags: String = "") -> StoredMessage {
        var m = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: thread, subject: "S\(uid)",
                              fromName: nil, fromAddress: from, recipients: to, date: Date().addingTimeInterval(-minutesAgo * 60))
        m.category = category
        m.flags = flags
        return m
    }

    @Test func reasonsInOrderOfImportance() throws {
        let s = try store()
        let messages = [
            message(1, thread: "waiting", mailbox: "Sent Messages", from: me, to: "bo@x.dk", minutesAgo: 120),
            message(2, thread: "waiting", from: "bo@x.dk", minutesAgo: 5, category: .updates),        // reply to me
            message(3, thread: "pinned", from: "shop@x.dk", minutesAgo: 60, category: .advertising, flags: "\\Flagged \\Seen"),
            message(4, thread: "pinned", from: "shop@x.dk", minutesAgo: 4, category: .advertising),    // pinned thread
            message(5, thread: "anna", from: "anna@firma.dk", minutesAgo: 3),                          // Primary person
            message(6, thread: "ad", from: "deals@x.dk", minutesAgo: 2, category: .advertising),       // bundle: quiet
            message(7, thread: "read", from: "anna@firma.dk", minutesAgo: 2, flags: "\\Seen"),          // already read
            message(8, thread: "old", from: "anna@firma.dk", minutesAgo: 60 * 30),                     // caught up after sleep
            message(9, thread: "mine", from: me, minutesAgo: 1),                                       // my own
        ]
        try s.upsert(messages.map { ($0, $0.subject) })
        let arrived = try s.inboxMessages().sorted { $0.date < $1.date }
        let ruled = try #require(arrived.first { $0.uid == 6 })
        let run = RuleRun(id: 1, at: Date(), accountID: "a", messageID: ruled.id!, threadID: "ad", subject: "", sender: "",
                          ruleIDs: ["r"], ruleNames: ["Deals I want"], actions: [.notify], previousCategory: .advertising,
                          previousReason: nil, undoneAt: nil)
        let policy = NotificationPolicy()
        let reasons = policy.notifications(for: arrived, ruleRuns: [run], ownAddresses: [me], store: s)
            .map { "\($0.threadID):\($0.reason)" }
        #expect(reasons == ["waiting:reply", "pinned:pinned", "anna:person", "ad:rule(\"Deals I want\")"])

        var vipOnly = policy
        vipOnly.onlyVIPs = true
        vipOnly.vips = ["ANNA@firma.dk"]
        #expect(vipOnly.notifications(for: arrived, ruleRuns: [], ownAddresses: [me], store: s).map(\.reason).contains(.vip))
        vipOnly.vips = []
        #expect(!vipOnly.notifications(for: arrived, ruleRuns: [], ownAddresses: [me], store: s).map(\.threadID).contains("anna"))

        try s.mute(threadID: "anna")
        #expect(!policy.notifications(for: arrived, ruleRuns: [], ownAddresses: [me], store: s).map(\.threadID).contains("anna"))

        var off = policy
        off.isEnabled = false
        #expect(off.notifications(for: arrived, ruleRuns: [run], ownAddresses: [me], store: s).isEmpty)
    }

    @Test func vipsAreSeededFromWhoYouWriteTo() throws {
        let s = try store()
        try s.upsert([
            message(1, thread: "a", mailbox: "Sent Messages", from: me, to: "Anna <anna@firma.dk>, bo@x.dk", minutesAgo: 10),
            message(2, thread: "b", mailbox: "Sent Messages", from: me, to: "Anna <anna@firma.dk>", minutesAgo: 9),
            message(3, thread: "c", mailbox: "Sent Messages", from: me, to: "noreply@shop.dk", minutesAgo: 8),
        ].map { ($0, $0.subject) })
        #expect(try s.frequentCorrespondents(ownAddresses: [me]).map(\.address) == ["anna@firma.dk", "bo@x.dk"])
    }
}

@Suite(.serialized) struct MuteIntegrationTests {
    @Test func newMailInAMutedConversationSkipsTheInbox() async throws {
        guard let f = try await TriageIntegrationTests().fixture() else { return }
        let thread = try f.thread("website")
        try f.store.mute(threadID: thread.threadID)
        // A reply arrives in the muted conversation.
        let raw = TestMailFactory.text(from: MailAddress(name: "Sofie", address: "sofie@example.dk"), to: [TestMailFactory.me],
                                       subject: "Re: \(thread.latest.subject)", date: Date(), id: "<\(UUID().uuidString)@x>",
                                       body: "One more thing")
        var withReply = String(decoding: raw, as: UTF8.self)
        if let original = thread.latest.messageID {
            withReply = withReply.replacingOccurrences(of: "Subject:", with: "In-Reply-To: \(original)\r\nReferences: \(original)\r\nSubject:")
        }
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
            _ = try await session.append(to: "INBOX", message: Data(withReply.utf8))
        }
        try await f.sync.syncOnce()
        let report = try await f.sync.runRules(engine: RuleEngine())
        #expect(report.arrived.count == 1)
        #expect(try f.inbox().contains { $0.threadID == thread.threadID } == false)
    }
}
