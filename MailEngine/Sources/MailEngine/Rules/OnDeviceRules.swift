import Foundation
import GRDB
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - "About …" conditions: embedding pre-filter, then Foundation Models

/// Decides natural-language conditions on device (SPEC §6). The embedding similarity between
/// the description and the message is a cheap pre-filter, calibrated per condition against your
/// own Inbox (`AboutCalibration`); Foundation Models gives the yes/no for what passes, with your
/// ✓/✗ examples in the prompt. Without the model, the calibrated similarity alone decides.
public final class OnDeviceRuleJudge: RuleJudge, @unchecked Sendable {
    let store: MailStore
    let embedder: (any TextEmbedder)?
    let verifier: (any AboutVerifier)?
    private let lock = NSLock()
    private var descriptionVectors: [String: [Float]] = [:]

    public init?(store: MailStore, embedder: (any TextEmbedder)?, verifier: (any AboutVerifier)? = FoundationModelsAboutVerifier()) {
        guard embedder != nil || verifier != nil else { return nil }
        self.store = store
        self.embedder = embedder
        self.verifier = verifier
    }

    public func isAbout(_ condition: AboutCondition, message: StoredMessage) async -> Bool? {
        let description = condition.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return false }
        if let similarity = similarity(description, message) {
            // Below the calibrated cut: not worth asking the model.
            if condition.threshold > 0, similarity < condition.threshold { return false }
            guard let verifier else { return condition.threshold > 0 }
            return await verifier.verify(condition, message: message)
        }
        return await verifier?.verify(condition, message: message)
    }

    /// Cosine similarity (vectors are L2-normalized), or nil without embeddings.
    public func similarity(_ description: String, _ message: StoredMessage) -> Float? {
        guard let embedder, let query = vector(for: description) else { return nil }
        let messageVector = message.id.flatMap { try? store.embedding(for: $0) }
            ?? embedder.embed(MailStore.embeddingText(message))
        guard let messageVector, messageVector.count == query.count else { return nil }
        return VectorMath.dot(query, messageVector)
    }

    private func vector(for description: String) -> [Float]? {
        lock.lock()
        if let cached = descriptionVectors[description] { lock.unlock(); return cached }
        lock.unlock()
        guard let vector = embedder?.embed(description) else { return nil }
        lock.lock(); descriptionVectors[description] = vector; lock.unlock()
        return vector
    }

    /// Sets the condition's pre-filter cut from how similar your Inbox mail is to the description:
    /// mean + 1.5 standard deviations (embedding scores are high for everything, so a fixed
    /// number wouldn't mean much). Unchanged without embeddings.
    public func calibrated(_ condition: AboutCondition, sample: Int = 1500) -> AboutCondition {
        guard let query = vector(for: condition.description) else { return condition }
        let vectors = (try? store.inboxEmbeddings(limit: sample)) ?? []
        guard vectors.count >= 30 else { return condition }
        var scores: [Float] = []
        scores.reserveCapacity(vectors.count)
        for v in vectors where v.count == query.count {
            scores.append(VectorMath.dot(query, v))
        }
        let (mean, std) = VectorMath.meanAndDeviation(scores)
        var result = condition
        result.threshold = mean + 1.5 * std
        return result
    }

    /// For previews: messages passing the cheap part of a rule, ranked by similarity, so the
    /// slow model is only asked about the likeliest ones.
    func ranked(_ messages: [StoredMessage], by description: String) -> [StoredMessage] {
        guard embedder != nil else { return messages }
        return messages
            .map { ($0, similarity(description, $0) ?? 0) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// The yes/no step for "about …" conditions.
public protocol AboutVerifier: Sendable {
    func verify(_ condition: AboutCondition, message: StoredMessage) async -> Bool?
}

public struct FoundationModelsAboutVerifier: AboutVerifier {
    public init?() {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        #else
        return nil
        #endif
    }

    public func verify(_ condition: AboutCondition, message: StoredMessage) async -> Bool? {
        #if canImport(FoundationModels)
        var instructions = """
            You decide whether an email matches a description the user wrote, such as "about shoes" \
            or "invoices from my accountant". Emails may be Danish or English. Answer only about this \
            email's content and sender, and say no when unsure.
            """
        if !condition.examples.isEmpty {
            instructions += "\n\nThe user marked these examples:\n"
            for example in condition.examples.prefix(8) {
                instructions += "- \(example.matches ? "matches" : "does not match"): \(example.text.prefix(200))\n"
            }
        }
        let session = LanguageModelSession(instructions: instructions)
        let text = (message.plainText ?? message.preview).prefix(700)
        do {
            let response = try await session.respond(to: """
                Description: \(condition.description)

                From: \(message.fromName ?? message.fromAddress)
                Subject: \(message.subject)

                \(text)
                """, generating: AboutVerdict.self)
            return response.content.matches
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
struct AboutVerdict {
    @Guide(description: "Whether the email matches the description")
    var matches: Bool
}
#endif

// MARK: - Drafting a rule from a sentence

/// "Create rules by typing a sentence → editable rule" (SPEC §6).
public protocol RuleDrafter: Sendable {
    /// `folders`: mailbox paths the rule may move mail to.
    func draft(_ sentence: String, folders: [String]) async -> Rule?
}

public struct FoundationModelsRuleDrafter: RuleDrafter {
    public init?() {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        #else
        return nil
        #endif
    }

    public func draft(_ sentence: String, folders: [String]) async -> Rule? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You turn a sentence about sorting email into a rule. The user may write Danish or English; \
            name the rule in the user's language.

            Conditions say which mail the rule is for:
            - sender, recipient, subject, text (subject or body): an operation (contains, doesNotContain, \
            equals, beginsWith, endsWith) and a value. For mail from a named person or company \
            ("fra Sofie Hansen", "from Zalando"), use sender contains that name. For mail from a domain \
            such as zalando.dk, use sender endsWith "@zalando.dk". Never invent addresses or domains \
            the user didn't write.
            - category: the mail's current category (only when the user says which mail, e.g. "newsletters about …").
            - hasAttachment.
            - about: a topic in the user's own words that isn't a plain text match, e.g. "crypto" or \
            "invoices from my accountant". Never use about for a sender the user names.
            matchAll is true unless the user says "or".

            Actions say what to do with it:
            - setCategory moves mail to a category: primary, transactions (Transaktioner), updates \
            (Opdateringer), newsletters (Nyhedsbreve), advertising (Reklamer), social (Socialt). \
            "Move to Reklamer/Advertising" is this action, not a condition.
            - pin, markRead, replyLater, done (archive), snooze (value = hours; 0 = someday), \
            moveToFolder (value = one of: \(folders.isEmpty ? "none" : folders.joined(separator: ", "))).
            """)
        do {
            let response = try await session.respond(to: sentence, generating: DraftedRule.self)
            return response.content.rule?.grounded(in: sentence)
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
struct DraftedRule {
    @Guide(description: "A short name for the rule")
    var name: String
    @Guide(description: "True if all conditions must match, false if any one is enough")
    var matchAll: Bool
    @Guide(description: "One to three conditions", .count(1...3))
    var conditions: [DraftedCondition]
    @Guide(description: "One to three actions", .count(1...3))
    var actions: [DraftedAction]

    @Generable
    struct DraftedCondition {
        @Guide(.anyOf(["sender", "recipient", "subject", "text", "category", "hasAttachment", "about"]))
        var kind: String
        @Guide(description: "For text kinds", .anyOf(["contains", "doesNotContain", "equals", "beginsWith", "endsWith"]))
        var operation: String
        @Guide(description: "The text to match, the category, or the topic for about")
        var value: String
    }

    @Generable
    struct DraftedAction {
        @Guide(.anyOf(["setCategory", "pin", "markRead", "replyLater", "done", "snooze", "moveToFolder"]))
        var kind: String
        @Guide(description: "The category for setCategory, the folder for moveToFolder, the hours for snooze; else empty")
        var value: String
    }

    var rule: Rule? {
        let conditions = conditions.compactMap { c -> RuleCondition? in
            let match = TextMatch(TextMatch.Operation(rawValue: c.operation) ?? .contains, c.value)
            switch c.kind {
            case "sender": return .sender(match)
            case "recipient": return .recipient(match)
            case "subject": return .subject(match)
            case "text": return .text(match)
            case "category": return MailCategory(rawValue: c.value.lowercased()).map(RuleCondition.category)
            case "hasAttachment": return .hasAttachment(true)
            case "about": return c.value.isEmpty ? nil : .about(AboutCondition(c.value))
            default: return nil
            }
        }
        let actions = actions.compactMap { a -> RuleAction? in
            switch a.kind {
            case "setCategory": return MailCategory(rawValue: a.value.lowercased()).map(RuleAction.setCategory)
            case "pin": return .pin
            case "markRead": return .markRead
            case "replyLater": return .replyLater
            case "done": return .done
            case "snooze": return .snooze(hours: Int(a.value).flatMap { $0 > 0 ? $0 : nil })
            case "moveToFolder": return a.value.isEmpty ? nil : .moveToFolder(a.value)
            default: return nil
            }
        }
        guard !conditions.isEmpty else { return nil }
        return Rule(name: name, matchAll: matchAll, conditions: conditions, actions: actions)
    }
}
#endif

// MARK: - Store support

extension MailStore {
    /// The text a message is embedded from (same as the refinement pass).
    static func embeddingText(_ m: StoredMessage) -> String {
        "\(m.fromName ?? "") \(m.fromAddress)\n\(m.subject)\n\(m.preview)"
    }

    func inboxEmbeddings(limit: Int) throws -> [[Float]] {
        try db.read { db in
            try Data.fetchAll(db, sql: """
                SELECT e.vector FROM embedding e JOIN message m ON m.id = e.messageID
                WHERE m.mailbox = 'INBOX' ORDER BY m.date DESC LIMIT ?
                """, arguments: [limit]).map(Self.floats)
        }
    }
}

// MARK: - Keeping a drafted rule to what the sentence says

extension Rule {
    /// Words that name each category in a sentence (Danish and English stems).
    static let categoryWords: [MailCategory: [String]] = [
        .primary: ["primary", "primær"],
        .transactions: ["transaction", "transaktion"],
        .updates: ["update", "opdatering"],
        .newsletters: ["newsletter", "nyhedsbrev"],
        .advertising: ["advertis", "reklame", "promotion"],
        .social: ["social"],
    ]

    /// A drafted rule with what the small on-device model made up removed: text values that
    /// aren't in the sentence (invented addresses and domains), attachment and category
    /// conditions the sentence doesn't mention. A category the sentence names but the draft
    /// neither tests nor sets becomes "move to that category".
    public func grounded(in sentence: String) -> Rule {
        let said = sentence.lowercased()
        func mentions(_ category: MailCategory) -> Bool { Self.categoryWords[category, default: []].contains { said.contains($0) } }
        func appears(_ value: String) -> Bool {
            let v = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ ."))
            guard !v.isEmpty else { return false }
            if said.contains(v) { return true }
            // "@zalando.dk" when the sentence says "Zalando".
            let stem = v.split(separator: "@").last.map { String($0.split(separator: ".").first ?? "") } ?? v
            return stem.count >= 3 && said.contains(stem)
        }
        var rule = self
        rule.conditions = conditions.map { condition in
            if case .about(let a) = condition, let sender = Self.namedSender(a.description, in: sentence) {
                return .sender(TextMatch(.contains, sender))
            }
            return condition
        }.filter { condition in
            switch condition {
            case .sender(let m), .recipient(let m), .subject(let m), .text(let m): return appears(m.value)
            case .hasAttachment: return ["attach", "vedhæft", "bilag"].contains { said.contains($0) }
            case .category(let c): return mentions(c)
            case .about(let a): return !a.description.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        rule.actions = actions.filter { action in
            if case .setCategory(let c) = action { return mentions(c) }
            return true
        }
        let tested = Set(rule.conditions.compactMap { if case .category(let c) = $0 { c } else { nil } })
        let set = rule.actions.contains { if case .setCategory = $0 { true } else { false } }
        if !set, let named = MailCategory.allCases.first(where: { mentions($0) && !tested.contains($0) }) {
            rule.actions.insert(.setCategory(named), at: 0)
        }
        return rule
    }

    /// The small model sometimes turns "mail fra Sofie Hansen" into "about: Sofie Hansen", which
    /// the judge then matches loosely. When the value comes right after "fra"/"from" and is a
    /// name (capitalised words, as written) or an address/domain, it's a sender, not a topic.
    /// "from my accountant" stays a topic.
    static func namedSender(_ value: String, in sentence: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        let said = sentence.lowercased()
        guard ["fra ", "from "].contains(where: { said.contains($0 + v.lowercased()) }),
              let range = sentence.range(of: v, options: .caseInsensitive) else { return nil }
        let written = sentence[range]
        let isAddress = written.contains("@") || (written.contains(".") && !written.contains(" "))
        let isName = written.split(separator: " ").allSatisfy { $0.first?.isUppercase == true }
        return isAddress || isName ? String(written) : nil
    }
}
