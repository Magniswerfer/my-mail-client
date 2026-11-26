import Foundation
import GRDB

/// What the date scan found in one message, keyed by account + Message-ID so it survives a move
/// to Archive (and your Dismiss with it).
public struct EventSuggestionRecord: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "eventSuggestion"

    public enum State: String, Sendable, Codable, DatabaseValueConvertible {
        /// Shown in the reader (when there's anything upcoming to show).
        case open
        /// You dismissed it: never shown again for this message.
        case dismissed
        /// You added (one of) them to your calendar.
        case added
    }

    public var accountID: String
    public var messageKey: String
    /// Possibly empty: "scanned, nothing found".
    public var suggestions: [EventSuggestion]
    public var state: State
    /// Some suggestions still wait for the on-device model (hidden until then).
    public var awaitingReview: Bool
    public var scannedAt: Date

    public init(accountID: String, messageKey: String, suggestions: [EventSuggestion], state: State = .open,
                awaitingReview: Bool = false, scannedAt: Date = Date()) {
        self.accountID = accountID
        self.messageKey = messageKey
        self.suggestions = suggestions
        self.state = state
        self.awaitingReview = awaitingReview
        self.scannedAt = scannedAt
    }

    /// What the reader may show: confident (or model-confirmed) suggestions that haven't ended.
    public func visible(at now: Date = Date()) -> [EventSuggestion] {
        guard state != .dismissed else { return [] }
        return suggestions.filter { ($0.confidence == .high || $0.reviewedByModel) && $0.isUpcoming(at: now) }
    }
}

extension MailStore {
    static func registerEventSuggestionMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v20-event-suggestions") { db in
            try db.create(table: "eventSuggestion") { t in
                t.column("accountID", .text).notNull()
                t.column("messageKey", .text).notNull()
                t.column("suggestions", .text).notNull()     // JSON [EventSuggestion]
                t.column("state", .text).notNull().defaults(to: "open")
                t.column("awaitingReview", .boolean).notNull().defaults(to: false)
                t.column("scannedAt", .datetime).notNull()
                t.primaryKey(["accountID", "messageKey"])
            }
            try db.create(index: "eventSuggestion_review", on: "eventSuggestion", columns: ["awaitingReview"])
        }
    }

    public func eventSuggestions(for message: StoredMessage) throws -> EventSuggestionRecord? {
        try db.read { try EventSuggestionRecord.fetchOne($0, key: ["accountID": message.accountID, "messageKey": message.eventKey]) }
    }

    /// Saves a scan. A re-scan keeps what you decided (dismissed / added).
    public func saveEventSuggestions(_ record: EventSuggestionRecord) throws {
        try db.write { db in
            var record = record
            if let existing = try EventSuggestionRecord.fetchOne(db, key: ["accountID": record.accountID, "messageKey": record.messageKey]) {
                record.state = existing.state
            }
            try record.save(db)
        }
    }

    public func setEventSuggestionState(_ state: EventSuggestionRecord.State, for message: StoredMessage) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE eventSuggestion SET state = ? WHERE accountID = ? AND messageKey = ?",
                           arguments: [state, message.accountID, message.eventKey])
        }
    }

    /// Recent mail not scanned yet, newest first: received mail only (not Sent, Drafts, Trash
    /// or Junk), without a meeting invite (M4.6 handles those).
    public func messagesNeedingEventScan(since: Date, limit: Int) throws -> [StoredMessage] {
        try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m
                WHERE m.date >= ? AND m.invite IS NULL
                  AND m.mailbox NOT IN (SELECT path FROM mailboxState s WHERE s.accountID = m.accountID
                                        AND s.role IN ('sent', 'drafts', 'trash', 'junk'))
                  AND NOT EXISTS (SELECT 1 FROM eventSuggestion e WHERE e.accountID = m.accountID
                                  AND e.messageKey = coalesce(m.messageID, 'uid:' || m.mailbox || '/' || m.uid))
                ORDER BY m.date DESC LIMIT ?
                """, arguments: [since, limit])
        }
    }

    /// Scans with suggestions the on-device model still has to look at.
    public func eventSuggestionsAwaitingReview(limit: Int) throws -> [EventSuggestionRecord] {
        try db.read { db in
            try EventSuggestionRecord.fetchAll(db, sql: """
                SELECT * FROM eventSuggestion WHERE awaitingReview = 1 ORDER BY scannedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// A message for a stored scan (any copy of it), for the model's context.
    public func message(accountID: String, eventKey: String) throws -> StoredMessage? {
        try db.read { db in
            if eventKey.hasPrefix("uid:") {
                return try StoredMessage.fetchOne(db, sql: """
                    SELECT * FROM message WHERE accountID = ? AND messageID IS NULL AND 'uid:' || mailbox || '/' || uid = ?
                    """, arguments: [accountID, eventKey])
            }
            return try StoredMessage.fetchOne(db, sql: """
                SELECT * FROM message WHERE messageID = ? AND accountID = ? ORDER BY date DESC LIMIT 1
                """, arguments: [eventKey, accountID])
        }
    }
}
