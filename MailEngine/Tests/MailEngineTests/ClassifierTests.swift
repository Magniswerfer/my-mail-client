import Foundation
import GRDB
import Testing
@testable import MailEngine

@Suite struct SenderCorrectionTests {
    func store() throws -> MailStore {
        try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("tidings-cls-\(UUID()).sqlite").path)
    }

    func message(_ uid: UInt32, from: String, subject: String, category: MailCategory) -> StoredMessage {
        StoredMessage(accountID: "a", mailbox: "INBOX", uid: uid, subject: subject, fromName: "Bogholderiet",
                      fromAddress: from, date: Date().addingTimeInterval(-Double(uid) * 3600), category: category)
    }

    @Test func correctionRecategorizesSenderAndKeepsSearchWorking() throws {
        let s = try store()
        try s.upsert([
            (message(1, from: "bogholderi@firma.dk", subject: "Faktura 1", category: .primary), "faktura nummer 1"),
            (message(2, from: "Bogholderi@Firma.dk", subject: "Faktura 2", category: .primary), "faktura nummer 2"),
            (message(3, from: "anna@example.dk", subject: "Middag", category: .primary), "faktura? nej, middag"),
        ])
        let changed = try s.remember(category: .transactions, forSender: "BOGHOLDERI@firma.dk")
        #expect(changed.count == 2, "case-insensitive sender match")

        let engine = SearchEngine(store: s)
        #expect(try engine.facets(SearchQuery(parsing: "faktura category:transactions")).total == 2, "FTS re-keyed with the new category")
        #expect(try engine.facets(SearchQuery(parsing: "faktura")).total == 3, "no index entries lost or duplicated")
        let reasons = try s.db.read { try String.fetchAll($0, sql: "SELECT classificationReason FROM message WHERE category = 'transactions'") }
        #expect(reasons.allSatisfy { $0 == "senderRule|transactions" })
    }

    @Test func futureMailFromCorrectedSenderFollowsTheRule() throws {
        let s = try store()
        try s.remember(category: .updates, forSender: "news@pol.dk")
        let parsed = MIMEParser.parse(Data("From: Politiken <news@pol.dk>\r\nList-Unsubscribe: <x>\r\nSubject: Morgenbrief\r\n\r\nhej".utf8))
        let (category, reason) = MessageClassifier(store: s).classify(parsed, userAddresses: [])
        #expect(category == .updates)
        #expect(reason == .youMovedThisSender(.updates))
    }

    @Test func reasonsRoundTrip() {
        let all: [ClassificationReason] = [.sentByYou, .youMovedThisSender(.social), .socialNetwork(domain: "linkedin.com"),
                                           .transactional, .promotional, .mailingListUnsubscribe, .mailingList,
                                           .automatedSender(local: "noreply"), .person, .learned(confidence: 87),
                                           .onDevice(summary: "Order shipped | tracking")]
        for reason in all { #expect(ClassificationReason(encoded: reason.encoded) == reason) }
    }
}

@Suite struct ConversationMoveTests {
    func store() throws -> MailStore {
        try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID()).sqlite").path)
    }

    func add(_ s: MailStore, uid: UInt32, thread: String, from: String, category: MailCategory) throws {
        var m = StoredMessage(accountID: "a", mailbox: "INBOX", uid: uid, threadID: thread, subject: "S\(uid)",
                              fromAddress: from, date: Date(), category: category)
        m.classificationReason = ClassificationReason.promotional.encoded
        try s.upsert([(m, "tekst \(uid)")])
    }

    @Test func movingOneConversationLeavesTheSendersOtherMailAlone() throws {
        let s = try store()
        try add(s, uid: 1, thread: "t1", from: "bank@danskebank.dk", category: .advertising)
        try add(s, uid: 2, thread: "t2", from: "bank@danskebank.dk", category: .advertising)
        let result = try s.moveConversations(["t1"], to: .transactions)
        #expect(result.promotedSender == nil)
        let categories = try s.db.read { try String.fetchAll($0, sql: "SELECT category FROM message ORDER BY uid") }
        #expect(categories == ["transactions", "advertising"])
        #expect(try s.senderRule(for: "bank@danskebank.dk") == nil)
    }

    @Test func secondConsistentMoveBecomesASenderRule() throws {
        let s = try store()
        for i in 1...3 { try add(s, uid: UInt32(i), thread: "t\(i)", from: "Bank@DanskeBank.dk", category: .advertising) }
        _ = try s.moveConversations(["t1"], to: .transactions)
        let second = try s.moveConversations(["t2"], to: .transactions)
        #expect(second.promotedSender == "bank@danskebank.dk")
        #expect(try s.senderRule(for: "bank@danskebank.dk")?.category == .transactions)
        let third = try s.db.read { try String.fetchOne($0, sql: "SELECT category FROM message WHERE uid = 3") }
        #expect(third == "transactions", "the rule applies to the rest of the sender's mail")
    }

    @Test func undoRestoresExactly() throws {
        let s = try store()
        try add(s, uid: 1, thread: "t1", from: "x@y.dk", category: .advertising)
        let result = try s.moveConversations(["t1"], to: .primary)
        try s.restoreCategories(result.previous)
        let row = try s.db.read { try Row.fetchOne($0, sql: "SELECT category, classificationReason FROM message") }
        #expect(row?["category"] == "advertising")
        #expect(row?["classificationReason"] == "promotional")
    }

    @Test func previewsLeaveOutQuotedText() {
        let text = "Gerne! Kl. 18?\n\nOn 22 Nov 2026, Anna wrote:\n> Skal vi lave middag?\n> Kh Anna"
        #expect(MailStore.makePreview(text) == "Gerne! Kl. 18?")
        let danish = "Perfekt.\nDen 22. nov. 2026 kl. 13.17 skrev Anna Jensen <anna@example.dk>:\n> tidligere"
        #expect(MailStore.makePreview(danish) == "Perfekt.")
        #expect(MailStore.makePreview("> only a quote") == "> only a quote", "never empty")
    }
}
