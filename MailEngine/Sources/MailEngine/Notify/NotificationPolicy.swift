import Foundation
import GRDB

/// One notification to show for newly arrived mail (SPEC §10).
public struct MailNotification: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case person
        case vip
        case pinned
        /// An answer in a conversation where you wrote last.
        case reply
        /// One of your rules said "Notify me".
        case rule(String)
    }

    public var localID: Int64
    public var messageID: String?
    public var threadID: String
    public var accountID: String
    public var sender: String
    public var subject: String
    public var preview: String
    public var reason: Reason
}

/// What deserves a notification. Never per-bundle mail; only what a person would want to know
/// about now: Primary mail from people (optionally only VIPs), pinned conversations, replies
/// to mail you're waiting on, and rules that ask for it.
public struct NotificationPolicy: Codable, Sendable, Hashable {
    public var isEnabled = true
    public var people = true
    public var onlyVIPs = false
    public var pinned = true
    public var replies = true
    public var rules = true
    /// Lowercased addresses.
    public var vips: [String] = []
    /// Mail older than this when it reaches the device (catching up after sleep) stays quiet.
    public var maxAge: TimeInterval = 24 * 3600

    public init() {}

    /// The notifications for mail that just arrived, oldest first.
    public func notifications(for arrived: [StoredMessage], ruleRuns: [RuleRun], ownAddresses: Set<String>,
                              store: MailStore, now: Date = Date()) -> [MailNotification] {
        guard isEnabled else { return [] }
        let own = Set(ownAddresses.map { $0.lowercased() })
        let vipSet = Set(vips.map { $0.lowercased() })
        var ruleNames: [Int64: String] = [:]
        for run in ruleRuns { ruleNames[run.messageID] = run.ruleNames.first ?? "" }
        return arrived.compactMap { m in
            guard let id = m.id, let threadID = m.threadID,
                  !own.contains(m.fromAddress.lowercased()),
                  !m.flags.contains("\\Seen"),
                  now.timeIntervalSince(m.date) <= maxAge,
                  !((try? store.isMuted(threadID: threadID)) ?? false) else { return nil }
            let reason: MailNotification.Reason?
            if rules, let name = ruleNames[id] {
                reason = .rule(name)
            } else if pinned, (try? store.isPinned(threadID: threadID)) == true {
                reason = .pinned
            } else if replies, (try? store.wasWaiting(threadID: threadID, before: m.date)) == true {
                reason = .reply
            } else if people, m.category == .primary {
                if vipSet.contains(m.fromAddress.lowercased()) { reason = .vip }
                else { reason = onlyVIPs ? nil : .person }
            } else {
                reason = nil
            }
            guard let reason else { return nil }
            return MailNotification(localID: id, messageID: m.messageID, threadID: threadID, accountID: m.accountID,
                                    sender: m.fromName ?? m.fromAddress, subject: m.subject, preview: m.preview, reason: reason)
        }
    }
}

extension MailStore {
    func isPinned(threadID: String) throws -> Bool {
        try db.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE threadID = ? AND instr(flags, '\\Flagged') > 0)",
                              arguments: [threadID]) ?? false
        }
    }

    /// Whether the newest message before `date` in the conversation is one you sent.
    func wasWaiting(threadID: String, before date: Date) throws -> Bool {
        try db.read { db in
            guard let mailbox = try String.fetchOne(db, sql: """
                SELECT mailbox FROM message WHERE threadID = ? AND date < ? ORDER BY date DESC LIMIT 1
                """, arguments: [threadID, date]) else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mailboxState WHERE path = ? AND role = 'sent')",
                                     arguments: [mailbox]) ?? false
        }
    }

    /// The people you write to most (to seed VIPs): recipients of your recent sent mail.
    public func frequentCorrespondents(ownAddresses: Set<String>, limit: Int = 10, sample: Int = 2000) throws -> [MailAddress] {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let recipients = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT recipients FROM message
                WHERE mailbox IN (SELECT path FROM mailboxState WHERE role = 'sent')
                ORDER BY date DESC LIMIT ?
                """, arguments: [sample])
        }
        var counts: [String: (MailAddress, Int)] = [:]
        for line in recipients {
            for address in AddressParser.parse(line) {
                let key = address.address.lowercased()
                guard !own.contains(key), !SignatureInfo.looksAutomated(key) else { continue }
                counts[key] = (counts[key]?.0 ?? address, (counts[key]?.1 ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
