import Foundation

/// A parsed search query with Gmail-compatible operators (SPEC §7).
///
/// Supported: `from:` `to:` `subject:` `category:` `in:` `has:attachment` `is:unread` `is:read`
/// `is:pinned` `is:waiting` (you wrote last), `before:`/`after:` with `YYYY-MM-DD`, `today`,
/// `thisweek`, `thismonth`, `thisyear` or a relative `30d`/`6w`/`3m`/`1y`, `larger:5M` `smaller:100K`,
/// quoted phrases, `-term` exclusion, and `account:` (an account's name, address or domain; the app
/// resolves it to account ids with `resolvingAccounts`).
public struct SearchQuery: Sendable, Hashable {
    public var terms: [String] = []
    public var phrases: [String] = []
    public var excluded: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var subject: [String] = []
    public var categories: [MailCategory] = []
    public var mailbox: String?
    /// `account:`: as typed until `resolvingAccounts`, then account ids.
    public var accounts: [String] = []
    public var hasAttachment: Bool?
    public var unread: Bool?
    public var pinned: Bool?
    /// Conversations where the newest message is one you sent ("waiting for reply").
    public var waiting: Bool?
    /// `is:readlater`: conversations set aside with Read Later.
    public var readLater: Bool?
    public var before: Date?
    public var after: Date?
    public var largerThan: Int?
    public var smallerThan: Int?

    public var isEmpty: Bool { self == SearchQuery() }

    /// Facets are skipped for a lone one-character prefix: it matches nearly everything, and the
    /// hits alone are the useful answer while the user is still typing.
    public var wantsFacets: Bool {
        var bare = self
        bare.terms = []
        let onlyShortTerm = terms.count == 1 && terms[0].count < 2 && bare == SearchQuery()
        return !onlyShortTerm
    }

    public init() {}

    public init(parsing input: String) {
        for token in Self.tokenize(input) {
            apply(token)
        }
    }

    private mutating func apply(_ token: Token) {
        switch token {
        case .phrase(let p):
            phrases.append(p)
        case .word(let w):
            if w.hasPrefix("-"), w.count > 1 {
                excluded.append(String(w.dropFirst()))
                return
            }
            guard let colon = w.firstIndex(of: ":"), colon != w.startIndex else { terms.append(w); return }
            let key = w[..<colon].lowercased()
            let value = String(w[w.index(after: colon)...])
            // An operator it doesn't understand (or can't read the value of) is searched as text.
            if value.isEmpty || !(applyTextOperator(key, value) || applyOperator(key, value)) { terms.append(w) }
        case .quotedOperator(let key, let value):
            if !applyTextOperator(key.lowercased(), value) { phrases.append(value) }
        }
    }

    /// Operators whose value is free text, quoted or not. False for any other key.
    private mutating func applyTextOperator(_ key: String, _ value: String) -> Bool {
        switch key {
        case "from": from.append(value)
        case "to": to.append(value)
        case "subject": subject.append(value)
        case "in": mailbox = value
        case "account": accounts.append(value)
        default: return false
        }
        return true
    }

    /// Operators with a fixed vocabulary, a date or a size. False when the key or value isn't one.
    private mutating func applyOperator(_ key: String, _ value: String) -> Bool {
        let lower = value.lowercased()
        switch (key, lower) {
        case ("category", _):
            guard let c = MailCategory(rawValue: lower) ?? Self.categoryAliases[lower] else { return false }
            categories.append(c)
        case ("has", "attachment"): hasAttachment = true
        case ("is", "unread"): unread = true
        case ("is", "read"): unread = false
        case ("is", "pinned"): pinned = true
        case ("is", "waiting"): waiting = true
        case ("is", "readlater"): readLater = true
        case ("before", _):
            guard let d = Self.date(value) else { return false }
            before = d
        case ("after", _):
            guard let d = Self.date(value) else { return false }
            after = d
        case ("larger", _):
            guard let n = Self.size(value) else { return false }
            largerThan = n
        case ("smaller", _):
            guard let n = Self.size(value) else { return false }
            smallerThan = n
        default: return false
        }
        return true
    }

    /// `account:` values turned into account ids: an id, the account's name, any of its
    /// addresses, or a domain ("icloud.com", "work"), case-insensitive. A value that names no
    /// account matches nothing (rather than everything).
    public func resolvingAccounts(_ all: [AccountConfig]) -> SearchQuery {
        guard !accounts.isEmpty else { return self }
        var copy = self
        copy.accounts = accounts.flatMap { value -> [String] in
            let found = all.filter { $0.matches(searchValue: value) }.map(\.id)
            return found.isEmpty ? ["\u{0}none:\(value)"] : found
        }
        return copy
    }

    static let categoryAliases: [String: MailCategory] = [
        "promotions": .advertising, "ads": .advertising, "receipts": .transactions,
        "transaktioner": .transactions, "opdateringer": .updates, "nyhedsbreve": .newsletters,
        "reklamer": .advertising, "socialt": .social, "primær": .primary,
    ]

    // MARK: FTS

    /// The FTS5 MATCH expression for the free-text part, or nil when there is none.
    /// Every bare term is a prefix match, which gives as-you-type results and a cheap
    /// stand-in for Danish/English stemming ("faktura" finds "fakturaer").
    public var ftsExpression: String? {
        var parts: [String] = []
        for term in terms {
            let cleaned = Self.ftsSafe(term)
            guard !cleaned.isEmpty else { continue }
            parts.append("\"\(cleaned)\"*")
        }
        for phrase in phrases {
            let cleaned = Self.ftsSafe(phrase)
            if !cleaned.isEmpty { parts.append("\"\(cleaned)\"") }
        }
        // Column filters use the index too: "from:anna" → sender : "anna"*.
        for (column, values) in [("subject", subject), ("sender", from), ("recipients", to)] {
            for value in values {
                let cleaned = Self.ftsSafe(value)
                if !cleaned.isEmpty { parts.append("\(column) : \"\(cleaned)\"*") }
            }
        }
        guard !parts.isEmpty else { return nil }
        var expression = parts.joined(separator: " AND ")
        for ex in excluded {
            let cleaned = Self.ftsSafe(ex)
            if !cleaned.isEmpty { expression += " NOT \"\(cleaned)\"*" }
        }
        return expression
    }

    static func ftsSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tokenizing

    enum Token: Equatable { case word(String), phrase(String), quotedOperator(String, String) }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var i = input.startIndex
        while i < input.endIndex {
            if input[i].isWhitespace { i = input.index(after: i); continue }
            if input[i] == "\"" {
                let start = input.index(after: i)
                let end = input[start...].firstIndex(of: "\"") ?? input.endIndex
                let phrase = String(input[start..<end])
                if !phrase.isEmpty { tokens.append(.phrase(phrase)) }
                i = end < input.endIndex ? input.index(after: end) : end
                continue
            }
            var j = i
            while j < input.endIndex, !input[j].isWhitespace {
                // key:"quoted value"
                if input[j] == ":", input.index(after: j) < input.endIndex, input[input.index(after: j)] == "\"" {
                    let key = String(input[i..<j])
                    let start = input.index(j, offsetBy: 2)
                    let end = input[start...].firstIndex(of: "\"") ?? input.endIndex
                    tokens.append(.quotedOperator(key, String(input[start..<end])))
                    j = end < input.endIndex ? input.index(after: end) : end
                    i = j
                    break
                }
                j = input.index(after: j)
            }
            if i < j { tokens.append(.word(String(input[i..<j]))) }
            i = j
        }
        return tokens
    }

    static let absoluteDateFormats = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM", "yyyy"]

    static func date(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lower = s.lowercased()
        switch lower {
        case "today", "idag": return calendar.startOfDay(for: now)
        case "thisweek": return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case "thismonth": return calendar.dateInterval(of: .month, for: now)?.start
        case "thisyear", "iår": return calendar.dateInterval(of: .year, for: now)?.start
        default: break
        }
        // Relative: 30d, 6w, 3m, 1y ago.
        if let unit = lower.last, let n = Int(lower.dropLast()), n >= 0 {
            let component: Calendar.Component? = switch unit {
            case "d": .day
            case "w": .weekOfYear
            case "m": .month
            case "y": .year
            default: nil
            }
            if let component { return calendar.date(byAdding: component, value: -n, to: calendar.startOfDay(for: now)) }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in absoluteDateFormats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static let sizeMultipliers: [(suffix: String, bytes: Int)] = [("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)]

    static func size(_ s: String) -> Int? {
        let upper = s.uppercased()
        for (suffix, m) in sizeMultipliers where upper.hasSuffix(suffix) {
            return Double(upper.dropLast()).map { Int($0 * Double(m)) }
        }
        return Int(upper)
    }
}
