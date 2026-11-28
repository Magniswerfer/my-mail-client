import Foundation
import GRDB

/// What a message was learned as.
public enum JunkLabel: String, Sendable, Codable {
    case spam, ham
}

/// The local junk filter (SPEC §8): a token naive-Bayes classifier in the SpamBayes style
/// (Robinson's per-token probabilities, chi-square combining), trained on what's in Junk and on
/// your corrections. Everything stays on this device; no external lookups.
public enum JunkFilter {
    /// At or above: moved to Junk. Between `warning` and this: a banner, the mail stays.
    public static let junkThreshold = 0.95
    public static let warningThreshold = 0.80
    /// Too little to go on below these: nothing is scored.
    public static let minSpam = 20
    public static let minHam = 50

    // Robinson's smoothing: strength of the 0.5 prior, and how far from 0.5 a token must be to count.
    static let priorStrength = 0.45
    static let minDeviation = 0.1
    static let maxClues = 150
    static let bodyLimit = 4000

    // MARK: Tokens

    /// The distinct tokens of a message: subject and body words, the sender's address, domain
    /// and name, link hosts, and Tidings' own phishing verdict. Prefixes keep them apart
    /// ("s:free" in the subject is not "free" in the body).
    public static func tokens(subject: String, fromName: String?, fromAddress: String, body: String,
                              risk: RiskLevel = .none) -> Set<String> {
        var out = Set<String>()
        for word in words(subject) { out.insert("s:" + word) }
        for word in words(String(body.prefix(bodyLimit))) { out.insert(word) }
        let address = fromAddress.lowercased()
        if !address.isEmpty {
            out.insert("from:" + address)
            if let domain = address.split(separator: "@").last.map(String.init) {
                out.insert("fromdom:" + domain)
                out.insert("fromreg:" + PhishingCheck.registrable(domain))
            }
        }
        for word in words(fromName ?? "") { out.insert("name:" + word) }
        for host in linkHosts(in: body) { out.insert("url:" + host) }
        switch risk {
        case .none: break
        case .caution: out.insert("risk:caution")
        case .danger: out.insert("risk:danger")
        }
        return out
    }

    /// Lowercased runs of letters and digits, 3–20 characters, not just digits (æ, ø, å included).
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            if (3...20).contains(current.count), !current.allSatisfy(\.isNumber) { result.append(current) }
            current = ""
        }
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) } else { flush() }
        }
        flush()
        return result
    }

    /// Hosts of http(s) links, without "www.".
    static func linkHosts(in text: String) -> Set<String> {
        var hosts = Set<String>()
        var rest = Substring(text.prefix(bodyLimit * 2))
        while let start = rest.range(of: "http", options: .caseInsensitive) {
            let tail = rest[start.lowerBound...]
            let end = tail.firstIndex(where: { $0.isWhitespace || "<>\"')]".contains($0) }) ?? tail.endIndex
            if let url = URL(string: String(tail[..<end])), let host = url.host?.lowercased() {
                hosts.insert(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
            rest = tail[end...]
            if rest.isEmpty { break }
            rest = rest.dropFirst()
        }
        return hosts
    }

    public static func tokens(of message: StoredMessage) -> Set<String> {
        tokens(subject: message.subject, fromName: message.fromName, fromAddress: message.fromAddress,
               body: message.plainText ?? message.preview, risk: message.riskLevel)
    }

    // MARK: Scoring

    public struct Counts: Sendable, Hashable {
        public var spam: Int
        public var ham: Int
        public init(spam: Int, ham: Int) { self.spam = spam; self.ham = ham }
    }

    /// The token's spam probability, smoothed toward 0.5 when it's rarely been seen.
    static func probability(_ c: Counts, totals: Counts) -> Double {
        let spamRatio = Double(c.spam) / Double(max(totals.spam, 1))
        let hamRatio = Double(c.ham) / Double(max(totals.ham, 1))
        guard spamRatio + hamRatio > 0 else { return 0.5 }
        let p = spamRatio / (spamRatio + hamRatio)
        let n = Double(c.spam + c.ham)
        return (priorStrength * 0.5 + n * p) / (priorStrength + n)
    }

    /// 0 (certainly fine) … 1 (certainly junk), from the most telling tokens.
    public static func score(_ tokens: Set<String>, counts: [String: Counts], totals: Counts) -> Double {
        var clues: [Double] = []
        for token in tokens {
            guard let c = counts[token] else { continue }
            let p = probability(c, totals: totals)
            if abs(p - 0.5) >= minDeviation { clues.append(p) }
        }
        guard !clues.isEmpty else { return 0.5 }
        clues.sort { abs($0 - 0.5) > abs($1 - 0.5) }
        let used = clues.prefix(maxClues).map { min(max($0, 0.01), 0.99) }
        let n = used.count
        let spamEvidence = used.reduce(0) { $0 + log(1 - $1) }
        let hamEvidence = used.reduce(0) { $0 + log($1) }
        let s = 1 - chi2Q(-2 * spamEvidence, degrees: 2 * n)
        let h = 1 - chi2Q(-2 * hamEvidence, degrees: 2 * n)
        return (s - h + 1) / 2
    }

    /// P(χ² ≥ x²) for an even number of degrees of freedom.
    static func chi2Q(_ x2: Double, degrees: Int) -> Double {
        let m = x2 / 2
        var term = exp(-m)
        var sum = term
        for i in 1..<max(degrees / 2, 1) {
            term *= m / Double(i)
            sum += term
        }
        return min(sum, 1)
    }
}

// MARK: - Store

extension MailStore {
    static func registerJunkMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v22-junk-filter") { db in
            try db.create(table: "junkToken", options: .withoutRowID) { t in
                t.column("token", .text).primaryKey()
                t.column("spam", .integer).notNull().defaults(to: 0)
                t.column("ham", .integer).notNull().defaults(to: 0)
            }
            // One label per message (by Message-ID, so a message keeps it across folders and
            // accounts), with the tokens it added so a correction takes them back exactly.
            try db.create(table: "junkLabel", options: .withoutRowID) { t in
                t.column("messageKey", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("tokens", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            // The score of mail the filter acted on or warned about; 0 after "It's fine".
            try db.alter(table: "message") { t in t.add(column: "junkScore", .double) }
        }
    }

    /// How a message is known to the filter, across folders and accounts.
    static func junkKey(_ message: StoredMessage) -> String {
        message.messageID.map { $0.lowercased() } ?? "\(message.accountID)/\(message.mailbox)/\(message.uid)"
    }

    /// Learns a message as spam or ham. Relearning with the other label takes the old tokens
    /// back first; the same label again changes nothing.
    public func learnJunk(_ message: StoredMessage, as label: JunkLabel) throws {
        let key = Self.junkKey(message)
        let tokens = JunkFilter.tokens(of: message)
        try db.write { db in try Self.learn(key: key, tokens: tokens, label: label, in: db) }
    }

    static func learn(key: String, tokens: Set<String>, label: JunkLabel, in db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT label, tokens FROM junkLabel WHERE messageKey = ?", arguments: [key]) {
            if row["label"] as String == label.rawValue { return }
            try unlearn(row, in: db)
        }
        let column = label == .spam ? "spam" : "ham"
        for token in tokens {
            try db.execute(sql: """
                INSERT INTO junkToken (token, \(column)) VALUES (?, 1)
                ON CONFLICT(token) DO UPDATE SET \(column) = \(column) + 1
                """, arguments: [token])
        }
        let packed = TextCompression.compress(tokens.sorted().joined(separator: "\n")) ?? Data()
        try db.execute(sql: "INSERT OR REPLACE INTO junkLabel (messageKey, label, tokens, createdAt) VALUES (?, ?, ?, ?)",
                       arguments: [key, label.rawValue, packed, Date()])
    }

    private static func unlearn(_ row: Row, in db: Database) throws {
        let column = row["label"] as String == JunkLabel.spam.rawValue ? "spam" : "ham"
        let tokens = TextCompression.decompress(row["tokens"] as Data)?.split(separator: "\n").map(String.init) ?? []
        for token in tokens {
            try db.execute(sql: "UPDATE junkToken SET \(column) = max(\(column) - 1, 0) WHERE token = ?", arguments: [token])
        }
        try db.execute(sql: "DELETE FROM junkToken WHERE spam = 0 AND ham = 0 AND token IN (\(tokens.map { _ in "?" }.joined(separator: ",")))",
                       arguments: StatementArguments(tokens))
    }

    /// Forgets what a message taught (an undone Move to Junk or Not Junk).
    public func forgetJunk(_ message: StoredMessage) throws {
        let key = Self.junkKey(message)
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT label, tokens FROM junkLabel WHERE messageKey = ?", arguments: [key]) else { return }
            try Self.unlearn(row, in: db)
            try db.execute(sql: "DELETE FROM junkLabel WHERE messageKey = ?", arguments: [key])
        }
    }

    public func junkLabel(of message: StoredMessage) throws -> JunkLabel? {
        try db.read {
            try String.fetchOne($0, sql: "SELECT label FROM junkLabel WHERE messageKey = ?", arguments: [Self.junkKey(message)])
                .flatMap(JunkLabel.init(rawValue:))
        }
    }

    /// How many messages each side has learned from.
    public func junkTotals() throws -> JunkFilter.Counts {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT label, count(*) AS n FROM junkLabel GROUP BY label")
            var totals = JunkFilter.Counts(spam: 0, ham: 0)
            for row in rows {
                if row["label"] as String == JunkLabel.spam.rawValue { totals.spam = row["n"] } else { totals.ham = row["n"] }
            }
            return totals
        }
    }

    /// The message's junk probability, or nil while the filter hasn't learned enough.
    public func junkScore(_ message: StoredMessage) throws -> Double? {
        let totals = try junkTotals()
        guard totals.spam >= JunkFilter.minSpam, totals.ham >= JunkFilter.minHam else { return nil }
        let tokens = JunkFilter.tokens(of: message)
        let counts = try junkCounts(Array(tokens))
        return JunkFilter.score(tokens, counts: counts, totals: totals)
    }

    func junkCounts(_ tokens: [String]) throws -> [String: JunkFilter.Counts] {
        try db.read { db in
            var out: [String: JunkFilter.Counts] = [:]
            for start in stride(from: 0, to: tokens.count, by: 500) {
                let chunk = Array(tokens[start..<min(start + 500, tokens.count)])
                let rows = try Row.fetchAll(db, sql: "SELECT token, spam, ham FROM junkToken WHERE token IN (\(chunk.map { _ in "?" }.joined(separator: ",")))",
                                            arguments: StatementArguments(chunk))
                for row in rows { out[row["token"]] = .init(spam: row["spam"], ham: row["ham"]) }
            }
            return out
        }
    }

    public func setJunkScore(_ score: Double?, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.write {
            try $0.execute(sql: "UPDATE message SET junkScore = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           arguments: StatementArguments([score as (any DatabaseValueConvertible)?] + ids.map { $0 as (any DatabaseValueConvertible)? }))
        }
    }

    public func junkScore(id: Int64) throws -> Double? {
        try db.read { try Double.fetchOne($0, sql: "SELECT junkScore FROM message WHERE id = ?", arguments: [id]) }
    }

    /// Junk the account has that the filter hasn't learned yet, newest first.
    func unlearnedJunk(accountID: String, limit: Int) throws -> [StoredMessage] {
        try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m
                WHERE m.accountID = ?1 AND m.mailbox IN (SELECT path FROM mailboxState WHERE accountID = ?1 AND role = 'junk')
                  AND NOT EXISTS (SELECT 1 FROM junkLabel l WHERE l.messageKey = coalesce(lower(m.messageID), m.accountID || '/' || m.mailbox || '/' || m.uid))
                ORDER BY m.date DESC LIMIT ?2
                """, arguments: [accountID, limit])
        }
    }

    /// Mail you've kept, for the "fine" side: filed away (Archive, your folders), or read in the
    /// Inbox and left there for a few days. Not your own, not Junk/Trash/Sent/Drafts, and not
    /// mail the filter is still warning about.
    func unlearnedHam(accountID: String, ownAddresses: Set<String>, limit: Int, settled: Date = Date().addingTimeInterval(-3 * 86_400)) throws -> [StoredMessage] {
        let mine = ownAddresses.map { $0.lowercased() }
        let notMine = mine.isEmpty ? "" : "AND lower(m.fromAddress) NOT IN (\(mine.map { _ in "?" }.joined(separator: ",")))"
        return try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m
                WHERE m.accountID = ? \(notMine)
                  AND m.mailbox NOT IN (SELECT path FROM mailboxState WHERE accountID = ? AND role IN ('junk', 'trash', 'sent', 'drafts'))
                  AND (m.mailbox != 'INBOX' OR (instr(m.flags, '\\Seen') > 0 AND m.date < ?))
                  AND coalesce(m.junkScore, 0) < ?
                  AND NOT EXISTS (SELECT 1 FROM junkLabel l WHERE l.messageKey = coalesce(lower(m.messageID), m.accountID || '/' || m.mailbox || '/' || m.uid))
                ORDER BY m.date DESC LIMIT ?
                """, arguments: StatementArguments([accountID as any DatabaseValueConvertible] + mine.map { $0 as any DatabaseValueConvertible }
                                                   + [accountID, settled, JunkFilter.warningThreshold, limit]))
        }
    }

    /// Have you ever written to this address?
    func hasWrittenTo(_ address: String, ownAddresses: Set<String>) throws -> Bool {
        try db.read { try Self.hasWritten(to: address, from: ownAddresses, in: $0) }
    }

    /// Whether a message from one of `ownAddresses` has exactly `address` among its recipients.
    /// A substring match isn't enough: it would let "ob@example.com" pass as "bob@example.com",
    /// which the junk filter and the remote-image policy both trust.
    static func hasWritten(to address: String, from ownAddresses: Set<String>, in db: Database) throws -> Bool {
        let mine = ownAddresses.map { $0.lowercased() }
        let address = address.lowercased()
        guard !mine.isEmpty, !address.isEmpty else { return false }
        let candidates = try String.fetchCursor(db, sql: """
            SELECT recipients FROM message WHERE lower(fromAddress) IN (\(mine.map { _ in "?" }.joined(separator: ",")))
            AND lower(recipients) LIKE ? ESCAPE '\\'
            """, arguments: StatementArguments(mine + ["%\(likeEscaped(address))%"]))
        while let recipients = try candidates.next() {
            if AddressParser.parse(recipients).contains(where: { $0.address.lowercased() == address }) { return true }
        }
        return false
    }

    /// `%` and `_` in an address are LIKE wildcards; escaped, they match only themselves.
    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
