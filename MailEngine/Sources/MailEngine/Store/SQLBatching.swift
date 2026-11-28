import GRDB

extension MailStore {
    /// How many values one `IN (…)` list binds when a long list is split up: well under
    /// SQLite's limit on bound parameters, and small enough to keep each statement cheap.
    static let sqlBatchSize = 500
}

extension Collection {
    /// The collection in consecutive slices of at most `size` elements.
    func chunks(of size: Int) -> [SubSequence] {
        precondition(size > 0, "chunk size must be positive")
        var chunks: [SubSequence] = []
        var start = startIndex
        while start != endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }

    /// The collection in slices small enough for one `IN (…)` list each.
    func sqlBatches() -> [SubSequence] { chunks(of: MailStore.sqlBatchSize) }

    /// `?,?,?`: one placeholder per element, for an `IN (…)` list.
    var sqlPlaceholders: String { databaseQuestionMarks(count: count) }
}
