import Foundation
import Testing
@testable import MailEngine

/// Settings for generic accounts, `account:` in search, and removing an account (no server).
@Suite struct MultiAccountUnitTests {
    let personal = AccountConfig(id: "p", displayName: "magnus@icloud.com", endpoint: .iCloud(address: "magnus@icloud.com"),
                                 addresses: ["magnus@icloud.com", "m@kaspersen.dk"])
    let work = AccountConfig(id: "w", displayName: "Work",
                             endpoint: IMAPEndpoint(host: "mail.work.test", port: 993, useTLS: true, username: "magnus"),
                             addresses: ["magnus@work.test"])

    func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-multi-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
    }

    func receive(_ store: MailStore, account: String, uid: UInt32, messageID: String, thread: String, mailbox: String = "INBOX",
                 subject: String = "Hello") throws {
        let m = StoredMessage(accountID: account, mailbox: mailbox, uid: uid, messageID: messageID, threadID: thread,
                              subject: subject, fromAddress: "anna@example.dk", date: Date().addingTimeInterval(Double(uid)))
        try store.upsert([(m, subject)])
    }

    // MARK: Providers

    @Test func builtInProvidersFillTheFormWithoutTheNetwork() throws {
        let gmail = try #require(MailProvider.builtIn(for: "Anna.Jensen@Gmail.com"))
        #expect(gmail.imap == IMAPEndpoint(host: "imap.gmail.com", port: 993, useTLS: true, username: "anna.jensen@gmail.com"))
        #expect(gmail.smtp.host == "smtp.gmail.com" && gmail.smtp.port == 465 && gmail.smtp.security == .tls)
        #expect(gmail.note == .appPassword)
        #expect(MailProvider.builtIn(for: "x@hotmail.dk")?.note == .oauthOnly)
        #expect(MailProvider.builtIn(for: "x@me.com")?.note == .iCloud)
        #expect(MailProvider.builtIn(for: "x@gmx.de")?.smtp.security == .startTLS)
        #expect(MailProvider.builtIn(for: "x@unknown-domain.dk") == nil)
        let guess = try #require(MailProvider.guess(for: "x@unknown-domain.dk"))
        #expect(guess.imap.host == "imap.unknown-domain.dk" && guess.smtp.host == "smtp.unknown-domain.dk")
        #expect(MailProvider.guess(for: "not an address") == nil)
    }

    static let autoconfig = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <clientConfig version="1.1">
          <emailProvider id="example.dk">
            <domain>example.dk</domain>
            <displayName>Example Mail</displayName>
            <incomingServer type="pop3">
              <hostname>pop.example.dk</hostname><port>995</port><socketType>SSL</socketType>
              <username>%EMAILADDRESS%</username>
            </incomingServer>
            <incomingServer type="imap">
              <hostname>imap.example.dk</hostname><port>143</port><socketType>STARTTLS</socketType>
              <username>%EMAILADDRESS%</username>
            </incomingServer>
            <incomingServer type="imap">
              <hostname>IMAP.example.dk</hostname><port>993</port><socketType>SSL</socketType>
              <username>%EMAILLOCALPART%</username>
            </incomingServer>
            <outgoingServer type="smtp">
              <hostname>smtp.example.dk</hostname><port>25</port><socketType>plain</socketType>
              <username>%EMAILADDRESS%</username>
            </outgoingServer>
            <outgoingServer type="smtp">
              <hostname>smtp.example.dk</hostname><port>587</port><socketType>STARTTLS</socketType>
              <username>%EMAILADDRESS%</username>
            </outgoingServer>
          </emailProvider>
        </clientConfig>
        """.utf8)

    @Test func autoconfigTakesTheEncryptedServersAndExpandsTheLogin() throws {
        let s = try #require(MailProvider.parseAutoconfig(Self.autoconfig, address: "Anna@Example.dk"))
        #expect(s.imap == IMAPEndpoint(host: "imap.example.dk", port: 993, useTLS: true, username: "anna"))
        #expect(s.smtp.host == "smtp.example.dk" && s.smtp.port == 587 && s.smtp.security == .startTLS)
        #expect(s.smtp.username == "anna@example.dk")
        #expect(s.source == "Example Mail")
        #expect(MailProvider.parseAutoconfig(Data("<html>nope</html>".utf8), address: "a@example.dk") == nil)
    }

    @Test func lookUpTriesTheDomainThenThunderbirdsDatabaseAndSendsOnlyTheDomain() async throws {
        actor Seen { var urls: [URL] = []; func add(_ u: URL) { urls.append(u) } }
        let seen = Seen()
        let found = await MailProvider.lookUp("anna@example.dk") { url in
            await seen.add(url)
            if url.host == "autoconfig.thunderbird.net" { return Self.autoconfig }
            throw URLError(.cannotFindHost)
        }
        #expect(found?.imap.host == "imap.example.dk")
        #expect(found?.source == "autoconfig.thunderbird.net")
        let urls = await seen.urls
        #expect(urls.count == 3)
        #expect(urls.allSatisfy { $0.scheme == "https" && !$0.absoluteString.contains("anna") })
        // Built-in providers never ask the network.
        let gmail = await MailProvider.lookUp("x@gmail.com") { _ in Issue.record("no network for Gmail"); return Data() }
        #expect(gmail?.source == "Gmail")
    }

    // MARK: Accounts in search

    @Test func accountOperatorMatchesNameAddressAndDomain() {
        #expect(work.matches(searchValue: "work"))
        #expect(work.matches(searchValue: "magnus@work.test"))
        #expect(work.matches(searchValue: "work.test"))
        #expect(personal.matches(searchValue: "icloud"))
        #expect(personal.matches(searchValue: "kaspersen.dk"))
        #expect(!personal.matches(searchValue: "work"))
        #expect(work.login == "magnus@mail.work.test", "a bare login is told apart by its server")
        #expect(personal.login == "magnus@icloud.com")
        #expect(personal.isICloud && !work.isICloud)

        let q = SearchQuery(parsing: "faktura account:work account:\"magnus@icloud.com\"")
        #expect(q.accounts == ["work", "magnus@icloud.com"])
        #expect(q.terms == ["faktura"])
        #expect(q.resolvingAccounts([personal, work]).accounts == ["w", "p"])
        #expect(SearchQuery(parsing: "account:nobody").resolvingAccounts([personal, work]).accounts.allSatisfy { $0.hasPrefix("\u{0}") })
    }

    @Test func searchCanBeLimitedToOneAccount() throws {
        let store = try makeStore()
        try receive(store, account: "p", uid: 1, messageID: "a@x", thread: "a", subject: "Faktura fra Anna")
        try receive(store, account: "w", uid: 1, messageID: "b@x", thread: "b", subject: "Faktura fra kunden")
        let engine = SearchEngine(store: store)
        #expect(try engine.hits(SearchQuery(parsing: "faktura")).hits.count == 2)
        let onlyWork = SearchQuery(parsing: "faktura account:work").resolvingAccounts([personal, work])
        #expect(try engine.hits(onlyWork).hits.map(\.subject) == ["Faktura fra kunden"])
        #expect(try engine.conversationCount(onlyWork) == 1)
        let nobody = SearchQuery(parsing: "faktura account:nobody").resolvingAccounts([personal, work])
        #expect(try engine.hits(nobody).hits.isEmpty)
    }

    // MARK: Removing an account

    @Test func removingAnAccountDeletesOnlyItsDataAndNeverDeletesInICloud() throws {
        let store = try makeStore()
        let cloud = CloudAccounts([(personal.id, personal.login), (work.id, work.login)])
        try store.save(MailboxState(accountID: "w", path: "INBOX", role: .inbox, uidValidity: 1, uidNext: nil,
                                    highestModSeq: nil, messageCount: 2, lastSync: nil))
        try store.save(MailboxState(accountID: "p", path: "INBOX", role: .inbox, uidValidity: 1, uidNext: nil,
                                    highestModSeq: nil, messageCount: 2, lastSync: nil))
        try receive(store, account: "p", uid: 1, messageID: "own@x", thread: "own-p")
        try receive(store, account: "w", uid: 1, messageID: "own@w", thread: "own-w")
        // One conversation in both accounts (sent to both addresses).
        try receive(store, account: "p", uid: 2, messageID: "both@x", thread: "both")
        try receive(store, account: "w", uid: 2, messageID: "both@x", thread: "both")
        try store.mute(threadID: "own-w")
        try store.mute(threadID: "both")
        try store.setSetting("sentCopy", "client", accountID: "w")
        _ = try store.save(OutboxItem(accountID: "w", message: OutgoingMessage(from: MailAddress(name: nil, address: "magnus@work.test"),
                                                                              to: [], subject: "Draft", text: ""), state: .draft))
        let sync = AccountSync(account: work, password: "x", store: store,
                               cache: MessageCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID())")))
        // Reply Later on the work copy: CloudKit state keyed by the work login.
        _ = try store.db.write { db in
            try db.execute(sql: "INSERT INTO messageState (account, messageID, payload, modifiedAt) VALUES (?, ?, ?, ?)",
                           arguments: [work.login, "own@w", Data("{}".utf8), Date()])
        }
        // Everything is in iCloud already.
        try store.collectCloudChanges(accounts: cloud)
        for change in try store.pendingCloudChanges() { if case .save(let r) = change { try store.cloudSaved(r) } }
        #expect(try store.pendingCloudChanges().isEmpty)
        _ = sync

        try store.deleteAccount("w", cloudAccounts: cloud)

        #expect(try store.messageCounts() == ["p": 2])
        #expect(try store.mailboxStates(accountID: "w").isEmpty)
        #expect(try store.mailboxStates(accountID: "p").count == 1)
        #expect(try store.outbox(accountID: "w").isEmpty && store.drafts().allSatisfy { $0.accountID != "w" })
        #expect(try store.setting("sentCopy", accountID: "w") == nil)
        #expect(try !store.isMuted(threadID: "own-w"), "the work-only conversation's mute is gone here")
        #expect(try store.isMuted(threadID: "both"), "a conversation still in the other account keeps its mute")
        #expect(try store.threads(mailbox: "INBOX").map(\.threadID).sorted() == ["both", "own-p"])
        #expect(try SearchEngine(store: store).hits(SearchQuery(parsing: "hello")).hits.count == 2)
        // Removing an account on this device leaves its state in iCloud for the others.
        let afterCount = try store.collectCloudChanges(accounts: CloudAccounts([(personal.id, personal.login)]))
        #expect(afterCount == 0)
        #expect(try store.pendingCloudChanges().isEmpty)
    }

    @Test func aConversationInTwoAccountsIsActedOnInBoth() async throws {
        let store = try makeStore()
        try receive(store, account: "p", uid: 1, messageID: "both@x", thread: "both")
        try receive(store, account: "w", uid: 1, messageID: "both@x", thread: "both")
        try receive(store, account: "w", uid: 2, messageID: "w@x", thread: "only-w")
        let owners = try store.accountIDs(threadIDs: ["both", "only-w", "missing"], mailbox: "INBOX")
        #expect(owners == ["both": ["p", "w"], "only-w": ["w"]])
        #expect(try store.threads(mailbox: "INBOX").count == 2, "one row in the unified Inbox")
        #expect(try store.threads(mailbox: "INBOX").first { $0.threadID == "both" }?.messageCount == 1, "one message, two copies")
        #expect(try store.threads(mailbox: "INBOX", accountID: "p").map(\.threadID) == ["both"])
        #expect(try store.threads(mailbox: "INBOX", accountID: "w").count == 2)
    }
}

/// Two accounts on the local Dovecot, one store, the way the app runs them; sending from the
/// second one goes to Mailpit.
@Suite(.serialized) struct MultiAccountIntegrationTests {
    struct Fixture {
        let store: MailStore
        let personal: AccountSync
        let work: AccountSync
        let workEndpoint: IMAPEndpoint
        let personalEndpoint: IMAPEndpoint
        let dir: URL
    }

    func fixture() async throws -> Fixture? {
        guard (try? await MailSession.probeGreeting(endpoint: IMAPIntegrationTests.endpoint)) != nil else { return nil }
        let run = UUID().uuidString.prefix(8)
        let personalEndpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "personal-\(run)")
        let workEndpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "work-\(run)")
        _ = try await TestServerSeeder.seed(endpoint: personalEndpoint, password: "tidings-test")
        _ = try await TestServerSeeder.seed(endpoint: workEndpoint, password: "tidings-test", work: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-two-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let cache = MessageCache(directory: dir.appendingPathComponent("cache"))
        // The first account behaves like iCloud (no MOVE, no SPECIAL-USE); the second is a
        // plain generic IMAP server with every extension Dovecot has.
        let personal = AccountSync(account: AccountConfig(id: "personal", displayName: "Personal", endpoint: personalEndpoint,
                                                          addresses: [TestMailFactory.me.address]),
                                   password: "tidings-test", store: store, cache: cache, profile: .iCloudSimulation)
        let work = AccountSync(account: AccountConfig(id: "work", displayName: "Work", endpoint: workEndpoint,
                                                      addresses: [TestMailFactory.work.address], smtp: SMTPIntegrationTests.endpoint),
                               password: "tidings-test", store: store, cache: cache, profile: .generic)
        try await personal.syncOnce()
        try await work.syncOnce()
        return Fixture(store: store, personal: personal, work: work, workEndpoint: workEndpoint,
                       personalEndpoint: personalEndpoint, dir: dir)
    }

    func inboxMessageIDs(_ endpoint: IMAPEndpoint) async throws -> [String] {
        try await MailSession.open(endpoint: endpoint, password: "tidings-test") { session in
            _ = try await session.select("INBOX", readOnly: true)
            return Array(try await session.fetchHeaderField("Message-ID").values)
        }
    }

    @Test func unifiedInboxHoldsBothAccountsAndEachAccountHasItsOwn() async throws {
        guard let f = try await fixture() else { return }
        let all = try f.store.threads(mailbox: "INBOX")
        let personal = try f.store.threads(mailbox: "INBOX", accountID: "personal")
        let work = try f.store.threads(mailbox: "INBOX", accountID: "work")
        #expect(personal.count > 10)
        #expect(work.count == 4, "Lene, Jonas, Jira and Anna's reply to both")
        #expect(all.count == personal.count + work.count - 1, "the dinner conversation is one row, not two")
        #expect(work.contains { $0.latest.subject == "Re: Kvartalsplan til mandag" && $0.messageCount == 3 })
        let dinner = try #require(all.first { $0.latest.subject.contains("Middag") })
        #expect(try f.store.accountIDs(threadIDs: [dinner.threadID], mailbox: "INBOX")[dinner.threadID] == ["personal", "work"])
        // Each account keeps its own folders.
        #expect(try f.store.mailboxStates(accountID: "work").contains { $0.role == .archive })
        #expect(try f.store.mailboxStates(accountID: "personal").contains { $0.role == .archive })
        let onlyWork = SearchQuery(parsing: "account:work").resolvingAccounts([
            AccountConfig(id: "personal", displayName: "Personal", endpoint: f.personalEndpoint, addresses: [TestMailFactory.me.address]),
            AccountConfig(id: "work", displayName: "Work", endpoint: f.workEndpoint, addresses: [TestMailFactory.work.address]),
        ])
        #expect(try SearchEngine(store: f.store).hits(onlyWork).hits.count == 7, "everything stored for the work account")
    }

    @Test func doneOnAConversationInBothAccountsArchivesItInBoth() async throws {
        guard let f = try await fixture() else { return }
        let dinner = try #require(try f.store.threads(mailbox: "INBOX").first { $0.latest.subject.contains("Middag") })
        // What the app does: perform in every account that has the conversation in the Inbox.
        let owners = try f.store.accountIDs(threadIDs: [dinner.threadID], mailbox: "INBOX")[dinner.threadID] ?? []
        for (id, sync) in [("personal", f.personal), ("work", f.work)] where owners.contains(id) {
            #expect(try await sync.perform(.done, threadIDs: [dinner.threadID]) != nil)
        }
        #expect(try !f.store.threads(mailbox: "INBOX").contains { $0.threadID == dinner.threadID })
        try await f.personal.syncOnce()
        try await f.work.syncOnce()
        #expect(try await !inboxMessageIDs(f.personalEndpoint).contains { $0.contains("seed-3@tidings.test") })
        #expect(try await !inboxMessageIDs(f.workEndpoint).contains { $0.contains("seed-3@tidings.test") })
        #expect(try await inboxMessageIDs(f.workEndpoint).contains { $0.contains("work-4@work.test") }, "the rest stays")
        #expect(try !f.store.threads(mailbox: "INBOX").contains { $0.threadID == dinner.threadID }, "and doesn't come back")
    }

    @Test func removingOneAccountLeavesTheOtherSyncing() async throws {
        guard let f = try await fixture() else { return }
        let personalBefore = try f.store.threads(mailbox: "INBOX", accountID: "personal").count
        try f.store.deleteAccount("work", cloudAccounts: CloudAccounts([("personal", f.personalEndpoint.username),
                                                                        ("work", f.workEndpoint.username)]))
        #expect(try f.store.threads(mailbox: "INBOX", accountID: "work").isEmpty)
        #expect(try f.store.mailboxStates(accountID: "work").isEmpty)
        #expect(try f.store.threads(mailbox: "INBOX").count == personalBefore)
        try await f.personal.syncOnce()
        #expect(try f.store.threads(mailbox: "INBOX").count == personalBefore)
        #expect(try await inboxMessageIDs(f.workEndpoint).count == 5, "nothing on the server is touched")
    }

    @Test func theSecondAccountSendsFromItsOwnAddress() async throws {
        guard await SMTPIntegrationTests.available, let f = try await fixture() else { return }
        try f.store.setSetting(AccountSync.sentCopyKey, AccountSync.SentCopyPolicy.client.rawValue, accountID: "work")
        let message = OutgoingMessage(from: TestMailFactory.work, to: [MailAddress(name: nil, address: "lene@work.test")],
                                      subject: "From the work account", text: "Sent from the second account.")
        try await f.work.queue(message, sendAt: Date())
        try await f.work.processOutbox()
        let caught = try #require(try await SMTPIntegrationTests.caught(messageID: message.messageID))
        let raw = String(decoding: try await SMTPIntegrationTests.raw(id: caught.ID), as: UTF8.self)
        #expect(raw.contains("From: Magnus Kaspersen <magnus@work.test>") || raw.contains("<magnus@work.test>"))
        #expect(try f.store.outbox(accountID: "work").isEmpty)
        // The Sent copy went to the work account's Sent, not the personal one's.
        let workSent = try await MailSession.open(endpoint: f.workEndpoint, password: "tidings-test") { session in
            _ = try await session.select("Sent", readOnly: true)
            return Array(try await session.fetchHeaderField("Message-ID").values)
        }
        #expect(workSent.contains { $0.contains(message.messageID) })
        let personalSent = try await MailSession.open(endpoint: f.personalEndpoint, password: "tidings-test") { session in
            _ = try await session.select("Sent", readOnly: true)
            return Array(try await session.fetchHeaderField("Message-ID").values)
        }
        #expect(!personalSent.contains { $0.contains(message.messageID) })
    }
}
