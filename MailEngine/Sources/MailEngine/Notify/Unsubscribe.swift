import Foundation
import GRDB
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a sender lets you leave their list (SPEC §11), best first.
public enum UnsubscribeMethod: Sendable, Hashable {
    /// RFC 8058: one POST, no page to visit.
    case oneClick(URL)
    /// A page to open in the browser.
    case web(URL)
    /// An email to send.
    case mail(to: String, subject: String, body: String)
}

public enum Unsubscribe {
    /// The methods a message offers, from its `List-Unsubscribe` and `List-Unsubscribe-Post`
    /// headers. One-click needs HTTPS and the `List-Unsubscribe=One-Click` post header.
    public static func methods(listUnsubscribe: String?, listUnsubscribePost: String?) -> [UnsubscribeMethod] {
        guard let header = listUnsubscribe else { return [] }
        let oneClick = listUnsubscribePost?.range(of: "List-Unsubscribe=One-Click", options: .caseInsensitive) != nil
        var web: [UnsubscribeMethod] = []
        var clicks: [UnsubscribeMethod] = []
        var mails: [UnsubscribeMethod] = []
        // Entries are <…> separated by commas; tolerate missing brackets.
        let entries = header.contains("<")
            ? header.components(separatedBy: "<").dropFirst().compactMap { $0.components(separatedBy: ">").first }
            : header.components(separatedBy: ",")
        for entry in entries.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard let url = URL(string: entry), let scheme = url.scheme?.lowercased() else { continue }
            switch scheme {
            case "https" where oneClick: clicks.append(.oneClick(url))
            case "https", "http": web.append(.web(url))
            case "mailto":
                let parts = URLComponents(string: entry)
                let address = (parts?.path ?? "").removingPercentEncoding ?? ""
                guard address.contains("@") else { continue }
                let query = Dictionary((parts?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                mails.append(.mail(to: address, subject: query["subject"].flatMap { $0.isEmpty ? nil : $0 } ?? "unsubscribe",
                                   body: query["body"] ?? ""))
            default: continue
            }
        }
        return clicks + mails + web
    }

    public static func methods(in parsed: ParsedMessage) -> [UnsubscribeMethod] {
        methods(listUnsubscribe: parsed.header("List-Unsubscribe"), listUnsubscribePost: parsed.header("List-Unsubscribe-Post"))
    }

    public enum Failure: Error, Sendable { case status(Int) }

    /// RFC 8058 one-click: POST `List-Unsubscribe=One-Click`, no cookies, no redirects to follow.
    public static func postOneClick(_ url: URL, session: URLSession = .shared) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.status(status) }
    }
}

/// A sender and how much mail they send you (the Senders screen, SPEC §11).
public struct SenderStats: Sendable, Hashable, Identifiable {
    public var address: String
    public var name: String?
    public var count: Int
    public var inboxCount: Int
    public var unreadCount: Int
    public var lastDate: Date
    public var category: MailCategory
    /// Bulk mail that came with an unsubscribe link (or from a list).
    public var isList: Bool
    public var unsubscribedAt: Date?
    public var id: String { address }
}

extension MailStore {
    static func registerUnsubscribeMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v15-unsubscribed") { db in
            try db.create(table: "unsubscribed") { t in
                t.column("address", .text).primaryKey()
                t.column("at", .datetime).notNull()
                t.column("method", .text).notNull()
            }
        }
    }

    public func recordUnsubscribe(address: String, method: String) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO unsubscribed (address, at, method) VALUES (?, ?, ?)",
                           arguments: [address.lowercased(), Date(), method])
        }
    }

    public func unsubscribedAt(address: String) throws -> Date? {
        try db.read { try Date.fetchOne($0, sql: "SELECT at FROM unsubscribed WHERE address = ?", arguments: [address.lowercased()]) }
    }

    /// Who sends you the most mail (not counting your own), busiest first.
    public func senderStats(ownAddresses: Set<String>, since: Date? = nil, limit: Int = 300) throws -> [SenderStats] {
        let own = ownAddresses.map { $0.lowercased() }
        let ownList = own.isEmpty ? "''" : own.map { _ in "?" }.joined(separator: ",")
        var args: [any DatabaseValueConvertible] = own
        var dateClause = ""
        if let since { dateClause = "AND date >= ?"; args.append(since) }
        args.append(limit)
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT lower(fromAddress) AS address, max(fromName) AS name, count(*) AS n,
                       sum(mailbox = 'INBOX') AS inbox,
                       sum(mailbox = 'INBOX' AND instr(flags, '\\Seen') = 0) AS unread,
                       max(date) AS last,
                       max(classificationReason IN ('listUnsubscribe', 'list')) AS list,
                       (SELECT category FROM message l WHERE lower(l.fromAddress) = lower(message.fromAddress) ORDER BY date DESC LIMIT 1) AS category,
                       (SELECT at FROM unsubscribed u WHERE u.address = lower(message.fromAddress)) AS unsubscribed
                FROM message
                WHERE lower(fromAddress) NOT IN (\(ownList))
                  AND mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('sent', 'drafts'))
                  \(dateClause)
                GROUP BY lower(fromAddress) ORDER BY n DESC LIMIT ?
                """, arguments: StatementArguments(args.map { $0 as (any DatabaseValueConvertible)? })).map { row in
                SenderStats(address: row["address"], name: row["name"], count: row["n"], inboxCount: row["inbox"] ?? 0,
                            unreadCount: row["unread"] ?? 0, lastDate: row["last"],
                            category: MailCategory(rawValue: row["category"] ?? "") ?? .primary,
                            isList: (row["list"] as Int? ?? 0) == 1, unsubscribedAt: row["unsubscribed"])
            }
        }
    }

    /// The newest message from a sender (where to find their unsubscribe headers).
    public func newestMessage(from address: String) throws -> StoredMessage? {
        try db.read {
            try StoredMessage.fetchOne($0, sql: "SELECT * FROM message WHERE lower(fromAddress) = ? ORDER BY date DESC LIMIT 1",
                                       arguments: [address.lowercased()])
        }
    }
}
