import Foundation
import Testing
@testable import MailEngine

@Suite struct SearchEngineTests {
    func makeStore() throws -> MailStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-test-\(UUID()).sqlite").path
        return try MailStore(path: path)
    }

    func message(_ uid: UInt32, _ subject: String, from: String, category: MailCategory = .primary,
                 daysAgo: Double = 1, attachments: Bool = false) -> StoredMessage {
        StoredMessage(accountID: "a", mailbox: "INBOX", uid: uid, subject: subject, fromName: from.capitalized,
                      fromAddress: "\(from)@example.dk", date: Date().addingTimeInterval(-daysAgo * 86_400),
                      hasAttachments: attachments, category: category)
    }

    @Test func prefixMatchingActsAsLightStemming() throws {
        let store = try makeStore()
        try store.upsert([
            (message(1, "Fakturaer for oktober", from: "bogholderi", category: .transactions), "Her er jeres fakturaer."),
            (message(2, "Middag", from: "anna"), "Skal vi spise kl 18?"),
        ])
        let r = try SearchEngine(store: store).hits(SearchQuery(parsing: "faktura"))
        #expect(r.hits.map(\.id) == [1])
    }

    @Test func diacriticsAndCaseAreFolded() throws {
        let store = try makeStore()
        try store.upsert([(message(1, "Møde i morgen", from: "peter"), "Kan du MØDES kl. 10?")])
        let engine = SearchEngine(store: store)
        #expect(try engine.facets(SearchQuery(parsing: "møde")).total == 1)
        #expect(try engine.facets(SearchQuery(parsing: "MØD")).total == 1)
    }

    @Test func facetsAndFilters() throws {
        let store = try makeStore()
        try store.upsert([
            (message(1, "Nye sko", from: "nike", category: .advertising), "sko tilbud"),
            (message(2, "Din ordre: sko", from: "zalando", category: .transactions, attachments: true), "sko ordre kvittering"),
            (message(3, "Sko til festen?", from: "anna"), "skal vi købe sko"),
        ])
        let engine = SearchEngine(store: store)
        let all = try engine.facets(SearchQuery(parsing: "sko"))
        #expect(all.total == 3)
        #expect(Set(all.categories.map(\.value)) == ["advertising", "transactions", "primary"])
        #expect(all.withAttachments == 1)
        #expect(all.senders.count == 3)

        #expect(try engine.hits(SearchQuery(parsing: "sko from:zalando")).hits.map(\.id) == [2])
        #expect(try engine.hits(SearchQuery(parsing: "sko category:advertising")).hits.map(\.id) == [1])
        #expect(try engine.hits(SearchQuery(parsing: "sko has:attachment")).hits.map(\.id) == [2])
        #expect(try engine.facets(SearchQuery(parsing: "sko -tilbud")).total == 2)
        #expect(try engine.facets(SearchQuery(parsing: "category:transactions")).total == 1)
    }

    @Test func snippetComesFromCompressedBody() throws {
        let store = try makeStore()
        let body = String(repeating: "fyld ", count: 50) + "betalingsfristen er den 15. december" + String(repeating: " fyld", count: 50)
        try store.upsert([(message(1, "Påmindelse", from: "firma"), body)])
        let hit = try #require(try SearchEngine(store: store).hits(SearchQuery(parsing: "betalingsfristen")).hits.first)
        #expect(hit.snippet.contains("betalingsfristen er den 15. december"))
        #expect(hit.snippet.hasPrefix("…"))
    }

    @Test func upsertReplacesIndexEntry() throws {
        let store = try makeStore()
        try store.upsert([(message(1, "Gammelt emne", from: "a"), "gammel tekst")])
        try store.upsert([(message(1, "Nyt emne", from: "a"), "ny tekst")])
        let engine = SearchEngine(store: store)
        #expect(try store.count() == 1)
        #expect(try engine.facets(SearchQuery(parsing: "gammel")).total == 0)
        #expect(try engine.facets(SearchQuery(parsing: "nyt")).total == 1)
    }

    @Test func resultsAreNewestFirstAndDateFiltersUseTheSortKey() throws {
        let store = try makeStore()
        try store.upsert([
            (message(1, "gammel kvittering", from: "a", daysAgo: 400), "kvittering"),
            (message(2, "ny kvittering", from: "a", daysAgo: 2), "kvittering"),
            (message(3, "mellem kvittering", from: "a", daysAgo: 30), "kvittering"),
        ])
        let engine = SearchEngine(store: store)
        #expect(try engine.hits(SearchQuery(parsing: "kvittering")).hits.map(\.id) == [2, 3, 1])
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-100 * 86_400)).prefix(10)
        #expect(try engine.hits(SearchQuery(parsing: "kvittering after:\(cutoff)")).hits.map(\.id) == [2, 3])
        #expect(try engine.hits(SearchQuery(parsing: "kvittering before:\(cutoff)")).hits.map(\.id) == [1])
    }

    @Test func plainTextIsStoredCompressed() throws {
        let store = try makeStore()
        let text = String(repeating: "Dette er en lang mail med gentagelser. ", count: 200)
        try store.upsert([(message(1, "Lang", from: "a"), text)])
        let stored = try store.db.read { try StoredMessage.fetchOne($0) }
        let blob = try #require(stored?.bodyText)
        #expect(blob.count < text.utf8.count / 5)
        #expect(stored?.plainText == text)
    }
}
