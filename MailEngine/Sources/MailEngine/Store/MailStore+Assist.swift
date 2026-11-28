import Foundation
import GRDB

// MARK: - Records

/// A cached on-device summary of a conversation. `basis` says what it was made from, so a new
/// message makes it stale.
public struct ThreadDigestRecord: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "threadDigest"
    public var threadID: String
    public var basis: String
    public var summary: String
    public var createdAt: Date
}

/// A follow-up Tidings drafted for a conversation still waiting on someone else (Auto Drafts).
/// Never sent by itself: it waits in Drafts until you send, edit or dismiss it.
public struct AutoDraft: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "autoDraft"
    public var threadID: String
    public var accountID: String
    /// The draft in the outbox table; nil once dismissed or sent.
    public var outboxID: Int64?
    /// The message of yours it follows up on.
    public var messageID: Int64
    public var createdAt: Date
    public var dismissed: Bool
    /// A follow-up to your own unanswered mail, or a reply to mail that asks you something.
    public var kind: Kind

    public enum Kind: String, Sendable, Codable, DatabaseValueConvertible { case followUp, reply }

    public init(threadID: String, accountID: String, outboxID: Int64?, messageID: Int64, createdAt: Date = Date(),
                dismissed: Bool = false, kind: Kind = .followUp) {
        self.threadID = threadID
        self.accountID = accountID
        self.outboxID = outboxID
        self.messageID = messageID
        self.createdAt = createdAt
        self.dismissed = dismissed
        self.kind = kind
    }
}

/// Everything Tidings knows about a correspondent, from your own mail (Contact sidebar).
public struct ContactProfile: Sendable, Hashable {
    public struct Conversation: Sendable, Hashable, Identifiable {
        public var id: String { threadID }
        public var threadID: String
        public var subject: String
        public var date: Date
        public var fromThem: Bool
    }

    public var address: String
    public var name: String?
    public var received: Int
    public var sent: Int
    public var firstContact: Date?
    public var lastContact: Date?
    public var recent: [Conversation]
    /// Other people you mail at the same organisation (not for webmail domains).
    public var colleagues: [MailAddress]
    public var signature: SignatureInfo
    /// When they usually answer you, if there's enough history (median hours).
    public var typicalReplyHours: Double?

    public var domain: String { address.split(separator: "@").last.map(String.init) ?? "" }
    public var isOrganisation: Bool { !SignatureInfo.webmailDomains.contains(domain.lowercased()) }
}

// MARK: - Store

extension MailStore {
    static func registerAssistMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v11-assist") { db in
            try db.create(table: "threadDigest") { t in
                t.column("threadID", .text).primaryKey()
                t.column("basis", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "autoDraft") { t in
                t.column("threadID", .text).primaryKey()
                t.column("accountID", .text).notNull()
                t.column("outboxID", .integer)
                t.column("messageID", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("dismissed", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v18-reply-drafts") { db in
            try db.alter(table: "autoDraft") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "followUp")
            }
        }
    }

    // MARK: Summaries

    public func digest(threadID: String) throws -> ThreadDigestRecord? {
        try db.read { try ThreadDigestRecord.fetchOne($0, key: threadID) }
    }

    public func saveDigest(threadID: String, basis: String, summary: String) throws {
        try db.write { try ThreadDigestRecord(threadID: threadID, basis: basis, summary: summary, createdAt: Date()).save($0) }
    }

    // MARK: Auto Drafts

    private static let secondsPerDay: TimeInterval = 86_400
    /// More recipients than this is a blast, not a conversation worth following up.
    private static let maxFollowUpRecipients = 6
    /// Shorter than this (in characters of your own words) is a bare "Thanks!", not a question.
    private static let minFollowUpLength = 40
    /// Candidates the SQL returns per wanted result: the Swift-side filters drop most of them.
    private static let followUpOverfetch = 3
    private static let replyOverfetch = 4
    /// You're on To, approximated as "one of the first few addresses is yours": `recipients`
    /// is To + Cc in that order.
    private static let toAddressesChecked = 3

    /// Conversations where you wrote last, to real people, between `minDays` and `maxDays` ago,
    /// with nothing drafted or dismissed for them yet. Newest first.
    public func followUpCandidates(accountID: String, ownAddresses: Set<String>, minDays: Int = 3, maxDays: Int = 21,
                                   now: Date = Date(), limit: Int = 10) throws -> [StoredMessage] {
        let own = Set(ownAddresses.map { $0.lowercased() })
        guard !own.isEmpty else { return [] }
        let newest = now.addingTimeInterval(-Double(minDays) * Self.secondsPerDay)
        let oldest = now.addingTimeInterval(-Double(maxDays) * Self.secondsPerDay)
        let rows = try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m JOIN (
                    SELECT threadID, max(date) AS d FROM message WHERE accountID = ? AND threadID IS NOT NULL GROUP BY threadID
                ) t ON m.threadID = t.threadID AND m.date = t.d
                WHERE m.accountID = ? AND m.reactionTo IS NULL
                  AND lower(m.fromAddress) IN (\(own.sqlPlaceholders))
                  AND m.date BETWEEN ? AND ?
                  AND m.threadID NOT IN (SELECT threadID FROM autoDraft)
                  AND m.mailbox NOT IN (SELECT path FROM mailboxState WHERE accountID = ? AND role IN ('drafts', 'trash', 'junk'))
                ORDER BY m.date DESC LIMIT ?
                """, arguments: StatementArguments([accountID, accountID] + own.sorted() + [oldest, newest, accountID, limit * Self.followUpOverfetch] as [any DatabaseValueConvertible]))
        }
        var seen = Set<String>()
        return rows.filter { m in
            guard let thread = m.threadID, seen.insert(thread).inserted else { return false }
            let others = AddressParser.parse(m.recipients).filter { !own.contains($0.address.lowercased()) }
            guard !others.isEmpty, others.count <= Self.maxFollowUpRecipients else { return false }
            guard !others.contains(where: { SignatureInfo.looksAutomated($0.address) }) else { return false }
            return MailStore.ownText(m.plainText ?? m.preview).count >= Self.minFollowUpLength
        }
        .prefix(limit).map { $0 }
    }

    /// Recent Primary mail from a person, addressed to you (To, not just Cc), that looks like it
    /// asks you something, newest first, with nothing drafted for it yet.
    public func replyCandidates(accountID: String, ownAddresses: Set<String>, maxDays: Int = 2,
                                now: Date = Date(), limit: Int = 5) throws -> [StoredMessage] {
        let own = Set(ownAddresses.map { $0.lowercased() })
        guard !own.isEmpty else { return [] }
        let oldest = now.addingTimeInterval(-Double(maxDays) * Self.secondsPerDay)
        let rows = try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT m.* FROM message m JOIN (
                    SELECT threadID, max(date) AS d FROM message WHERE accountID = ? AND threadID IS NOT NULL GROUP BY threadID
                ) t ON m.threadID = t.threadID AND m.date = t.d
                WHERE m.accountID = ? AND m.mailbox = 'INBOX' AND m.category = 'primary' AND m.date >= ? AND m.reactionTo IS NULL
                  AND lower(m.fromAddress) NOT IN (\(own.sqlPlaceholders))
                  AND m.threadID NOT IN (SELECT threadID FROM autoDraft)
                ORDER BY m.date DESC LIMIT ?
                """, arguments: StatementArguments([accountID, accountID, oldest] + own.sorted() + [limit * Self.replyOverfetch] as [any DatabaseValueConvertible]))
        }
        return rows.filter { m in
            guard !SignatureInfo.looksAutomated(m.fromAddress), m.riskLevel == .none else { return false }
            let listed = AddressParser.parse(m.recipients).prefix(Self.toAddressesChecked).map { $0.address.lowercased() }
            guard listed.contains(where: own.contains) else { return false }
            return NeedsReply.likely(subject: m.subject, text: m.plainText ?? m.preview)
        }
        .prefix(limit).map { $0 }
    }

    public func saveAutoDraft(_ draft: AutoDraft) throws {
        try db.write { try draft.save($0) }
    }

    /// Follow-up drafts waiting for you, with their conversation's newest message.
    public func pendingAutoDrafts() throws -> [AutoDraft] {
        try db.read { db in
            try AutoDraft.fetchAll(db, sql: """
                SELECT a.* FROM autoDraft a JOIN outbox o ON o.id = a.outboxID
                WHERE a.dismissed = 0 AND o.state = 'draft' ORDER BY a.createdAt DESC
                """)
        }
    }

    public func autoDraft(threadID: String) throws -> AutoDraft? {
        try db.read { try AutoDraft.fetchOne($0, key: threadID) }
    }

    /// "Not needed": the draft goes, and this conversation isn't drafted for again.
    public func dismissAutoDraft(threadID: String) throws {
        try db.write { db in
            guard let draft = try AutoDraft.fetchOne(db, key: threadID) else { return }
            try Self.retire(draft, in: db)
        }
    }

    /// A reply arrived (or you wrote again): an unsent follow-up draft is no longer right.
    @discardableResult
    public func retireAnsweredAutoDrafts() throws -> Int {
        try db.write { db in
            let stale = try AutoDraft.fetchAll(db, sql: """
                SELECT a.* FROM autoDraft a JOIN message m ON m.id = a.messageID
                WHERE a.dismissed = 0 AND a.outboxID IS NOT NULL
                  AND EXISTS (SELECT 1 FROM message n WHERE n.threadID = a.threadID AND n.date > m.date)
                """)
            for draft in stale { try Self.retire(draft, in: db) }
            return stale.count
        }
    }

    /// Deletes the draft if it's still unsent and marks the conversation as not to be drafted for again.
    private static func retire(_ draft: AutoDraft, in db: Database) throws {
        var draft = draft
        if let id = draft.outboxID {
            try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND state = 'draft'", arguments: [id])
        }
        draft.outboxID = nil
        draft.dismissed = true
        try draft.save(db)
    }

    // MARK: Contacts

    private static let colleaguesShown = 5
    /// Short replies often have no signature: look through this many of their latest messages.
    private static let signatureSearchDepth = 6
    private static let replyTimeSamples = 200
    /// Fewer answers than this say nothing about how fast someone replies.
    private static let minReplyTimeSamples = 3

    public func contactProfile(address raw: String, ownAddresses: Set<String>, recentLimit: Int = 8) throws -> ContactProfile {
        let address = raw.lowercased()
        let own = Set(ownAddresses.map { $0.lowercased() })
        let ownList = own.isEmpty ? [""] : own.sorted()
        let ownMarks = ownList.sqlPlaceholders
        let like = "%\(address)%"
        return try db.read { db in
            let received = try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE lower(fromAddress) = ?", arguments: [address]) ?? 0
            let sent = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message WHERE lower(fromAddress) IN (\(ownMarks)) AND lower(recipients) LIKE ?
                """, arguments: StatementArguments(ownList + [like])) ?? 0
            let span = try Row.fetchOne(db, sql: """
                SELECT min(date) AS first, max(date) AS last FROM message
                WHERE lower(fromAddress) = ? OR (lower(fromAddress) IN (\(ownMarks)) AND lower(recipients) LIKE ?)
                """, arguments: StatementArguments([address] + ownList + [like]))
            let name = try String.fetchOne(db, sql: """
                SELECT fromName FROM message WHERE lower(fromAddress) = ? AND fromName IS NOT NULL AND fromName != ''
                ORDER BY date DESC LIMIT 1
                """, arguments: [address])
            let recent = try Row.fetchAll(db, sql: """
                SELECT threadID, subject, max(date) AS d, sum(lower(fromAddress) = ?) > 0 AS fromThem FROM message
                WHERE threadID IS NOT NULL AND (lower(fromAddress) = ? OR (lower(fromAddress) IN (\(ownMarks)) AND lower(recipients) LIKE ?))
                GROUP BY threadID ORDER BY d DESC LIMIT ?
                """, arguments: StatementArguments([address, address] + ownList + [like, recentLimit])).map {
                ContactProfile.Conversation(threadID: $0["threadID"], subject: $0["subject"], date: $0["d"], fromThem: $0["fromThem"])
            }
            let domain = address.split(separator: "@").last.map(String.init) ?? ""
            var colleagues: [MailAddress] = []
            if !domain.isEmpty, !SignatureInfo.webmailDomains.contains(domain) {
                colleagues = try Row.fetchAll(db, sql: """
                    SELECT lower(fromAddress) AS a, max(fromName) AS n, count(*) AS c FROM message
                    WHERE lower(fromAddress) LIKE ? AND lower(fromAddress) != ? GROUP BY lower(fromAddress) ORDER BY c DESC LIMIT \(Self.colleaguesShown)
                    """, arguments: ["%@\(domain)", address]).map { MailAddress(name: $0["n"], address: $0["a"]) }
                    .filter { !SignatureInfo.looksAutomated($0.address) && !own.contains($0.address) }
            }
            let signature = try Data.fetchAll(db, sql: """
                SELECT bodyText FROM message WHERE lower(fromAddress) = ? AND bodyText IS NOT NULL ORDER BY date DESC LIMIT \(Self.signatureSearchDepth)
                """, arguments: [address]).lazy.compactMap(TextCompression.decompress).map(SignatureInfo.extract)
                .first { !$0.links.isEmpty || !$0.phones.isEmpty } ?? SignatureInfo()

            // Reply time: their message right after one of yours in the same conversation.
            let pairs = try Row.fetchAll(db, sql: """
                SELECT (julianday(t.date) - julianday(m.date)) * 24 AS hours FROM message m
                JOIN message t ON t.threadID = m.threadID AND lower(t.fromAddress) = ? AND t.date > m.date
                WHERE lower(m.fromAddress) IN (\(ownMarks)) AND lower(m.recipients) LIKE ?
                  AND NOT EXISTS (SELECT 1 FROM message x WHERE x.threadID = m.threadID AND x.date > m.date AND x.date < t.date)
                LIMIT \(Self.replyTimeSamples)
                """, arguments: StatementArguments([address] + ownList + [like])).compactMap { $0["hours"] as Double? }
            let sorted = pairs.sorted()
            return ContactProfile(
                address: address, name: name, received: received, sent: sent,
                firstContact: span?["first"], lastContact: span?["last"], recent: recent, colleagues: colleagues,
                signature: signature,
                typicalReplyHours: sorted.count >= Self.minReplyTimeSamples ? sorted[sorted.count / 2] : nil)
        }
    }
}
