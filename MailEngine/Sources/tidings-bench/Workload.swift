import Foundation
import GRDB
import MailEngine

/// The synthetic mailbox the budgets are measured on: `SyntheticCorpus` (Zipf vocabulary, mixed
/// Danish/English, eight years of mail) shaped like a real account. Mail from the last 45 days is
/// in the Inbox (about 2%, ~5k messages at 250k), the rest in Archive; most conversations are a
/// single message, some run to six. The newest Inbox messages also have a raw body in the cache
/// tier: plain text, an HTML newsletter, or a message with a 256 KB attachment.
enum Workload {
    static let account = "synthetic"
    static let me = "magnus@example.dk"
    static let inboxDays = 45.0
    static let cachedBodies = 300

    static func storePath(_ directory: URL) -> String { directory.appendingPathComponent("mail.sqlite").path }
    static func cache(_ directory: URL) -> MessageCache { MessageCache(directory: directory.appendingPathComponent("cache")) }

    struct Summary { var messages: Int; var inbox: Int; var cached: Int }

    static func seed(count: Int, directory: URL) throws -> Summary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: storePath(directory)) else {
            throw BenchError("\(storePath(directory)) already exists; seed into an empty directory")
        }
        let store = try MailStore(path: storePath(directory))
        var rng = Rng(seed: 2026)
        let inboxSince = Date().addingTimeInterval(-inboxDays * 86_400)

        var all = SyntheticCorpus().messages(count: count, accountID: account)
        var thread = 0
        var left = 0
        for i in all.indices {
            if left == 0 {
                thread += 1
                left = rng.next() % 10 < 6 ? 1 : 2 + rng.next() % 5
            }
            left -= 1
            all[i].message.threadID = "thread-\(thread)"
            all[i].message.mailbox = all[i].message.date >= inboxSince ? "INBOX" : "Archive"
        }
        for chunk in stride(from: 0, to: all.count, by: 5_000) {
            try store.upsert(Array(all[chunk..<min(chunk + 5_000, all.count)]))
        }

        let inbox = all.filter { $0.message.mailbox == "INBOX" }
        try store.db.write { db in
            for (path, total) in [("INBOX", inbox.count), ("Archive", all.count - inbox.count)] {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO mailboxState(accountID, path, uidValidity, messageCount) VALUES (?, ?, 1, ?)
                    """, arguments: [account, path, total])
            }
        }

        let cache = cache(directory)
        let newest = inbox.sorted { $0.message.date > $1.message.date }.prefix(cachedBodies)
        for (n, item) in newest.enumerated() {
            let raw = RawMail.make(kind: n % 3, message: item.message, text: item.plainText)
            try cache.write(raw, account: account, mailbox: "INBOX", validity: 1, uid: item.message.uid)
        }
        return Summary(messages: all.count, inbox: inbox.count, cached: newest.count)
    }
}

/// Raw RFC 5322 messages for the cache tier, sized like real mail.
enum RawMail {
    static func make(kind: Int, message: StoredMessage, text: String) -> Data {
        var headers = [
            "From: \(message.fromName ?? "") <\(message.fromAddress)>",
            "To: \(Workload.me)",
            "Subject: =?utf-8?B?\(Data(message.subject.utf8).base64EncodedString())?=",
            "Date: \(rfc822(message.date))",
            "Message-ID: \(message.messageID ?? "<\(message.uid)@synthetic.invalid>")",
            "MIME-Version: 1.0",
        ]
        let body: String
        switch kind {
        case 0:
            headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit"]
            body = wrap(text)
        case 1:
            headers.append("Content-Type: multipart/alternative; boundary=\"alt\"")
            body = """
                --alt
                Content-Type: text/plain; charset=utf-8
                Content-Transfer-Encoding: 8bit

                \(wrap(text))
                --alt
                Content-Type: text/html; charset=utf-8
                Content-Transfer-Encoding: base64

                \(Data(newsletter(text).utf8).base64EncodedString(options: .lineLength76Characters))
                --alt--
                """
        default:
            headers.append("Content-Type: multipart/mixed; boundary=\"mix\"")
            var rng = Rng(seed: UInt64(message.uid))
            let file = Data((0..<262_144).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            body = """
                --mix
                Content-Type: text/plain; charset=utf-8
                Content-Transfer-Encoding: 8bit

                \(wrap(text))
                --mix
                Content-Type: application/pdf
                Content-Disposition: attachment; filename="faktura-\(message.uid).pdf"
                Content-Transfer-Encoding: base64

                \(file.base64EncodedString(options: .lineLength76Characters))
                --mix--
                """
        }
        let joined = headers.joined(separator: "\n") + "\n\n" + body + "\n"
        return Data(joined.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    /// A newsletter-shaped page (~50 KB): nested tables, inline styles, links and images.
    static func newsletter(_ text: String) -> String {
        let words = text.split(separator: " ")
        var html = "<html><head><style>td{font-family:Helvetica,Arial,sans-serif;color:#333}</style></head><body><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">"
        var section = 0
        while html.utf8.count < 50_000 {
            let start = (section * 37) % max(words.count, 1)
            let slice = words[start..<min(start + 60, words.count)].joined(separator: " ")
            html += """
                <tr><td style="padding:24px 32px;border-bottom:1px solid #eee"><table width="100%"><tr>\
                <td width="120"><img src="https://cdn.example.com/img/\(section).jpg" width="120" height="80" alt=""></td>\
                <td style="padding-left:16px"><h2 style="margin:0 0 8px;font-size:18px">Afsnit \(section)</h2>\
                <p style="margin:0;line-height:1.5">\(slice) <a href="https://example.com/r/\(section)?utm_source=nl">Læs mere</a></p>\
                </td></tr></table></td></tr>
                """
            section += 1
        }
        return html + "</table></body></html>"
    }

    static func wrap(_ text: String) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count > 72 { lines.append(line); line = "" }
            line += line.isEmpty ? String(word) : " \(word)"
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    static func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}

/// SplitMix64, so the mailbox is the same on every run.
struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int { Int(truncatingIfNeeded: nextBits() >> 1) }
    mutating func nextBits() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
