import Foundation
import GRDB

/// How to leave a mailing list, from its headers (RFC 2369 List-Unsubscribe, RFC 8058 one-click).
public struct UnsubscribeOptions: Codable, Sendable, Hashable {
    /// POST "List-Unsubscribe=One-Click" here: done without leaving the app.
    public var oneClick: URL?
    /// Send an email (often with a subject the list expects).
    public var mailto: String?
    public var mailtoSubject: String?
    /// A web page to finish on.
    public var web: URL?

    public var isEmpty: Bool { oneClick == nil && mailto == nil && web == nil }

    public static func parse(listUnsubscribe: String?, listUnsubscribePost: String?) -> UnsubscribeOptions? {
        guard let header = listUnsubscribe else { return nil }
        var options = UnsubscribeOptions()
        let oneClick = listUnsubscribePost?.replacingOccurrences(of: " ", with: "").lowercased()
            .contains("list-unsubscribe=one-click") == true
        for match in header.matches(of: /<([^>]+)>/) {
            let value = String(match.output.1).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("mailto:"), options.mailto == nil {
                var comps = URLComponents(string: value)
                options.mailto = comps?.path.removingPercentEncoding ?? String(value.dropFirst(7))
                options.mailtoSubject = comps?.queryItems?.first { $0.name.lowercased() == "subject" }?.value
                comps = nil
            } else if let url = URL(string: value), url.scheme == "https" || url.scheme == "http" {
                // One-click only over HTTPS (RFC 8058).
                if oneClick, url.scheme == "https", options.oneClick == nil { options.oneClick = url }
                else if options.web == nil { options.web = url }
            }
        }
        return options.isEmpty ? nil : options
    }

    public static func parse(_ message: ParsedMessage) -> UnsubscribeOptions? {
        parse(listUnsubscribe: message.header("List-Unsubscribe"), listUnsubscribePost: message.header("List-Unsubscribe-Post"))
    }
}

/// One row of the Senders screen (SPEC §11), sorted by volume.
public struct SenderStat: Sendable, Hashable, Identifiable {
    public var id: String { address }
    public var address: String
    public var name: String?
    public var count: Int
    public var inInbox: Int
    public var unread: Int
    public var lastDate: Date
    public var category: MailCategory
    public var canUnsubscribe: Bool
}

/// An attachment and the message it came with (attachment browser).
public struct AttachmentEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(messageID)#\(index)" }
    public var messageID: Int64
    public var index: Int
    public var info: AttachmentInfo
    public var sender: String
    public var subject: String
    public var date: Date
}

extension MailStore {
    static func registerNewsletterMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v16-unsubscribe-attachments") { db in
            try db.alter(table: "message") { t in
                t.add(column: "unsubscribe", .text)
                t.add(column: "attachments", .text)
            }
        }
    }

    public func senders(ownAddresses: Set<String>, limit: Int = 300) throws -> [SenderStat] {
        let own = ownAddresses.isEmpty ? [""] : ownAddresses.map { $0.lowercased() }.sorted()
        let ownSQL = own.map { _ in "?" }.joined(separator: ",")
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT lower(fromAddress) AS a, max(fromName) AS n, count(*) AS c, sum(mailbox = 'INBOX') AS inbox,
                       sum(mailbox = 'INBOX' AND instr(flags, '\\Seen') = 0) AS unread, max(date) AS last,
                       max(unsubscribe IS NOT NULL) AS unsub
                FROM message
                WHERE fromAddress != '' AND lower(fromAddress) NOT IN (\(ownSQL))
                  AND mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('sent', 'drafts'))
                GROUP BY lower(fromAddress) ORDER BY c DESC LIMIT ?
                """, arguments: StatementArguments(own + [limit] as [any DatabaseValueConvertible]))
            // Each sender's most common category, in one pass.
            var best: [String: (MailCategory, Int)] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT lower(fromAddress) AS a, category AS cat, count(*) AS n FROM message
                WHERE fromAddress != '' GROUP BY lower(fromAddress), category
                """) {
                let a: String = row["a"]
                let n: Int = row["n"]
                if let c = MailCategory(rawValue: row["cat"] ?? ""), n > (best[a]?.1 ?? 0) { best[a] = (c, n) }
            }
            return rows.map {
                let a: String = $0["a"]
                return SenderStat(address: a, name: $0["n"], count: $0["c"], inInbox: $0["inbox"] ?? 0, unread: $0["unread"] ?? 0,
                                  lastDate: $0["last"], category: best[a]?.0 ?? .primary,
                                  canUnsubscribe: ($0["unsub"] as Int? ?? 0) == 1)
            }
        }
    }

    /// The newest message from a sender that says how to unsubscribe.
    public func unsubscribeOptions(for address: String) throws -> (UnsubscribeOptions, StoredMessage)? {
        let m = try db.read { db in
            try StoredMessage.fetchOne(db, sql: """
                SELECT * FROM message WHERE lower(fromAddress) = ? AND unsubscribe IS NOT NULL ORDER BY date DESC LIMIT 1
                """, arguments: [address.lowercased()])
        }
        guard let m, let options = m.unsubscribe else { return nil }
        return (options, m)
    }

    /// Conversations from a sender in a mailbox (for "Mark all done").
    public func threadIDs(from address: String, mailbox: String = "INBOX") throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT threadID FROM message WHERE lower(fromAddress) = ? AND mailbox = ? AND threadID IS NOT NULL
                """, arguments: [address.lowercased(), mailbox])
        }
    }

    /// Conversations carrying a keyword (Read Later), newest first.
    public func threadIDs(withKeyword keyword: String, limit: Int = 500) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT threadID FROM message WHERE instr(flags, ?) > 0 AND threadID IS NOT NULL
                GROUP BY threadID ORDER BY max(date) DESC LIMIT ?
                """, arguments: [keyword, limit])
        }
    }

    /// Attachments (not inline images), newest first, from messages that recorded them at sync.
    public func attachmentEntries(limit: Int = 1_000) throws -> [AttachmentEntry] {
        let rows = try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE attachments IS NOT NULL AND hasAttachments = 1
                  AND mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('trash', 'junk'))
                ORDER BY date DESC LIMIT ?
                """, arguments: [limit])
        }
        var seen = Set<String>()
        return rows.flatMap { m in
            (m.attachments ?? []).enumerated().compactMap { i, info -> AttachmentEntry? in
                guard !info.isInline, let id = m.id else { return nil }
                // The same file in several copies of a message (Inbox + Sent) shows once.
                guard seen.insert("\(m.messageID ?? "\(id)")|\(info.filename ?? "")|\(info.size)").inserted else { return nil }
                return AttachmentEntry(messageID: id, index: i, info: info, sender: m.fromName ?? m.fromAddress,
                                       subject: m.subject, date: m.date)
            }
        }
    }
}
