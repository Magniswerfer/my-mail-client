import Foundation
import Testing
@testable import MailEngine

/// End-to-end: seed a fresh Dovecot user, sync it with AccountSync, check the store.
@Suite(.serialized) struct SyncIntegrationTests {
    static var serverAvailable: Bool {
        get async { (try? await MailSession.probeGreeting(endpoint: IMAPIntegrationTests.endpoint)) != nil }
    }

    func makeSync() async throws -> (AccountSync, MailStore)? {
        guard await Self.serverAvailable else { return nil }
        let user = "sync-\(UUID().uuidString.prefix(8))"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: user)
        _ = try await TestServerSeeder.seed(endpoint: endpoint, password: "tidings-test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-sync-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "test", displayName: "Test", endpoint: endpoint, addresses: [TestMailFactory.me.address])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: .iCloudSimulation)
        return (sync, store)
    }

    @Test func initialSyncFillsStoreWithThreadsAndCategories() async throws {
        guard let (sync, store) = try await makeSync() else { return }
        try await sync.syncOnce()

        let seeds = TestMailFactory.mailbox()
        #expect(try store.count() == seeds.count)

        let inbox = try store.threads(mailbox: "INBOX", ownAddresses: [TestMailFactory.me.address])
        let dinner = try #require(inbox.first { $0.latest.subject.contains("Middag") })
        #expect(dinner.messageCount == 3, "two inbox messages + my reply in Sent")
        #expect(dinner.unreadCount == 1)
        #expect(dinner.latest.fromName == "Anna Jensen")
        #expect(dinner.participants == ["Anna Jensen"], "my own name is left out")
        #expect(try store.messages(inThread: dinner.threadID).map(\.mailbox) == ["INBOX", "Sent", "INBOX"])

        let byCategory = Dictionary(grouping: inbox, by: \.latest.category)
        #expect(byCategory[.newsletters]?.count == 3)
        #expect(byCategory[.advertising]?.count == 3)
        #expect(byCategory[.transactions]?.count == 3)
        #expect(byCategory[.social]?.count == 1)
        #expect(byCategory[.updates]?.count == 2)
        #expect(byCategory[.primary]?.count == 4, "3 conversations + the phishing attempt")
        let phish = try #require(inbox.first { $0.latest.subject == "Din Apple-konto er låst" })
        #expect(phish.latest.riskLevel == .danger)
        #expect(RiskAssessment.decode(phish.latest.riskReasons).count >= 2)

        let contract = try #require(inbox.first { $0.latest.subject == "Kontrakt til gennemsyn" })
        #expect(contract.latest.hasAttachments)
        #expect(contract.latest.flags.contains("\\Flagged"))

        let hits = try SearchEngine(store: store).hits(SearchQuery(parsing: "faktura in:Archive"))
        #expect(hits.hits.count == 12)
    }

    @Test func secondSyncIsIncrementalAndIdempotent() async throws {
        guard let (sync, store) = try await makeSync() else { return }
        try await sync.syncOnce()
        let first = try store.count()
        try await sync.syncOnce()
        #expect(try store.count() == first)
    }

    @Test func syncNeverMarksMailRead() async throws {
        guard let (sync, store) = try await makeSync() else { return }
        try await sync.syncOnce()
        let unreadBefore = try store.threads(mailbox: "INBOX").reduce(0) { $0 + $1.unreadCount }
        try await sync.syncOnce() // re-reads server flags
        let unreadAfter = try store.threads(mailbox: "INBOX").reduce(0) { $0 + $1.unreadCount }
        #expect(unreadBefore == unreadAfter)
        #expect(unreadBefore > 0)
    }

    @Test func readingPaneFetchesFromCache() async throws {
        guard let (sync, store) = try await makeSync() else { return }
        try await sync.syncOnce()
        let message = try #require(try store.threads(mailbox: "INBOX").first?.latest)
        let raw = try await sync.rawMessage(message)
        #expect(MIMEParser.parse(raw).subject == message.subject)
    }
}
