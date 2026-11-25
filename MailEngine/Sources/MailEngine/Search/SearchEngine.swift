import Foundation
import GRDB

public struct SearchHit: Sendable, Hashable {
    public var id: Int64
    public var subject: String
    public var fromName: String?
    public var fromAddress: String
    public var date: Date
    public var category: MailCategory
    public var snippet: String
}

public struct FacetCount: Sendable, Hashable {
    public var value: String
    public var count: Int
}

/// Phase 1: what the user sees on the keystroke. Budget < 30 ms p95.
public struct SearchHits: Sendable {
    public var hits: [SearchHit]
    public var duration: Duration
}

/// Phase 2: refinement facets, computed after the hits are on screen.
public struct SearchFacets: Sendable {
    public var total: Int
    public var categories: [FacetCount]
    public var years: [FacetCount]
    public var withAttachments: Int
    /// Top senders among the most recent `senderSampleSize` matches.
    public var senders: [FacetCount]
    public var duration: Duration
}

/// Faceted, as-you-type search over the always-local tier (SPEC §7).
///
/// Results are newest-first. The FTS rowid is a `SortKey`, so the index streams matches in
/// date order and the query stops after `limit` rows instead of ranking the whole match set.
/// Category, attachment and date filters/facets are evaluated on the rowid without a join.
public struct SearchEngine: Sendable {
    public let store: MailStore
    public var senderSampleSize = 2_000

    public init(store: MailStore) { self.store = store }

    // MARK: Phase 1

    public func hits(_ query: SearchQuery, limit: Int = 50) throws -> SearchHits {
        let clock = ContinuousClock()
        let start = clock.now
        let plan = Self.plan(query)
        let rows: [Row] = try store.db.read { db in
            if let match = plan.match {
                // Stream FTS newest-first, join only for the rows we keep.
                return try Row.fetchAll(db, sql: """
                    SELECT m.id, m.subject, m.fromName, m.fromAddress, m.date, m.category, m.preview, m.bodyText
                    FROM message_fts f JOIN message m ON m.sortKey = f.rowid
                    WHERE f.message_fts MATCH ? \(plan.rowidSQL("f.rowid")) \(plan.messageSQL)
                    ORDER BY f.rowid DESC LIMIT \(limit)
                    """, arguments: Self.arguments([match] + plan.rowidArguments + plan.messageArguments))
            } else {
                return try Row.fetchAll(db, sql: """
                    SELECT m.id, m.subject, m.fromName, m.fromAddress, m.date, m.category, m.preview, m.bodyText
                    FROM message m
                    WHERE 1 \(plan.rowidSQL("m.sortKey")) \(plan.messageSQL)
                    ORDER BY m.sortKey DESC LIMIT \(limit)
                    """, arguments: Self.arguments(plan.rowidArguments + plan.messageArguments))
            }
        }
        let terms = query.terms + query.phrases
        let hits = rows.map { row -> SearchHit in
            SearchHit(
                id: row["id"], subject: row["subject"], fromName: row["fromName"],
                fromAddress: row["fromAddress"], date: row["date"],
                category: MailCategory(rawValue: row["category"]) ?? .primary,
                snippet: Self.snippet(body: row["bodyText"], fallback: row["preview"], terms: terms)
            )
        }
        return SearchHits(hits: hits, duration: clock.now - start)
    }

    // MARK: Conversations (smart folders)

    /// The conversations a query matches, newest first: for each, the id of its newest
    /// matching message. Smart folders list these; any mailbox counts.
    public func conversations(_ query: SearchQuery, limit: Int = 500) throws -> [Int64] {
        let plan = Self.plan(query)
        return try store.db.read { db in
            let keys: [Int64]
            if let match = plan.match {
                keys = try Int64.fetchAll(db, sql: """
                    SELECT max(m.sortKey) AS k FROM message_fts f JOIN message m ON m.sortKey = f.rowid
                    WHERE f.message_fts MATCH ? \(plan.rowidSQL("f.rowid")) \(plan.messageSQL)
                    GROUP BY coalesce(m.threadID, m.id) ORDER BY k DESC LIMIT \(limit)
                    """, arguments: Self.arguments([match] + plan.rowidArguments + plan.messageArguments))
            } else {
                keys = try Int64.fetchAll(db, sql: """
                    SELECT max(m.sortKey) AS k FROM message m
                    WHERE 1 \(plan.rowidSQL("m.sortKey")) \(plan.messageSQL)
                    GROUP BY coalesce(m.threadID, m.id) ORDER BY k DESC LIMIT \(limit)
                    """, arguments: Self.arguments(plan.rowidArguments + plan.messageArguments))
            }
            guard !keys.isEmpty else { return [] }
            let ids = try Row.fetchAll(db, sql: "SELECT id, sortKey FROM message WHERE sortKey IN (\(keys.map(String.init).joined(separator: ",")))")
            let idByKey = Dictionary(uniqueKeysWithValues: ids.map { ($0["sortKey"] as Int64, $0["id"] as Int64) })
            return keys.compactMap { idByKey[$0] }
        }
    }

    /// How many conversations a query matches (smart folder counts).
    public func conversationCount(_ query: SearchQuery) throws -> Int {
        let plan = Self.plan(query)
        return try store.db.read { db in
            if let match = plan.match {
                return try Int.fetchOne(db, sql: """
                    SELECT count(DISTINCT coalesce(m.threadID, m.id)) FROM message_fts f JOIN message m ON m.sortKey = f.rowid
                    WHERE f.message_fts MATCH ? \(plan.rowidSQL("f.rowid")) \(plan.messageSQL)
                    """, arguments: Self.arguments([match] + plan.rowidArguments + plan.messageArguments)) ?? 0
            }
            return try Int.fetchOne(db, sql: """
                SELECT count(DISTINCT coalesce(m.threadID, m.id)) FROM message m WHERE 1 \(plan.rowidSQL("m.sortKey")) \(plan.messageSQL)
                """, arguments: Self.arguments(plan.rowidArguments + plan.messageArguments)) ?? 0
        }
    }

    // MARK: Phase 2

    public func facets(_ query: SearchQuery) throws -> SearchFacets {
        let clock = ContinuousClock()
        let start = clock.now
        let plan = Self.plan(query)
        return try store.db.read { db in
            // Rowid-only aggregation: no join unless the query has message-table filters.
            let source: String
            let key: String
            var args: [any DatabaseValueConvertible] = []
            if let match = plan.match {
                key = "f.rowid"
                source = plan.messageSQL.isEmpty
                    ? "FROM message_fts f WHERE f.message_fts MATCH ? \(plan.rowidSQL(key))"
                    : "FROM message_fts f JOIN message m ON m.sortKey = f.rowid WHERE f.message_fts MATCH ? \(plan.rowidSQL(key)) \(plan.messageSQL)"
                args = [match] + plan.rowidArguments + plan.messageArguments
            } else {
                key = "m.sortKey"
                source = "FROM message m WHERE 1 \(plan.rowidSQL(key)) \(plan.messageSQL)"
                args = plan.rowidArguments + plan.messageArguments
            }
            let arguments = Self.arguments(args)

            // One grouped pass over the rowids: (category, attachment, day) buckets.
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(SortKey.categorySQL(key)) AS c, \(SortKey.attachmentSQL(key)) AS a,
                       (\(key) >> \(SortKey.secondsShift)) / 86400 AS d, count(*) AS n
                \(source) GROUP BY c, a, d
                """, arguments: arguments)

            var total = 0
            var categoryCounts: [Int64: Int] = [:]
            var yearCounts: [Int: Int] = [:]
            var attachments = 0
            let calendar = Calendar(identifier: .gregorian)
            for row in rows {
                let n: Int = row["n"]
                total += n
                categoryCounts[row["c"], default: 0] += n
                if (row["a"] as Int64) == 1 { attachments += n }
                let day: Int64 = row["d"]
                yearCounts[calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(day * 86_400))), default: 0] += n
            }

            let senderRows = try Row.fetchAll(db, sql: """
                SELECT coalesce(max(m.fromName), m.fromAddress) AS v, count(*) AS n FROM (
                    SELECT \(key) AS k \(source) ORDER BY \(key) DESC LIMIT \(senderSampleSize)
                ) recent JOIN message m ON m.sortKey = recent.k
                GROUP BY m.fromAddress ORDER BY n DESC LIMIT 8
                """, arguments: arguments)

            return SearchFacets(
                total: total,
                categories: categoryCounts
                    .map { FacetCount(value: SortKey.categoriesByCode[$0.key]?.rawValue ?? "?", count: $0.value) }
                    .sorted { $0.count > $1.count },
                years: yearCounts.map { FacetCount(value: String($0.key), count: $0.value) }
                    .sorted { $0.value > $1.value },
                withAttachments: attachments,
                senders: senderRows.map { FacetCount(value: $0["v"], count: $0["n"]) },
                duration: clock.now - start
            )
        }
    }

    // MARK: Planning

    static func arguments(_ values: [any DatabaseValueConvertible]) -> StatementArguments {
        StatementArguments(values.map { $0 as (any DatabaseValueConvertible)? })
    }

    struct Plan {
        var match: String?
        var rowidClauses: [String] = []
        var rowidArguments: [any DatabaseValueConvertible] = []
        var messageClauses: [String] = []
        var messageArguments: [any DatabaseValueConvertible] = []

        func rowidSQL(_ column: String) -> String {
            rowidClauses.map { " AND " + $0.replacingOccurrences(of: "$K", with: column) }.joined()
        }
        var messageSQL: String { messageClauses.map { " AND " + $0 }.joined() }
    }

    static func plan(_ q: SearchQuery) -> Plan {
        var p = Plan()
        p.match = q.ftsExpression
        if !q.categories.isEmpty {
            let codes = q.categories.compactMap { SortKey.categoryCodes[$0] }
            p.rowidClauses.append("\(SortKey.categorySQL("$K")) IN (\(codes.map(String.init).joined(separator: ",")))")
        }
        if let a = q.hasAttachment {
            p.rowidClauses.append("\(SortKey.attachmentSQL("$K")) = \(a ? 1 : 0)")
        }
        if let d = q.after { p.rowidClauses.append("$K >= ?"); p.rowidArguments.append(SortKey.lowerBound(d)) }
        if let d = q.before { p.rowidClauses.append("$K < ?"); p.rowidArguments.append(SortKey.lowerBound(d)) }

        if let box = q.mailbox { p.messageClauses.append("m.mailbox = ? COLLATE NOCASE"); p.messageArguments.append(box) }
        if let u = q.unread {
            p.messageClauses.append(u ? "instr(m.flags, '\\Seen') = 0" : "instr(m.flags, '\\Seen') > 0")
        }
        if let pinned = q.pinned {
            p.messageClauses.append(pinned ? "instr(m.flags, '\\Flagged') > 0" : "instr(m.flags, '\\Flagged') = 0")
        }
        if q.waiting == true {
            // A message you sent that is still the newest in its conversation.
            p.messageClauses.append("""
                m.threadID IS NOT NULL
                AND m.mailbox IN (SELECT path FROM mailboxState WHERE accountID = m.accountID AND role = 'sent')
                AND NOT EXISTS (SELECT 1 FROM message later WHERE later.threadID = m.threadID AND later.date > m.date)
                """)
        }
        if let n = q.largerThan { p.messageClauses.append("m.size > ?"); p.messageArguments.append(n) }
        if let n = q.smallerThan { p.messageClauses.append("m.size < ?"); p.messageArguments.append(n) }
        return p
    }

    /// Cuts a ~160-character window around the first matching term from the compressed body.
    static func snippet(body: Data?, fallback: String, terms: [String]) -> String {
        guard !terms.isEmpty, let body, let text = TextCompression.decompress(body) else { return fallback }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for term in terms {
            let t = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard let range = folded.range(of: t) else { continue }
            let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
            let startOffset = max(0, offset - 60)
            let start = text.index(text.startIndex, offsetBy: min(startOffset, text.count))
            let end = text.index(start, offsetBy: min(160, text.distance(from: start, to: text.endIndex)))
            let window = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (startOffset > 0 ? "…" : "") + window + (end < text.endIndex ? "…" : "")
        }
        return fallback
    }
}
