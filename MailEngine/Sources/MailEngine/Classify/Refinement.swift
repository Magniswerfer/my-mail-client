import Accelerate
import Foundation
import GRDB
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Interfaces (real implementations below; tests use fakes)

/// Text → fixed-size vector.
public protocol TextEmbedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]?
}

/// A slower, smarter second opinion for uncertain messages (layer 3).
public protocol CategoryJudge: Sendable {
    func judge(subject: String, sender: String, snippet: String) async -> (MailCategory, String)?
}

// MARK: - Layer 2: softmax regression over embeddings

/// Multinomial logistic regression, trained on-device with SGD (vDSP).
public struct SoftmaxClassifier: Sendable, Codable {
    public static let classes = MailCategory.allCases
    public var dimension: Int
    /// classes × (dimension + 1), bias last.
    public var weights: [Float]
    public var trainedOn: Int

    public init(dimension: Int) {
        self.dimension = dimension
        self.weights = Array(repeating: 0, count: Self.classes.count * (dimension + 1))
        self.trainedOn = 0
    }

    public func probabilities(_ x: [Float]) -> [Float] {
        let k = Self.classes.count, d = dimension
        var logits = [Float](repeating: 0, count: k)
        weights.withUnsafeBufferPointer { w in
            for c in 0..<k {
                var dot: Float = 0
                vDSP_dotpr(w.baseAddress! + c * (d + 1), 1, x, 1, &dot, vDSP_Length(d))
                logits[c] = dot + w[c * (d + 1) + d]
            }
        }
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxLogit) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    public func predict(_ x: [Float]) -> (MailCategory, Float) {
        let p = probabilities(x)
        let best = p.indices.max { p[$0] < p[$1] }!
        return (Self.classes[best], p[best])
    }

    /// `examples`: (vector, category, weight). L2-regularized SGD; a few epochs suffice for 512-d.
    public mutating func train(_ examples: [(x: [Float], y: MailCategory, weight: Float)], epochs: Int = 25,
                               learningRate: Float = 0.5, l2: Float = 1e-4) {
        guard !examples.isEmpty else { return }
        let k = Self.classes.count, d = dimension
        var rng = SplitMix64(seed: 1)
        var order = Array(examples.indices)
        for epoch in 0..<epochs {
            for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            let lr = learningRate / (1 + Float(epoch) * 0.2)
            for index in order {
                let (x, y, weight) = examples[index]
                let p = probabilities(x)
                let target = Self.classes.firstIndex(of: y)!
                weights.withUnsafeMutableBufferPointer { w in
                    for c in 0..<k {
                        let gradient = (p[c] - (c == target ? 1 : 0)) * weight
                        let base = w.baseAddress! + c * (d + 1)
                        var shrink = 1 - lr * l2
                        vDSP_vsmul(base, 1, &shrink, base, 1, vDSP_Length(d))
                        var step = -lr * gradient
                        vDSP_vsma(x, 1, &step, base, 1, base, 1, vDSP_Length(d))
                        base[d] -= lr * gradient
                    }
                }
            }
        }
        trainedOn = examples.count
    }
}

// MARK: - Real embedder: NLContextualEmbedding (one Latin-script model covers Danish + English)

public final class ContextualEmbedder: TextEmbedder, @unchecked Sendable {
    private let model: NLContextualEmbedding
    private let lock = NSLock()
    public let dimension: Int

    /// nil when the on-device assets aren't installed.
    public init?() {
        guard let model = NLContextualEmbedding(script: .latin), model.hasAvailableAssets else { return nil }
        do { try model.load() } catch { return nil }
        self.model = model
        self.dimension = model.dimension
    }

    /// Mean-pooled, L2-normalized token vectors.
    public func embed(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let input = String(text.prefix(1200))
        guard !input.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(input)
        let language = recognizer.dominantLanguage ?? .english
        guard let result = try? model.embeddingResult(for: input, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return Self.normalized(sum.map { Float($0 / Double(count)) })
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var out = v
        var inv = 1 / norm
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }
}

// MARK: - Real judge: Foundation Models

public struct FoundationModelsJudge: CategoryJudge {
    public init?() {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        #else
        return nil
        #endif
    }

    public func judge(subject: String, sender: String, snippet: String) async -> (MailCategory, String)? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You sort emails into exactly one inbox category. Emails may be Danish or English.
            primary: written personally to the reader by a real person; expects attention or a reply.
            transactions: orders, receipts, invoices, shipping, bookings, payments.
            updates: account notices, security alerts, service notifications, reminders.
            newsletters: editorial content the reader subscribed to.
            advertising: promotions, sales, marketing offers.
            social: notifications from social networks and community platforms.
            When unsure between primary and anything else, choose primary.
            """)
        do {
            let response = try await session.respond(
                to: "From: \(sender)\nSubject: \(subject)\n\n\(snippet.prefix(600))", generating: CategoryVerdict.self)
            guard let category = MailCategory(rawValue: response.content.category) else { return nil }
            return (category, response.content.reason)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct CategoryVerdict {
    @Guide(description: "The inbox category", .anyOf(["primary", "transactions", "updates", "newsletters", "advertising", "social"]))
    var category: String
    @Guide(description: "Why, in at most 8 words, in the email's language")
    var reason: String
}
#endif

// MARK: - The refinement pass (layers 2 + 3)

/// Improves categories after sync, in the background (ADR 0004). Conservative by design: moving a
/// real person's mail out of Primary is worse than leaving a newsletter in it, so any move into or
/// out of Primary needs the judge to agree (or a near-certain classifier when no judge exists).
/// Your corrections and your own mail are never touched.
public actor Refinement {
    public struct Report: Sendable { public var embedded = 0, trainedOn = 0, changed = 0, judged = 0 }

    let store: MailStore
    let embedder: any TextEmbedder
    let judge: (any CategoryJudge)?
    var bundleThreshold: Float = 0.8
    var primaryThreshold: Float = 0.7      // ask the judge above this
    var noJudgeThreshold: Float = 0.95
    var maxJudgedPerPass = 25

    public init(store: MailStore, embedder: any TextEmbedder, judge: (any CategoryJudge)?) {
        self.store = store
        self.embedder = embedder
        self.judge = judge
    }

    /// The real stack, or nil when on-device embeddings aren't available on this Mac.
    public static func onDevice(store: MailStore) -> Refinement? {
        guard let embedder = ContextualEmbedder() else { return nil }
        return Refinement(store: store, embedder: embedder, judge: FoundationModelsJudge())
    }

    /// Embeds what's new, trains on current labels, and revisits weakly-classified Inbox mail.
    @discardableResult
    public func run(limit: Int = 2000) async throws -> Report {
        var report = Report()
        report.embedded = try embedMissing(limit: limit)
        guard let classifier = try trainModel() else { return report }
        report.trainedOn = classifier.trainedOn

        for candidate in try store.refinementCandidates(limit: limit) {
            try Task.checkCancellation()
            guard let vector = try store.embedding(for: candidate.id) else { continue }
            let (predicted, p) = classifier.predict(vector)
            guard predicted != candidate.category else { continue }
            let crossesPrimary = predicted == .primary || candidate.category == .primary
            if crossesPrimary {
                guard p >= primaryThreshold else { continue }
                if let judge {
                    guard report.judged < maxJudgedPerPass else { continue }
                    report.judged += 1
                    guard let (verdict, why) = await judge.judge(subject: candidate.subject, sender: candidate.sender, snippet: candidate.snippet),
                          verdict == predicted else { continue }
                    try store.setCategory(verdict, reason: .onDevice(summary: why), ids: [candidate.id])
                    report.changed += 1
                } else if p >= noJudgeThreshold {
                    try store.setCategory(predicted, reason: .learned(confidence: Int(p * 100)), ids: [candidate.id])
                    report.changed += 1
                }
            } else if p >= bundleThreshold {
                try store.setCategory(predicted, reason: .learned(confidence: Int(p * 100)), ids: [candidate.id])
                report.changed += 1
            }
        }
        return report
    }

    func embedMissing(limit: Int) throws -> Int {
        var done = 0
        for item in try store.messagesWithoutEmbedding(limit: limit) {
            guard let vector = embedder.embed(item.text), vector.count == embedder.dimension else { continue }
            try store.saveEmbedding(vector, for: item.id)
            done += 1
        }
        return done
    }

    /// Labels: your corrections (weight 3) and confident header decisions (weight 1).
    func trainModel() throws -> SoftmaxClassifier? {
        let labeled = try store.trainingExamples().filter { $0.vector.count == embedder.dimension }
        guard labeled.count >= 20, Set(labeled.map(\.category)).count >= 2 else { return nil }
        var model = SoftmaxClassifier(dimension: embedder.dimension)
        model.train(labeled.map { ($0.vector, $0.category, $0.weight) })
        return model
    }
}

// MARK: - Store support

extension MailStore {
    static func registerEmbeddingMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v8-embeddings") { db in
            try db.create(table: "embedding") { t in
                t.column("messageID", .integer).primaryKey().references("message", onDelete: .cascade)
                t.column("vector", .blob).notNull()   // Float16, L2-normalized
            }
        }
    }

    func saveEmbedding(_ vector: [Float], for id: Int64) throws {
        let half = vector.map { Float16($0) }
        let data = half.withUnsafeBufferPointer { Data(buffer: $0) }
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO embedding (messageID, vector) VALUES (?, ?)", arguments: [id, data]) }
    }

    func embedding(for id: Int64) throws -> [Float]? {
        guard let data = try db.read({ try Data.fetchOne($0, sql: "SELECT vector FROM embedding WHERE messageID = ?", arguments: [id]) }) else { return nil }
        return Self.floats(data)
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
    }

    struct EmbeddingInput { var id: Int64; var text: String }

    /// Newest first, so recent mail benefits first.
    func messagesWithoutEmbedding(limit: Int) throws -> [EmbeddingInput] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.subject, coalesce(m.fromName, '') AS name, m.fromAddress, m.preview FROM message m
                LEFT JOIN embedding e ON e.messageID = m.id WHERE e.messageID IS NULL
                ORDER BY m.date DESC LIMIT ?
                """, arguments: [limit]).map {
                EmbeddingInput(id: $0["id"], text: "\($0["name"] as String) \($0["fromAddress"] as String)\n\($0["subject"] as String)\n\($0["preview"] as String)")
            }
        }
    }

    struct TrainingExample { var vector: [Float]; var category: MailCategory; var weight: Float }

    func trainingExamples(limit: Int = 20_000) throws -> [TrainingExample] {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.vector, m.category, m.classificationReason FROM message m JOIN embedding e ON e.messageID = m.id
                ORDER BY m.date DESC LIMIT ?
                """, arguments: [limit])
        }
        return rows.compactMap { row in
            guard let category = MailCategory(rawValue: row["category"]),
                  let reason = (row["classificationReason"] as String?).flatMap(ClassificationReason.init(encoded:)) else { return nil }
            let weight: Float
            switch reason {
            case .youMovedThisSender: weight = 3
            case .sentByYou: return nil   // my own mail says nothing about inbox categories
            default:
                guard reason.confidence >= 0.85 else { return nil }
                weight = 1
            }
            return TrainingExample(vector: Self.floats(row["vector"]), category: category, weight: weight)
        }
    }

    struct RefinementCandidate { var id: Int64; var category: MailCategory; var subject: String; var sender: String; var snippet: String }

    /// Inbox messages decided by a weak layer: no correction, not mine, not refined yet.
    func refinementCandidates(limit: Int) throws -> [RefinementCandidate] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, category, subject, coalesce(fromName, fromAddress) AS sender, preview, classificationReason FROM message
                WHERE mailbox = 'INBOX' ORDER BY date DESC LIMIT ?
                """, arguments: [limit]).compactMap { row in
                guard let category = MailCategory(rawValue: row["category"]) else { return nil }
                switch (row["classificationReason"] as String?).flatMap(ClassificationReason.init(encoded:)) {
                case .person?, .automatedSender?, .mailingList?: break
                default: return nil
                }
                return RefinementCandidate(id: row["id"], category: category, subject: row["subject"],
                                           sender: row["sender"], snippet: row["preview"])
            }
        }
    }
}
