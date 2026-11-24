import Foundation
import Testing
@testable import MailEngine

/// Outbox end to end: Dovecot for IMAP (Sent copy, \Answered), Mailpit for SMTP.
@Suite(.serialized) struct OutboxIntegrationTests {
    struct Fixture {
        let sync: AccountSync
        let store: MailStore
        let endpoint: IMAPEndpoint
        let me = MailAddress(name: "Magnus Kaspersen", address: TestMailFactory.me.address)

        func message(_ subject: String, to: String = "anna@example.dk") -> OutgoingMessage {
            OutgoingMessage(from: me, to: [MailAddress(name: nil, address: to)], subject: subject, text: "Test \(subject)")
        }

        func sentOnServer() async throws -> [String] {
            try await MailSession.open(endpoint: endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
                guard try await session.listMailboxes().contains(where: { $0.path == "Sent" }) else { return [] }
                _ = try await session.select("Sent", readOnly: true)
                return Array(try await session.fetchHeaderField("Message-ID").values)
            }
        }
    }

    func fixture(smtpPort: Int = 31587, sentPolicy: AccountSync.SentCopyPolicy? = .client) async throws -> Fixture? {
        guard await SMTPIntegrationTests.available,
              (try? await MailSession.probeGreeting(endpoint: IMAPIntegrationTests.endpoint)) != nil else { return nil }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "outbox-\(UUID().uuidString.prefix(8))")
        _ = try await TestServerSeeder.seed(endpoint: endpoint, password: "tidings-test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-outbox-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        var smtp = SMTPIntegrationTests.endpoint
        smtp.port = smtpPort
        let account = AccountConfig(id: "o", displayName: "O", endpoint: endpoint, addresses: [TestMailFactory.me.address], smtp: smtp)
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: .iCloudSimulation)
        try await sync.syncOnce()
        if let sentPolicy { try store.setSetting(AccountSync.sentCopyKey, sentPolicy.rawValue, accountID: "o") }
        return Fixture(sync: sync, store: store, endpoint: endpoint)
    }

    @Test func undoWindowHoldsTheMessageAndCancelReturnsADraft() async throws {
        guard let f = try await fixture() else { return }
        let message = f.message("Undo me")
        let item = try await f.sync.queue(message)
        try await f.sync.processOutbox()   // not due yet: still inside the 10 s window
        #expect(try await SMTPIntegrationTests.caught(messageID: message.messageID) == nil)

        let draft = try #require(try await f.sync.cancelSend(id: item.id!))
        #expect(draft.state == .draft)
        #expect(draft.message?.subject == "Undo me")
        #expect(try f.store.outbox(accountID: "o").isEmpty)
    }

    @Test func dueMessageIsSentFiledInSentAndRemovedFromOutbox() async throws {
        guard let f = try await fixture() else { return }
        let message = f.message("Sent for real")
        try await f.sync.queue(message, sendAt: Date())
        try await f.sync.processOutbox()
        #expect(try await SMTPIntegrationTests.caught(messageID: message.messageID) != nil)
        #expect(try f.store.outbox(accountID: "o").isEmpty)
        #expect(try await f.sentOnServer().contains { $0.contains(message.messageID) }, "copy appended to Sent")
    }

    @Test func firstSendLearnsThatThisServerNeedsAClientCopy() async throws {
        guard let f = try await fixture(sentPolicy: nil) else { return }
        let message = f.message("Learn policy")
        try await f.sync.queue(message, sendAt: Date())
        try await f.sync.processOutbox()   // Dovecot never files its own copy → ~12 s of checking, then append
        #expect(try f.store.setting(AccountSync.sentCopyKey, accountID: "o") == "client")
        #expect(try await f.sentOnServer().filter { $0.contains(message.messageID) }.count == 1)
    }

    @Test func replyMarksTheOriginalAnswered() async throws {
        guard let f = try await fixture() else { return }
        let original = try #require(try f.store.threads(mailbox: "INBOX").first { $0.latest.subject.contains("website") }?.latest)
        try await f.sync.queue(f.message("Re: Quick question about the website", to: "sofie@example.com"),
                               sendAt: Date(), kind: .reply, originalLocalID: original.id)
        try await f.sync.processOutbox()
        let flags = try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
            _ = try await session.select("INBOX", readOnly: true)
            return try await session.fetchFlags(uids: [original.uid])[original.uid]?.flags ?? []
        }
        #expect(flags.contains("\\Answered"))
    }

    @Test func unreachableServerKeepsTheMessageQueuedWithAnError() async throws {
        guard let f = try await fixture(smtpPort: 1) else { return }   // nothing listens on port 1
        let message = f.message("Will retry")
        let item = try await f.sync.queue(message, sendAt: Date())
        try await f.sync.processOutbox()
        let after = try #require(try f.store.outboxItem(id: item.id!))
        #expect(after.state == .queued, "network errors are retried")
        #expect(after.attempts == 1)
        #expect(after.lastError != nil)
        #expect(after.sendAt! > Date(), "backed off")
    }

    @Test func identityForReplyMatchesTheAddressItWasSentTo() {
        let account = AccountConfig(displayName: "M", endpoint: .iCloud(address: "magnushkaspersen@icloud.com"),
                                    addresses: ["magnushkaspersen@icloud.com"],
                                    identities: [Identity(address: "magnushkaspersen@icloud.com", name: "Magnus"),
                                                 Identity(address: "m@gnus.hk", name: "Magnus H. Kaspersen")])
        let parsed = MIMEParser.parse(Data("To: Magnus <M@gnus.hk>\r\nFrom: a@x.dk\r\nSubject: s\r\n\r\nb".utf8))
        #expect(account.identity(replyingTo: parsed).address == "m@gnus.hk")
    }
}
