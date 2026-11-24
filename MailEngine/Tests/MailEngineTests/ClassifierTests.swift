import Foundation
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
