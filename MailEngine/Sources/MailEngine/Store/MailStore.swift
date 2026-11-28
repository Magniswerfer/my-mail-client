import Foundation
import GRDB

/// Categories from SPEC §4.
public enum MailCategory: String, Sendable, Codable, CaseIterable, DatabaseValueConvertible {
    case primary, transactions, updates, newsletters, advertising, social
}

/// A message as kept in the always-local tier (SPEC §3, ADR 0001).
public struct StoredMessage: Sendable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    /// Date-ordered key that is also the FTS rowid. See `SortKey`.
    public var sortKey: Int64 = 0
    public var accountID: String
    public var mailbox: String
    public var uid: UInt32
    public var messageID: String?
    public var threadID: String?
    public var subject: String
    public var fromName: String?
    public var fromAddress: String
    public var recipients: String
    public var date: Date
    public var flags: String
    public var size: Int
    public var hasAttachments: Bool
    public var category: MailCategory
    public var preview: String
    /// LZFSE-compressed UTF-8 plain-text body.
    public var bodyText: Data?
    public var inReplyTo: String?
    /// Why the message got its category ("why is this here?", SPEC §5).
    public var classificationReason: String?
    /// When a snoozed message came back: it sorts as new mail from then on.
    public var surfacedAt: Date?
    public var snoozedUntil: Date?
    public var isSnoozed: Bool = false
    /// Phishing/spoofing assessment (SPEC §8); reasons are encoded `RiskReason`s.
    public var riskLevel: RiskLevel = .none
    public var riskReasons: String?
    /// The meeting invite, update, cancellation or reply this message carries (JSON), and its
    /// event UID so every message about one event shares a conversation.
    public var invite: CalendarInvite?
    public var inviteUID: String?
    /// Codes, parcels, flights, receipts, reservations, bills found in the message (JSON).
    public var highlights: [Highlight]?
    /// The files attached (not inline images), as JSON. nil until known: set at sync, from the
    /// cache in the background, or when the message is opened.
    public var attachmentList: [AttachmentInfo]?
    /// The junk filter's score, when it moved this to Junk or warned about it; 0 after "It's fine".
    public var junkScore: Double?
    /// Set when this message is a reaction: the Message-ID it reacts to, and the emoji ("" when
    /// the sender took their reaction back). Reactions never show as mail (see `reactions(toMessageIDs:)`).
    public var reactionTo: String?
    public var reactionEmoji: String?
    /// The sender asked not to be reacted to (`x-ms-reactions: disallow`).
    public var reactionsDisallowed: Bool = false

    /// A reaction ("👍"), not mail to show.
    public var isReaction: Bool { reactionTo != nil }

    public init(
        id: Int64? = nil, accountID: String, mailbox: String, uid: UInt32, messageID: String? = nil,
        threadID: String? = nil, subject: String, fromName: String? = nil, fromAddress: String,
        recipients: String = "", date: Date, flags: String = "", size: Int = 0, hasAttachments: Bool = false,
        category: MailCategory = .primary, preview: String = "", bodyText: Data? = nil
    ) {
        self.id = id; self.accountID = accountID; self.mailbox = mailbox; self.uid = uid
        self.messageID = messageID; self.threadID = threadID; self.subject = subject
        self.fromName = fromName; self.fromAddress = fromAddress; self.recipients = recipients
        self.date = date; self.flags = flags; self.size = size; self.hasAttachments = hasAttachments
        self.category = category; self.preview = preview; self.bodyText = bodyText
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var plainText: String? { bodyText.flatMap(TextCompression.decompress) }
}

/// The always-local tier: metadata, compressed plain text and the full-text index.
///
/// The FTS5 table is *contentless* (`content=''`): it stores only the inverted index,
/// never a second copy of the text. Snippets are cut from the compressed body on demand.
public final class MailStore: Sendable {
    public let db: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        db = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sortKey", .integer).notNull().unique()
                t.column("accountID", .text).notNull()
                t.column("mailbox", .text).notNull()
                t.column("uid", .integer).notNull()
                t.column("messageID", .text)
                t.column("threadID", .text)
                t.column("subject", .text).notNull()
                t.column("fromName", .text)
                t.column("fromAddress", .text).notNull()
                t.column("recipients", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("flags", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("hasAttachments", .boolean).notNull()
                t.column("category", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("bodyText", .blob)
                t.uniqueKey(["accountID", "mailbox", "uid"])
            }
            try db.create(index: "message_date", on: "message", columns: ["date"])
            try db.create(index: "message_from", on: "message", columns: ["fromAddress"])
            try db.create(index: "message_category_date", on: "message", columns: ["category", "date"])
            try db.create(index: "message_thread", on: "message", columns: ["threadID"])
            // Prefix indexes make as-you-type queries ("fak", "fakt") cheap; unicode61 with
            // diacritic folding keeps "æøå" searchable and folds "é" → "e".
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    subject, sender, recipients, body,
                    content='', contentless_delete=1,
                    tokenize='unicode61 remove_diacritics 2',
                    prefix='1 2 3'
                )
                """)
        }
        registerSyncMigrations(&m)
        registerTriageMigrations(&m)
        registerOutboxMigrations(&m)
        registerClassifierMigrations(&m)
        registerPrivacyMigrations(&m)
        registerRiskMigrations(&m)
        registerEmbeddingMigrations(&m)
        registerPreviewMigrations(&m)
        registerInviteMigrations(&m)
        registerAssistMigrations(&m)
        registerRuleMigrations(&m)
        registerSmartFolderMigrations(&m)
        registerMuteMigrations(&m)
        registerUnsubscribeMigrations(&m)
        registerAttachmentMigrations(&m)
        registerHighlightMigrations(&m)
        registerAICategoryMigrations(&m)
        registerEventSuggestionMigrations(&m)
        registerCloudMigrations(&m)
        registerJunkMigrations(&m)
        registerReactionMigrations(&m)
        registerSignatureMigrations(&m)
        registerHighlightTrainingMigrations(&m)
        registerReactionIndexMigrations(&m)
        return m
    }

    // MARK: Writing

    /// Inserts or replaces messages and keeps the index in step. `plainText` is the
    /// extracted body; it is compressed for storage and indexed in full.
    public func upsert(_ items: [(message: StoredMessage, plainText: String)]) throws {
        try db.write { db in
            for case (var message, let text) in items {
                if message.bodyText == nil, !text.isEmpty { message.bodyText = TextCompression.compress(text) }
                if message.preview.isEmpty { message.preview = Self.makePreview(text) }
                if let existing = try Row.fetchOne(db, sql: """
                    SELECT id, sortKey FROM message WHERE accountID = ? AND mailbox = ? AND uid = ?
                    """, arguments: [message.accountID, message.mailbox, message.uid]) {
                    message.id = existing["id"]
                    try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [existing["sortKey"] as Int64])
                    message.sortKey = try Self.freeSortKey(db, SortKey.make(for: message, id: message.id!), excluding: message.id)
                    try message.update(db)
                } else {
                    message.sortKey = try Self.freeSortKey(db, SortKey.make(for: message, id: try Self.nextID(db)), excluding: nil)
                    try message.insert(db)
                }
                // Reactions ("👍") are never search results: keeping them out of the index lets
                // text search and facets read the index alone, without joining `message`.
                guard message.reactionTo == nil else { continue }
                try db.execute(sql: """
                    INSERT INTO message_fts(rowid, subject, sender, recipients, body) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        message.sortKey, message.subject,
                        [message.fromName, message.fromAddress].compactMap { $0 }.joined(separator: " "),
                        message.recipients, text,
                    ])
            }
        }
    }

    static func nextID(_ db: Database) throws -> Int64 {
        (try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'message'") ?? 0) + 1
    }

    /// Sort keys must be unique; on the (rare) collision, nudge the low bits.
    static func freeSortKey(_ db: Database, _ key: Int64, excluding id: Int64?) throws -> Int64 {
        var candidate = key
        while let owner = try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE sortKey = ?", arguments: [candidate]),
              owner != id {
            candidate = SortKey.withLowBits(candidate, SortKey.lowBits(candidate) &+ 1)
        }
        return candidate
    }

    public func delete(ids: [Int64]) throws {
        try db.write { db in
            for id in ids {
                guard let key = try Int64.fetchOne(db, sql: "SELECT sortKey FROM message WHERE id = ?", arguments: [id]) else { continue }
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [key])
                try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
            }
        }
    }

    public func count() throws -> Int {
        try db.read { try StoredMessage.fetchCount($0) }
    }

    /// The first words of what this message itself says. Quoted replies ("> …"), attribution
    /// lines ("On … wrote:", "Den … skrev …:") and forwarded/original-message blocks are left out.
    static func makePreview(_ text: String) -> String {
        let kept = ownLines(text)
        let collapsed = kept.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let result = collapsed.isEmpty ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ") : collapsed
        return String(result.prefix(160))
    }

    /// The lines the sender wrote themselves: no "> " quotes, attribution lines, or the
    /// original/forwarded message below.
    static func ownLines(_ text: String) -> [Substring] {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("-----original message") || lower.hasPrefix("-----oprindelig")
                || lower.hasPrefix("---------- forwarded") || lower.hasPrefix("---------- videresendt") { break }
            let attribution = (lower.hasPrefix("on ") && lower.hasSuffix("wrote:"))
                || (lower.hasPrefix("den ") && lower.contains("skrev") && lower.hasSuffix(":"))
            if attribution { continue }
            kept.append(line)
        }
        return kept
    }

    /// What the sender wrote themselves, with blank-line runs collapsed (for AI input).
    public static func ownText(_ text: String) -> String {
        var out: [Substring] = []
        for line in ownLines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// M4.5: recompute stored previews without quoted text.
    static func registerPreviewMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v9-clean-previews") { db in
            var updates: [(Int64, String)] = []
            let rows = try Row.fetchCursor(db, sql: "SELECT id, bodyText FROM message WHERE bodyText IS NOT NULL")
            while let row = try rows.next() {
                if let data: Data = row["bodyText"], let text = TextCompression.decompress(data) {
                    updates.append((row["id"], makePreview(text)))
                }
            }
            for (id, preview) in updates {
                try db.execute(sql: "UPDATE message SET preview = ? WHERE id = ?", arguments: [preview, id])
            }
        }
    }
}

/// Tier-1 body text. LZFSE on Apple platforms (its streams start with "bvx"). Linux has no
/// LZFSE (ADR 0007), so there the text is stored as is behind a 0x00 tag byte. A store never
/// leaves its host, so the two forms only meet in tests.
enum TextCompression {
    static let plainTag: UInt8 = 0
    #if canImport(Darwin)
    static let compresses = true
    #else
    static let compresses = false
    #endif

    static func compress(_ text: String) -> Data? {
        #if canImport(Darwin)
        return try? (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data
        #else
        return Data([plainTag]) + Data(text.utf8)
        #endif
    }

    static func decompress(_ data: Data) -> String? {
        if data.first == plainTag { return String(decoding: data.dropFirst(), as: UTF8.self) }
        #if canImport(Darwin)
        guard let raw = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return String(data: raw, encoding: .utf8)
        #else
        return nil
        #endif
    }
}

/// The FTS rowid layout. Newest-first iteration of the index is then just `ORDER BY rowid DESC`,
/// which FTS5 streams without sorting, and category/attachment/date filters and facets can be read
/// from the rowid alone, with no join (SPEC §15: < 30 ms per keystroke).
///
///     bit 63      sign (always 0)
///     bits 24–62  seconds since 1970 (39 bits, good until year ~19400)
///     bits 21–23  category (3 bits)
///     bit  20     has attachments
///     bits 0–19   disambiguator (message id low bits)
public enum SortKey {
    static let secondsShift: Int64 = 24
    static let categoryShift: Int64 = 21
    static let attachmentShift: Int64 = 20
    static let lowMask: Int64 = (1 << 20) - 1

    static let categoryCodes: [MailCategory: Int64] = [
        .primary: 0, .transactions: 1, .updates: 2, .newsletters: 3, .advertising: 4, .social: 5,
    ]
    static let categoriesByCode: [Int64: MailCategory] =
        Dictionary(uniqueKeysWithValues: categoryCodes.map { ($1, $0) })

    public static func make(for message: StoredMessage, id: Int64) -> Int64 {
        let seconds = max(0, Int64(message.date.timeIntervalSince1970))
        return (seconds << secondsShift)
            | (categoryCodes[message.category]! << categoryShift)
            | ((message.hasAttachments ? 1 : 0) << attachmentShift)
            | (id & lowMask)
    }

    /// Smallest key for messages at or after `date`.
    public static func lowerBound(_ date: Date) -> Int64 { max(0, Int64(date.timeIntervalSince1970)) << secondsShift }

    static func lowBits(_ key: Int64) -> Int64 { key & lowMask }
    static func withLowBits(_ key: Int64, _ bits: Int64) -> Int64 { (key & ~lowMask) | (bits & lowMask) }

    /// SQL fragments over a rowid column.
    static func categorySQL(_ column: String) -> String { "((\(column) >> \(categoryShift)) & 7)" }
    static func attachmentSQL(_ column: String) -> String { "((\(column) >> \(attachmentShift)) & 1)" }
    static func yearSQL(_ column: String) -> String { "strftime('%Y', \(column) >> \(secondsShift), 'unixepoch')" }
}
