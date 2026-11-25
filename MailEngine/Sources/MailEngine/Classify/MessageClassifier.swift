import Foundation
import GRDB

/// Why a message got its category ("why is this here?", SPEC §5), as a stable code the app
/// localizes. Stored as "code" or "code|argument" in `message.classificationReason`.
public enum ClassificationReason: Sendable, Hashable {
    case sentByYou
    case youMovedThisSender(MailCategory)
    case youMovedThisConversation(MailCategory)
    case socialNetwork(domain: String)
    case transactional
    case promotional
    case mailingListUnsubscribe
    case mailingList
    case automatedSender(local: String)
    case person
    case calendarInvite                    // an invitation, update or cancellation for you
    case calendarReply                     // someone answered your invitation
    case rule(String)                      // one of your rules, by name
    case learned(confidence: Int)          // fast classifier, percent
    case onDevice(summary: String)         // Foundation Models, its own short reason

    public var encoded: String {
        switch self {
        case .sentByYou: "sentByYou"
        case .youMovedThisSender(let c): "senderRule|\(c.rawValue)"
        case .youMovedThisConversation(let c): "moved|\(c.rawValue)"
        case .socialNetwork(let d): "social|\(d)"
        case .transactional: "transactional"
        case .promotional: "promotional"
        case .mailingListUnsubscribe: "listUnsubscribe"
        case .mailingList: "list"
        case .automatedSender(let l): "automated|\(l)"
        case .person: "person"
        case .calendarInvite: "invite"
        case .calendarReply: "inviteReply"
        case .rule(let name): "rule|\(name)"
        case .learned(let p): "learned|\(p)"
        case .onDevice(let s): "ai|\(s)"
        }
    }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "sentByYou": self = .sentByYou
        case "senderRule": guard let c = MailCategory(rawValue: arg) else { return nil }; self = .youMovedThisSender(c)
        case "moved": guard let c = MailCategory(rawValue: arg) else { return nil }; self = .youMovedThisConversation(c)
        case "social": self = .socialNetwork(domain: arg)
        case "transactional": self = .transactional
        case "promotional": self = .promotional
        case "listUnsubscribe": self = .mailingListUnsubscribe
        case "list": self = .mailingList
        case "automated": self = .automatedSender(local: arg)
        case "person": self = .person
        case "invite": self = .calendarInvite
        case "inviteReply": self = .calendarReply
        case "rule": self = .rule(arg)
        case "learned": self = .learned(confidence: Int(arg) ?? 0)
        case "ai": self = .onDevice(summary: arg)
        default: return nil
        }
    }

    /// How sure the deciding layer is; low values are candidates for the next layer.
    var confidence: Double {
        switch self {
        case .sentByYou, .youMovedThisSender, .youMovedThisConversation: 1
        case .calendarInvite, .calendarReply: 0.95
        case .rule: 1
        case .socialNetwork, .mailingListUnsubscribe: 0.9
        case .transactional, .promotional: 0.85
        case .automatedSender, .mailingList: 0.75
        case .person: 0.6            // "no machine signals" is weak evidence: refine
        case .learned(let p): Double(p) / 100
        case .onDevice: 0.8
        }
    }
}

/// A remembered correction: "mail from this address belongs in this category".
public struct SenderRule: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "senderRule"
    public var address: String
    public var category: MailCategory
    public var createdAt: Date
}

/// The classification pipeline (ADR 0004): your corrections → header signals → (later layers).
public struct MessageClassifier: Sendable {
    public let store: MailStore

    public init(store: MailStore) { self.store = store }

    public func classify(_ parsed: ParsedMessage, userAddresses: Set<String>) -> (MailCategory, ClassificationReason) {
        let from = parsed.from.first?.address.lowercased() ?? ""
        if let rule = try? store.senderRule(for: from) {
            return (rule.category, .youMovedThisSender(rule.category))
        }
        let signal = SignalClassifier.classify(parsed, userAddresses: userAddresses)
        return (signal.category, signal.reason)
    }
}

extension MailStore {
    static func registerClassifierMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v5-classifier") { db in
            try db.create(table: "senderRule") { t in
                t.column("address", .text).primaryKey()
                t.column("category", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
    }

    public func senderRule(for address: String) throws -> SenderRule? {
        try db.read { try SenderRule.fetchOne($0, key: address.lowercased()) }
    }

    /// Remembers a correction and applies it to every stored message from that sender.
    /// Returns the ids that changed category.
    @discardableResult
    public func remember(category: MailCategory, forSender address: String) throws -> [Int64] {
        let sender = address.lowercased()
        try db.write { try SenderRule(address: sender, category: category, createdAt: Date()).save($0) }
        let ids = try db.read {
            try Int64.fetchAll($0, sql: "SELECT id FROM message WHERE lower(fromAddress) = ? AND category != ?",
                               arguments: [sender, category.rawValue])
        }
        try setCategory(category, reason: .youMovedThisSender(category), ids: ids)
        return ids
    }

    /// What a correction changed, so it can be undone exactly.
    public struct CategorySnapshot: Sendable, Hashable {
        public var id: Int64
        public var category: MailCategory
        public var reason: String?

        public init(id: Int64, category: MailCategory, reason: String?) {
            self.id = id
            self.category = category
            self.reason = reason
        }
    }

    /// Moves conversations to a category ("only this one"). Teaches the classifier (a strong
    /// training label) and, once the same sender has been moved to the same category in two
    /// separate conversations, makes it a sender rule. Returns what changed (for undo) and the
    /// sender that got a rule, if any.
    public func moveConversations(_ threadIDs: [String], to category: MailCategory, ownAddresses: Set<String> = [],
                                  promoteAfter: Int = 2) throws -> (previous: [CategorySnapshot], promotedSender: String?) {
        guard !threadIDs.isEmpty else { return ([], nil) }
        let placeholders = threadIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, category, classificationReason, lower(fromAddress) AS sender FROM message WHERE threadID IN (\(placeholders))",
                             arguments: StatementArguments(threadIDs))
        }
        let previous = rows.map {
            CategorySnapshot(id: $0["id"], category: MailCategory(rawValue: $0["category"]) ?? .primary, reason: $0["classificationReason"])
        }
        try setCategory(category, reason: .youMovedThisConversation(category), ids: previous.map(\.id))

        var promoted: String?
        let mine = Set(ownAddresses.map { $0.lowercased() })
        let senders = Set(rows.compactMap { $0["sender"] as String? }).subtracting(mine)
        let marker = ClassificationReason.youMovedThisConversation(category).encoded
        for sender in senders where try senderRule(for: sender) == nil {
            let moved = try db.read {
                try Int.fetchOne($0, sql: "SELECT count(DISTINCT threadID) FROM message WHERE lower(fromAddress) = ? AND classificationReason = ?",
                                 arguments: [sender, marker]) ?? 0
            }
            if moved >= promoteAfter {
                try remember(category: category, forSender: sender)
                promoted = sender
            }
        }
        return (previous, promoted)
    }

    /// Puts categories back exactly as captured.
    public func restoreCategories(_ snapshots: [CategorySnapshot]) throws {
        for snapshot in snapshots {
            let reason = snapshot.reason.flatMap(ClassificationReason.init(encoded:)) ?? .person
            try setCategory(snapshot.category, reason: reason, ids: [snapshot.id])
        }
    }

    public func forgetSenderRule(_ address: String) throws {
        _ = try db.write { try SenderRule.deleteOne($0, key: address.lowercased()) }
    }

    /// Changes category. The category is part of the FTS rowid (`SortKey`), so the index entry
    /// is re-keyed: deleted under the old key and re-inserted (text from the compressed body).
    public func setCategory(_ category: MailCategory, reason: ClassificationReason, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                guard var message = try StoredMessage.fetchOne(db, key: id) else { continue }
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [message.sortKey])
                message.category = category
                message.classificationReason = reason.encoded
                message.sortKey = try Self.freeSortKey(db, SortKey.make(for: message, id: id), excluding: id)
                try message.update(db)
                try db.execute(sql: """
                    INSERT INTO message_fts(rowid, subject, sender, recipients, body) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [message.sortKey, message.subject,
                                     [message.fromName, message.fromAddress].compactMap { $0 }.joined(separator: " "),
                                     message.recipients, message.plainText ?? ""])
            }
        }
    }
}
