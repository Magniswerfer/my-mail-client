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
            ids.append(row["messageID"])
            scores.append(VectorMath.dot(query, vector))
        }
        guard scores.count >= 20 else { return [] }
        let (mean, std) = VectorMath.meanAndDeviation(scores)
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
    /// address, ranked by how much mail they've sent lately (among the newest `contactSampleSize`
    /// matches), with an exact count of everything from them. nil for operator queries or long
    /// phrases. It runs with the hits on every keystroke, so it reads at most a sample of rows: a
    /// broad prefix ("no" → every noreply@) would otherwise group tens of thousands (~250 ms at 250k).
    public func contact(for query: SearchQuery) throws -> ContactHit? {
        var bare = query
        bare.terms = []
        guard bare == SearchQuery(), (1...3).contains(query.terms.count),
              query.terms.allSatisfy({ $0.count >= 2 }) else { return nil }
        let match = query.terms.map { "sender:\"\(SearchQuery.ftsSafe($0))\"*" }.joined(separator: " ")
        return try store.db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.fromAddress, max(m.fromName), count(*) FROM (
                    SELECT rowid AS k FROM message_fts WHERE message_fts MATCH ? ORDER BY rowid DESC LIMIT \(contactSampleSize)
                ) recent JOIN message m ON m.sortKey = recent.k
                GROUP BY m.fromAddress
                """, arguments: [match])
            // One person per address, however its case is spelled.
            var people: [String: (spellings: [String], name: String?, count: Int)] = [:]
            for row in rows {
                let address: String = row[0]
                let name: String? = row[1]
                let n: Int = row[2]
                people[address.lowercased(), default: ([], nil, 0)].spellings.append(address)
                people[address.lowercased()]!.count += n
                if let name, name > (people[address.lowercased()]!.name ?? "") { people[address.lowercased()]!.name = name }
            }
            guard let top = people.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.value else { return nil }
            // Exact, from the fromAddress index alone (no row reads).
            let total = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message WHERE fromAddress IN (\(top.spellings.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(top.spellings)) ?? top.count
            let address = top.spellings.first { $0 == $0.lowercased() } ?? top.spellings.sorted()[0]
            return ContactHit(name: top.name, address: address, messageCount: total)
        }
    }
}
