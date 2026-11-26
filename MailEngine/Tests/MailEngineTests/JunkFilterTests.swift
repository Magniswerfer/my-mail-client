import Foundation
import Testing
@testable import MailEngine

/// The local junk filter (SPEC §8): tokens, scoring, learning and unlearning, and the whole
/// round trip against Dovecot.
@Suite(.serialized) struct JunkFilterTests {
    // MARK: Unit

    @Test func tokensKeepTheirPlace() {
        let tokens = JunkFilter.tokens(subject: "Gratis præmie!", fromName: "Lucky Winner", fromAddress: "Win@Promo.Example.com",
                                       body: "Klik her https://www.claim-prize.biz/now for 100 kr. 2026 ab", risk: .danger)
        #expect(tokens.contains("s:gratis"))
        #expect(tokens.contains("s:præmie"))
        #expect(tokens.contains("klik"))
        #expect(tokens.contains("her"))
        #expect(!tokens.contains("2026"), "numbers alone say nothing")
        #expect(!tokens.contains("ab"), "too short")
        #expect(tokens.contains("from:win@promo.example.com"))
        #expect(tokens.contains("fromdom:promo.example.com"))
        #expect(tokens.contains("fromreg:example.com"))
        #expect(tokens.contains("name:lucky"))
        #expect(tokens.contains("url:claim-prize.biz"))
        #expect(tokens.contains("risk:danger"))
    }

    @Test func scoringSeparatesWhatItHasSeen() {
        let totals = JunkFilter.Counts(spam: 100, ham: 100)
        let counts: [String: JunkFilter.Counts] = [
            "casino": .init(spam: 60, ham: 1), "bonus": .init(spam: 50, ham: 3), "s:vind": .init(spam: 40, ham: 0),
            "møde": .init(spam: 0, ham: 50), "projekt": .init(spam: 2, ham: 70), "from:kollega@firma.dk": .init(spam: 0, ham: 30),
        ]
        let spam = JunkFilter.score(["casino", "bonus", "s:vind", "unknown"], counts: counts, totals: totals)
        let ham = JunkFilter.score(["møde", "projekt", "from:kollega@firma.dk"], counts: counts, totals: totals)
        let unsure = JunkFilter.score(["nothing", "known"], counts: counts, totals: totals)
        #expect(spam > JunkFilter.junkThreshold)
        #expect(ham < 0.05)
        #expect(unsure == 0.5)
        // Mixed evidence lands in the middle, not at an extreme.
        let mixed = JunkFilter.score(["casino", "møde"], counts: counts, totals: totals)
        #expect(mixed > 0.2 && mixed < 0.8)
    }

    @Test func relearningTakesTheOldTokensBack() throws {
        let store = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID()).sqlite").path)
        let message = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: "<x@y>", subject: "Casino bonus",
                                    fromAddress: "spam@casino.biz", date: Date(), preview: "casino bonus now")
        try store.learnJunk(message, as: .spam)
        try store.learnJunk(message, as: .spam)   // the same label again: no double count
        #expect(try store.junkTotals() == .init(spam: 1, ham: 0))
        #expect(try store.junkCounts(["s:casino"])["s:casino"] == .init(spam: 1, ham: 0))
        try store.learnJunk(message, as: .ham)
        #expect(try store.junkTotals() == .init(spam: 0, ham: 1))
        #expect(try store.junkCounts(["s:casino"])["s:casino"] == .init(spam: 0, ham: 1))
        try store.forgetJunk(message)
        #expect(try store.junkTotals() == .init(spam: 0, ham: 0))
        #expect(try store.junkCounts(["s:casino"]).isEmpty, "unused tokens are dropped")
        #expect(try store.junkScore(message) == nil, "nothing scored before it has learned enough")
    }

    // MARK: Against Dovecot

    struct Fixture {
        let sync: AccountSync
        let store: MailStore
        let endpoint: IMAPEndpoint
        static let me = "me@tidings.test"

        func count(_ mailbox: String) async throws -> Int {
            try await MailSession.open(endpoint: endpoint, password: "tidings-test") { session in
                try await session.select(mailbox, readOnly: true).exists
            }
        }
    }

    static func mail(_ n: Int, from: String, subject: String, body: String) -> Data {
        Data("""
            From: \(from)\r
            To: \(Fixture.me)\r
            Subject: \(subject)\r
            Message-ID: <junk-\(n)-\(UUID().uuidString)@test>\r
            Date: Thu, 26 Nov 2026 10:\(String(format: "%02d", n % 60)):00 +0100\r
            \r
            \(body)\r

            """.utf8)
    }

    static let spamWords = ["casino", "bonus", "gratis", "spins", "vinder", "jackpot", "lån", "kredit", "billig", "tilbud"]
    static let hamWords = ["møde", "projekt", "faktura", "kunde", "frokost", "design", "budget", "planlægning", "kode", "release"]

    static func spam(_ n: Int) -> Data {
        let words = (0..<6).map { spamWords[($0 + n) % spamWords.count] }.joined(separator: " ")
        return mail(n, from: "Lucky \(n) <win\(n)@promo-\(n % 5).biz>", subject: "Du har vundet \(spamWords[n % 10])",
                    body: "\(words). Klik https://claim-\(n % 3).biz/x nu og få din \(words)")
    }

    static func ham(_ n: Int) -> Data {
        let words = (0..<6).map { hamWords[($0 + n) % hamWords.count] }.joined(separator: " ")
        return mail(n, from: "Kollega \(n % 7) <kollega\(n % 7)@firma.dk>", subject: "Om \(hamWords[n % 10])",
                    body: "Hej, \(words). Vi ses på mandag. https://firma.dk/wiki")
    }

    func fixture() async throws -> Fixture? {
        guard (try? await MailSession.probeGreeting(endpoint: IMAPIntegrationTests.endpoint)) != nil else { return nil }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "junk-\(UUID().uuidString.prefix(8))")
        try await MailSession.open(endpoint: endpoint, password: "tidings-test") { session in
            try await session.ensureMailbox("Junk")
            try await session.ensureMailbox("Archive")
            for n in 0..<25 { _ = try await session.append(to: "Junk", message: Self.spam(n)) }
            for n in 100..<160 { _ = try await session.append(to: "Archive", message: Self.ham(n), flags: ["\\Seen"]) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-junk-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "j", displayName: "J", endpoint: endpoint, addresses: [Fixture.me])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")))
        try await sync.syncOnce()
        return Fixture(sync: sync, store: store, endpoint: endpoint)
    }

    @Test func learnsFromJunkAndMovesNewJunk() async throws {
        guard let f = try await fixture() else { return }
        // Junk is synced now, and the first pass learns from it and from the Archive.
        #expect(try f.store.mailboxStates(accountID: "j").contains { $0.role == .junk })
        let engine = RuleEngine()
        _ = try await f.sync.runRules(engine: engine)
        #expect(try f.store.junkTotals() == .init(spam: 25, ham: 60))

        // New mail: one junk, one from a colleague.
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test") { session in
            _ = try await session.append(to: "INBOX", message: Self.spam(500))
            _ = try await session.append(to: "INBOX", message: Self.ham(501))
        }
        try await f.sync.syncOnce()
        let report = try await f.sync.runRules(engine: engine)
        #expect(report.junk.moved == 1)
        #expect(report.arrived.count == 1, "junk doesn't count as arrived mail (no notification)")
        #expect(report.arrived.first?.subject.hasPrefix("Om") == true)
        try await f.sync.processPendingActions()
        #expect(try await f.count("INBOX") == 1)
        #expect(try await f.count("Junk") == 26)

        // Undo: the filter was wrong, so it learns that message as fine.
        let change = try #require(report.junk.change)
        #expect(change.byFilter)
        try await f.sync.undo(change)
        try await f.sync.processPendingActions()
        #expect(try await f.count("INBOX") == 2)
        let rescued = try #require(try f.store.threads(mailbox: "INBOX", ownAddresses: [Fixture.me]).first { $0.latest.subject.hasPrefix("Du har") })
        #expect(try f.store.junkLabel(of: rescued.latest) == .ham)
    }

    @Test func yourMovesTeachIt() async throws {
        guard let f = try await fixture() else { return }
        _ = try await f.sync.runRules(engine: RuleEngine())
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test") { session in
            _ = try await session.append(to: "INBOX", message: Self.mail(900, from: "Odd <odd@weird.example>", subject: "Something odd", body: "plain words here"))
        }
        try await f.sync.syncOnce()
        _ = try await f.sync.runRules(engine: RuleEngine())
        let thread = try #require(try f.store.threads(mailbox: "INBOX", ownAddresses: [Fixture.me]).first)

        // Move to Junk → learned as junk; Not Junk (back to the Inbox) → learned as fine.
        let toJunk = try #require(try await f.sync.perform(.junk, threadIDs: [thread.threadID]))
        #expect(try f.store.junkLabel(of: thread.latest) == .spam)
        #expect(try f.store.junkTotals().spam == 26)
        try await f.sync.processPendingActions()
        try await f.sync.perform(.moveToInbox, threadIDs: [thread.threadID], from: "Junk")
        #expect(try f.store.junkLabel(of: thread.latest) == .ham)
        #expect(try f.store.junkTotals().spam == 25)
        _ = toJunk

        // Undoing your own Move to Junk forgets it instead.
        try await f.sync.processPendingActions()
        let again = try #require(try await f.sync.perform(.junk, threadIDs: [thread.threadID]))
        #expect(try f.store.junkLabel(of: thread.latest) == .spam)
        try await f.sync.undo(again)
        #expect(try f.store.junkLabel(of: thread.latest) == nil)
    }

    @Test func neverMovesMailFromPeopleYouWriteTo() async throws {
        guard let f = try await fixture() else { return }
        _ = try await f.sync.runRules(engine: RuleEngine())
        // You've written to this junk-looking sender before.
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test") { session in
            _ = try await session.append(to: "Archive", message: Data("""
                From: \(Fixture.me)\r
                To: win7@promo-2.biz\r
                Subject: Re: hi\r
                Message-ID: <mine-\(UUID())@test>\r
                Date: Wed, 25 Nov 2026 10:00:00 +0100\r
                \r
                Thanks\r

                """.utf8), flags: ["\\Seen"])
            _ = try await session.append(to: "INBOX", message: Self.spam(7))
        }
        try await f.sync.syncOnce()
        let report = try await f.sync.runRules(engine: RuleEngine())
        #expect(report.junk.moved == 0)
        #expect(report.arrived.count == 1)
    }
}
