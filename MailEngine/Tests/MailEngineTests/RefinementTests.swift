import Foundation
import Testing
@testable import MailEngine

/// Keyword → dimension; deterministic stand-in for the real embedding model.
struct KeywordEmbedder: TextEmbedder {
    static let vocabulary = ["ordre", "kvittering", "faktura", "betaling", "nyhedsbrev", "artikel", "ugens", "læs",
                             "tilbud", "rabat", "udsalg", "møde", "middag", "hej", "spørgsmål", "kode"]
    var dimension: Int { Self.vocabulary.count }

    func embed(_ text: String) -> [Float]? {
        let lower = text.lowercased()
        let v = Self.vocabulary.map { lower.contains($0) ? Float(1) : 0 }
        return v.allSatisfy { $0 == 0 } ? nil : ContextualEmbedder.normalized(v)
    }
}

/// Answers from a script, and records what it was asked.
actor ScriptedJudge: CategoryJudge {
    var answers: [String: MailCategory]
    private(set) var asked: [String] = []
    init(_ answers: [String: MailCategory]) { self.answers = answers }

    nonisolated func judge(subject: String, sender: String, snippet: String) async -> (MailCategory, String)? {
        await record(subject)
        guard let category = await answers[subject] else { return nil }
        return (category, "scripted")
    }
    func record(_ s: String) { asked.append(s) }
}

@Suite struct RefinementTests {
    func store() throws -> MailStore {
        try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID()).sqlite").path)
    }

    var uid: UInt32 = 0

    func add(_ store: MailStore, _ subject: String, body: String, category: MailCategory, reason: ClassificationReason,
             from: String = "x@example.dk") throws -> Int64 {
        var m = StoredMessage(accountID: "a", mailbox: "INBOX", uid: UInt32.random(in: 1..<UInt32.max / 2), subject: subject,
                              fromAddress: from, date: Date(), category: category, preview: body)
        m.classificationReason = reason.encoded
        try store.upsert([(m, body)])
        return try #require(try store.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM message WHERE subject = ?", arguments: [subject]) })
    }

    /// 15 confident examples each of transactions and newsletters, plus some advertising.
    func seedLabels(_ s: MailStore) throws {
        for i in 0..<15 {
            _ = try add(s, "Kvittering \(i)", body: "ordre kvittering betaling", category: .transactions, reason: .transactional)
            _ = try add(s, "Ugens nyhedsbrev \(i)", body: "nyhedsbrev artikel læs ugens", category: .newsletters, reason: .mailingListUnsubscribe)
            _ = try add(s, "Udsalg \(i)", body: "tilbud rabat udsalg", category: .advertising, reason: .promotional)
        }
    }

    @Test func classifierLearnsSeparableData() {
        var model = SoftmaxClassifier(dimension: KeywordEmbedder().dimension)
        let e = KeywordEmbedder()
        let data: [(x: [Float], y: MailCategory, weight: Float)] =
            (0..<20).map { _ in (e.embed("ordre kvittering")!, .transactions, 1) } +
            (0..<20).map { _ in (e.embed("nyhedsbrev artikel")!, .newsletters, 1) } +
            (0..<20).map { _ in (e.embed("møde middag hej")!, .primary, 1) }
        model.train(data)
        #expect(model.predict(e.embed("kvittering for din ordre")!).0 == .transactions)
        #expect(model.predict(e.embed("ugens nyhedsbrev")!).0 == .newsletters)
        #expect(model.predict(e.embed("hej, middag?")!).0 == .primary)
        #expect(model.predict(e.embed("ordre kvittering")!).1 > 0.9)
    }

    @Test func weakBundleDecisionIsRefinedWithoutAJudge() async throws {
        let s = try store()
        try seedLabels(s)
        // Header signals only knew "automated sender" (→ updates); it reads like a receipt.
        let id = try add(s, "Din betaling", body: "kvittering for ordre betaling", category: .updates, reason: .automatedSender(local: "noreply"))
        let report = try await Refinement(store: s, embedder: KeywordEmbedder(), judge: nil).run()
        #expect(report.trainedOn == 45)
        let refined = try #require(try s.message(id: id))
        #expect(refined.category == .transactions)
        #expect(refined.classificationReason?.hasPrefix("learned|") == true)
    }

    @Test func leavingPrimaryNeedsTheJudgeToAgree() async throws {
        let s = try store()
        try seedLabels(s)
        let agreed = try add(s, "Ugens læs", body: "nyhedsbrev artikel ugens læs", category: .primary, reason: .person, from: "a@x.dk")
        let refused = try add(s, "Artikel til dig", body: "nyhedsbrev artikel læs", category: .primary, reason: .person, from: "b@x.dk")
        let judge = ScriptedJudge(["Ugens læs": .newsletters, "Artikel til dig": .primary])
        let report = try await Refinement(store: s, embedder: KeywordEmbedder(), judge: judge).run()
        #expect(report.judged == 2)
        #expect(try s.message(id: agreed)?.category == .newsletters)
        #expect(try s.message(id: agreed)?.classificationReason == "ai|scripted")
        #expect(try s.message(id: refused)?.category == .primary, "the judge said it's personal: it stays")
    }

    @Test func correctionsAndConfidentDecisionsAreNeverRevisited() async throws {
        let s = try store()
        try seedLabels(s)
        let corrected = try add(s, "Kvittering?", body: "ordre kvittering", category: .primary, reason: .youMovedThisSender(.primary))
        let judge = ScriptedJudge([:])
        try await Refinement(store: s, embedder: KeywordEmbedder(), judge: judge).run()
        #expect(try s.message(id: corrected)?.category == .primary)
        #expect(await judge.asked.isEmpty)
    }

    @Test func tooFewLabelsMeansNoChanges() async throws {
        let s = try store()
        let id = try add(s, "Ordre", body: "ordre kvittering", category: .updates, reason: .automatedSender(local: "noreply"))
        let report = try await Refinement(store: s, embedder: KeywordEmbedder(), judge: nil).run()
        #expect(report.trainedOn == 0)
        #expect(try s.message(id: id)?.category == .updates)
    }

    /// The real on-device model (skipped when its assets aren't installed).
    @Test func realEmbedderGroupsDanishAndEnglishByMeaning() throws {
        guard let embedder = ContextualEmbedder() else { return }
        func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
        let receiptDA = try #require(embedder.embed("Kvittering for dit køb hos Zalando. Ordre 48213, betalt 899 kr."))
        let receiptEN = try #require(embedder.embed("Your receipt from Zalando. Order 48213, paid 899 DKK."))
        let dinner = try #require(embedder.embed("Hej Magnus, skal vi spise middag på lørdag? Kh Anna"))
        #expect(cos(receiptDA, receiptEN) > cos(receiptDA, dinner))

        let clock = ContinuousClock()
        let start = clock.now
        for i in 0..<20 { _ = embedder.embed("Test besked nummer \(i) om en ordre og en faktura fra en butik") }
        let perMessage = (clock.now - start) / 20
        print("Embedding: \(perMessage) per message, dimension \(embedder.dimension)")
        #expect(perMessage < .milliseconds(200))
    }
}
