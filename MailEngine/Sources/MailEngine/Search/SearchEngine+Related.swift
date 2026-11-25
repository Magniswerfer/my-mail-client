import Accelerate
import Foundation
import GRDB

/// A person whose name or address matches the search (the card on top of results, SPEC §7).
public struct ContactHit: Sendable, Hashable {
    public var name: String?
    public var address: String
    public var messageCount: Int
}

extension SearchEngine {
    // MARK: Semantic second tier

    /// Messages close in meaning to `text` that keyword search may have missed (SPEC §7):
    /// the query's embedding against the stored ones for the newest `sample` messages. Only
    /// clear standouts count: at least the mean + 2 standard deviations of this query's scores,
    /// which adapts to how high embedding similarities run for everything.
    public func related(to text: String, embedder: any TextEmbedder, excluding: Set<Int64> = [],
                        limit: Int = 8, sample: Int = 20_000) throws -> [SearchHit] {
        guard let query = embedder.embed(text), query.count == embedder.dimension else { return [] }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.messageID, e.vector FROM embedding e JOIN message m ON m.id = e.messageID
                ORDER BY m.date DESC LIMIT ?
                """, arguments: [sample])
        }
        var ids: [Int64] = []
        var scores: [Float] = []
        ids.reserveCapacity(rows.count)
        scores.reserveCapacity(rows.count)
        for row in rows {
            let vector = MailStore.floats(row["vector"])
            guard vector.count == query.count else { continue }
            var dot: Float = 0
            vDSP_dotpr(query, 1, vector, 1, &dot, vDSP_Length(query.count))
            ids.append(row["messageID"])
            scores.append(dot)
        }
        guard scores.count >= 20 else { return [] }
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(scores, 1, nil, 1, &mean, &std, vDSP_Length(scores.count))
        let cut = mean + 2 * std
        let best = scores.indices
            .filter { scores[$0] >= cut && !excluding.contains(ids[$0]) }
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { ids[$0] }
        guard !best.isEmpty else { return [] }
        let messages = try store.db.read { try StoredMessage.fetchAll($0, keys: best) }
        let byID = Dictionary(uniqueKeysWithValues: messages.compactMap { m in m.id.map { ($0, m) } })
        return best.compactMap { byID[$0] }.map { m in
            SearchHit(id: m.id ?? 0, subject: m.subject, fromName: m.fromName, fromAddress: m.fromAddress, date: m.date,
                      category: m.category, snippet: m.preview)
        }
    }

    // MARK: Entity

    /// The person the query most likely means: plain words that prefix-match a sender's name or
    /// address, ranked by how much mail they've sent. nil for operator queries or long phrases.
    public func contact(for query: SearchQuery) throws -> ContactHit? {
        var bare = query
        bare.terms = []
        guard bare == SearchQuery(), (1...3).contains(query.terms.count),
              query.terms.allSatisfy({ $0.count >= 2 }) else { return nil }
        let match = query.terms.map { "sender:\"\(SearchQuery.ftsSafe($0))\"*" }.joined(separator: " ")
        return try store.db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.fromAddress AS address, max(m.fromName) AS name, count(*) AS n
                FROM message_fts f JOIN message m ON m.sortKey = f.rowid
                WHERE f.message_fts MATCH ?
                GROUP BY lower(m.fromAddress) ORDER BY n DESC LIMIT 1
                """, arguments: [match]) else { return nil }
            return ContactHit(name: row["name"], address: row["address"], messageCount: row["n"])
        }
    }
}
