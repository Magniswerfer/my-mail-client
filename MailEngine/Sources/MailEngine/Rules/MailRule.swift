import Foundation
import GRDB

/// An Outlook-style rule (SPEC §6): ordered, conditions + actions, optional "stop processing".
/// Runs on new Inbox mail after spam checks and AI sorting, so it can read and override the
/// category. Runs on existing mail only when you ask.
public struct MailRule: Codable, Sendable, Hashable, Identifiable {
    public enum Match: String, Codable, Sendable, Hashable, CaseIterable { case all, any }

    public enum Condition: Codable, Sendable, Hashable {
        case from(String)            // address or name contains (case-insensitive)
        case to(String)              // any To/Cc recipient contains
        case subject(String)
        case body(String)            // the sender's own words, quotes excluded
        case category(MailCategory)
        case hasAttachment
        /// Natural language: "about shoes". Embedding pre-filter, then the on-device model decides.
        case about(String)

        public var isNaturalLanguage: Bool { if case .about = self { true } else { false } }
    }

    public enum Action: Codable, Sendable, Hashable {
        case moveToFolder(String)
        case setCategory(MailCategory)
        case markDone
        case pin
        case markRead
        case snooze(days: Int)
        case replyLater
        case notify
        /// Structured rules send it; rules with an "about" condition leave a draft (SPEC §6).
        case forward(to: String)
        case autoReply(text: String)
        case runShortcut(name: String)
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var match: Match
    public var conditions: [Condition]
    public var actions: [Action]
    public var stopProcessing: Bool
    /// The sentence it was made from, if any ("all mails about shoes go to Shopping").
    public var sentence: String?

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, match: Match = .all,
                conditions: [Condition], actions: [Action], stopProcessing: Bool = false, sentence: String? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.conditions = conditions
        self.actions = actions
        self.stopProcessing = stopProcessing
        self.sentence = sentence
    }

    /// True when any condition needs the model; such rules never send mail by themselves.
    public var usesNaturalLanguage: Bool { conditions.contains(where: \.isNaturalLanguage) }
}

/// What a rule looks at.
public struct RuleInput: Sendable {
    public var fromAddress: String
    public var fromName: String
    public var recipients: String
    public var subject: String
    public var ownText: String
    public var category: MailCategory
    public var hasAttachment: Bool

    public init(message: StoredMessage) {
        fromAddress = message.fromAddress
        fromName = message.fromName ?? ""
        recipients = message.recipients
        subject = message.subject
        ownText = MailStore.ownText(message.plainText ?? message.preview)
        category = message.category
        hasAttachment = message.hasAttachments
    }

    public init(fromAddress: String, fromName: String = "", recipients: String = "", subject: String = "",
                ownText: String = "", category: MailCategory = .primary, hasAttachment: Bool = false) {
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.recipients = recipients
        self.subject = subject
        self.ownText = ownText
        self.category = category
        self.hasAttachment = hasAttachment
    }
}

public enum RuleEvaluator {
    /// A structured condition's result; nil for natural-language ones.
    public static func check(_ condition: MailRule.Condition, _ input: RuleInput) -> Bool? {
        func has(_ haystack: String, _ needle: String) -> Bool {
            let n = needle.trimmingCharacters(in: .whitespaces)
            return !n.isEmpty && haystack.range(of: n, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        switch condition {
        case .from(let s): return has(input.fromAddress, s) || has(input.fromName, s)
        case .to(let s): return has(input.recipients, s)
        case .subject(let s): return has(input.subject, s)
        case .body(let s): return has(input.ownText, s)
        case .category(let c): return input.category == c
        case .hasAttachment: return input.hasAttachment
        case .about: return nil
        }
    }

    public enum Outcome: Sendable, Equatable { case match, noMatch, needsJudge([String]) }

    /// Structured conditions first (they short-circuit); topics left for the model only when
    /// they can still change the result.
    public static func evaluate(_ rule: MailRule, _ input: RuleInput) -> Outcome {
        guard rule.isEnabled, !rule.conditions.isEmpty else { return .noMatch }
        var topics: [String] = []
        for condition in rule.conditions {
            if case .about(let topic) = condition { topics.append(topic); continue }
            let ok = check(condition, input) ?? false
            if rule.match == .all, !ok { return .noMatch }
            if rule.match == .any, ok { return .match }
        }
        if topics.isEmpty { return rule.match == .all ? .match : .noMatch }
        return .needsJudge(topics)
    }

    /// Final answer once topics are judged (`verdicts[topic]`).
    public static func resolve(_ rule: MailRule, verdicts: [String: Bool]) -> Bool {
        let results = rule.conditions.compactMap { c -> Bool? in
            if case .about(let t) = c { return verdicts[t] ?? false }
            return nil
        }
        return rule.match == .all ? results.allSatisfy { $0 } : results.contains(true)
    }
}

/// Decides whether a message is about a topic (Foundation Models in the app).
public protocol TopicJudge: Sendable {
    func isAbout(_ topic: String, subject: String, sender: String, snippet: String) async -> Bool?
}

// MARK: - Storage

extension MailStore {
    static func registerRuleMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v13-rules") { db in
            try db.create(table: "mailRule") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .blob).notNull()
            }
            // Which messages rules have seen, by account + Message-ID (stable across moves).
            try db.create(table: "ruleLog") { t in
                t.column("key", .text).primaryKey()
                t.column("at", .datetime).notNull()
            }
            // Rules only run automatically on mail that arrives from now on.
            try db.execute(sql: """
                INSERT OR IGNORE INTO ruleLog (key, at)
                SELECT accountID || '|' || coalesce(messageID, mailbox || '/' || uid), datetime('now') FROM message
                """)
        }
    }

    static func ruleKey(_ m: StoredMessage) -> String {
        "\(m.accountID)|\(m.messageID ?? "\(m.mailbox)/\(m.uid)")"
    }

    public func rules() throws -> [MailRule] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM mailRule ORDER BY position").compactMap {
                try? JSONDecoder().decode(MailRule.self, from: $0)
            }
        }
    }

    /// Replaces the whole ordered list (the order is the evaluation order).
    public func saveRules(_ rules: [MailRule]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM mailRule")
            for (position, rule) in rules.enumerated() {
                try db.execute(sql: "INSERT INTO mailRule (id, position, json) VALUES (?, ?, ?)",
                               arguments: [rule.id.uuidString, position, try JSONEncoder().encode(rule)])
            }
        }
    }

    /// New Inbox mail rules haven't looked at yet (not your own), oldest first.
    public func messagesAwaitingRules(ownAddresses: Set<String>, limit: Int = 200) throws -> [StoredMessage] {
        let own = ownAddresses.isEmpty ? [""] : ownAddresses.map { $0.lowercased() }.sorted()
        return try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE mailbox = 'INBOX' AND lower(fromAddress) NOT IN (\(own.map { _ in "?" }.joined(separator: ",")))
                  AND (accountID || '|' || coalesce(messageID, mailbox || '/' || uid)) NOT IN (SELECT key FROM ruleLog)
                ORDER BY date LIMIT ?
                """, arguments: StatementArguments(own + [limit] as [any DatabaseValueConvertible]))
        }
    }

    public func markSeenByRules(_ messages: [StoredMessage]) throws {
        try db.write { db in
            for m in messages {
                try db.execute(sql: "INSERT OR IGNORE INTO ruleLog (key, at) VALUES (?, ?)", arguments: [Self.ruleKey(m), Date()])
            }
        }
    }

    /// Recent mail (Inbox and Archive) to preview or run a rule on, newest first.
    public func recentMailForRules(ownAddresses: Set<String>, limit: Int = 3_000) throws -> [StoredMessage] {
        let own = ownAddresses.isEmpty ? [""] : ownAddresses.map { $0.lowercased() }.sorted()
        return try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m
                WHERE lower(m.fromAddress) NOT IN (\(own.map { _ in "?" }.joined(separator: ",")))
                  AND m.mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('sent', 'drafts', 'trash', 'junk'))
                ORDER BY m.date DESC LIMIT ?
                """, arguments: StatementArguments(own + [limit] as [any DatabaseValueConvertible]))
        }
    }

    /// A message's stored embedding, if the refinement pass made one.
    public func embeddingVector(messageID id: Int64) throws -> [Float]? {
        try embedding(for: id)
    }
}

public enum VectorMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }
}
