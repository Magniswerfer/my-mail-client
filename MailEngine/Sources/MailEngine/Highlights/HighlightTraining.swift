import Foundation
import GRDB

/// What you've taught the highlights (codes, amounts) per sender: never show one from them, or
/// read it after the label you picked ("Beløb i alt", "Din kode"). Synced like your rules.
public struct HighlightTraining: Codable, Sendable, Hashable {
    /// What a highlight shows that you can correct.
    public enum Field: String, Codable, Sendable, CaseIterable { case code, amount }

    public struct Rule: Codable, Sendable, Hashable, Identifiable {
        public var id: String { "\(sender)|\(field.rawValue)" }
        /// The sender's address, lowercased.
        public var sender: String
        public var field: Field
        /// Never show this field's highlight from this sender.
        public var suppressed: Bool
        /// The label before the value in this sender's mail.
        public var label: String?

        public init(sender: String, field: Field, suppressed: Bool = false, label: String? = nil) {
            self.sender = sender.lowercased(); self.field = field; self.suppressed = suppressed; self.label = label
        }
    }

    public var rules: [Rule] = []
    public init(rules: [Rule] = []) { self.rules = rules }

    public func rule(sender: String, field: Field) -> Rule? {
        rules.first { $0.sender == sender.lowercased() && $0.field == field }
    }

    public mutating func set(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
    }

    public mutating func remove(sender: String, field: Field) {
        rules.removeAll { $0.sender == sender.lowercased() && $0.field == field }
    }

    /// Whether a highlight of this kind from this sender is shown at all.
    public func shows(_ kind: Highlight.Kind, from sender: String) -> Bool {
        guard let field = kind.field else { return true }
        return rule(sender: sender, field: field)?.suppressed != true
    }

    /// The highlights found, corrected by what you taught for this sender.
    public func apply(to found: [Highlight], sender: String, senderName: String, text: String) -> [Highlight] {
        var result = found
        for field in Field.allCases {
            guard let rule = rule(sender: sender, field: field) else { continue }
            if rule.suppressed {
                result.removeAll { $0.kind.field == field }
                continue
            }
            guard let label = rule.label, let value = Self.value(after: label, field: field, in: text) else { continue }
            if let i = result.firstIndex(where: { $0.kind.field == field }) {
                result[i].value = value
            } else {
                result.append(Highlight(kind: field == .code ? .code : .receipt, title: senderName, value: value))
            }
        }
        return result
    }

    /// The first value of the field after the label (on its line, else the next).
    static func value(after label: String, field: Field, in text: String) -> String? {
        guard !label.isEmpty, let found = text.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let rest = text[found.upperBound...]
        let lines = rest.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).prefix(2)
        for line in lines {
            if let value = HighlightExtractor.candidates(field, in: Substring(line)).first?.value { return value }
        }
        return nil
    }
}

/// A value in a message you can pick as its code or amount, with the label in front of it.
public struct HighlightCandidate: Sendable, Hashable, Identifiable {
    public var id: String { value + "|" + label }
    public var value: String
    /// The words before it on its line ("Beløb i alt"), else the line above; empty if none.
    public var label: String
}

extension Highlight.Kind {
    /// What you can correct on a highlight of this kind.
    public var field: HighlightTraining.Field? {
        switch self {
        case .code: .code
        case .receipt, .bill: .amount
        default: nil
        }
    }
}

extension HighlightExtractor {
    /// Every value in the text that could be the code or the amount, in order, with its label.
    public static func candidates(_ field: HighlightTraining.Field, subject: String, text: String) -> [HighlightCandidate] {
        var seen = Set<String>()
        var result: [HighlightCandidate] = []
        var previous = ""
        for line in (subject + "\n" + text).split(separator: "\n").prefix(600) {
            for candidate in candidates(field, in: line, previousLine: previous) where seen.insert(candidate.value).inserted {
                result.append(candidate)
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { previous = trimmed }
            if result.count >= 40 { break }
        }
        return result
    }

    static func candidates(_ field: HighlightTraining.Field, in line: Substring, previousLine: String = "") -> [HighlightCandidate] {
        var ranges: [(String, Range<Substring.Index>)] = []
        switch field {
        case .amount:
            ranges = amounts(line).map { ($0.shown, $0.range) }
        case .code:
            // 4–10 letters and digits with at least one digit ("483920", "A1B2C3"), or "123 456".
            for m in line.matches(of: /\b(\d{3}[ -]\d{3})\b|\b([A-Z0-9]{4,10})\b/) {
                let raw = String(m.output.1 ?? m.output.2 ?? "")
                guard raw.contains(where: \.isNumber) else { continue }
                ranges.append((raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: ""), m.range))
            }
        }
        return ranges.map { value, range in
            HighlightCandidate(value: value, label: label(before: line[..<range.lowerBound], previousLine: previousLine))
        }
    }

    /// The last few words before a value, without trailing ":" or "-"; the line above if none.
    static func label(before text: Substring, previousLine: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–=|")))
        let words = trimmed.split(separator: " ").suffix(4).joined(separator: " ")
        if !words.isEmpty, words.contains(where: \.isLetter) { return String(words.prefix(40)) }
        let above = previousLine.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–=|")))
        return above.contains(where: \.isLetter) ? String(above.split(separator: " ").suffix(4).joined(separator: " ").prefix(40)) : ""
    }
}

// MARK: - Storage

extension MailStore {
    static func registerHighlightTrainingMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v26-highlight-training") { db in
            // One row ("training"), synced as one record.
            try db.create(table: "highlightTraining") { t in
                t.column("key", .text).primaryKey()
                t.column("json", .blob).notNull()
            }
        }
    }

    public func highlightTraining() throws -> HighlightTraining {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM highlightTraining WHERE key = 'training'")
                .flatMap { try? CloudJSON.value(HighlightTraining.self, $0) } ?? HighlightTraining()
        }
    }

    public func saveHighlightTraining(_ training: HighlightTraining) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO highlightTraining (key, json) VALUES ('training', ?)",
                           arguments: [try CloudJSON.data(training)])
        }
    }

    /// Replaces a message's highlights (what you corrected or hid on it).
    public func setHighlights(_ highlights: [Highlight]?, messageID id: Int64) throws {
        try db.write { db in
            guard var message = try StoredMessage.fetchOne(db, key: id) else { return }
            message.highlights = (highlights?.isEmpty ?? true) ? nil : highlights
            try message.update(db)
        }
    }
}
