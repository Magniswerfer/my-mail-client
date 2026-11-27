import Foundation

/// An attachment on an outgoing message.
public struct OutgoingAttachment: Codable, Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for inline images referenced from the HTML as `cid:`.
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

/// A message to send (SPEC §9). Bcc is part of the envelope only, never a header.
public struct OutgoingMessage: Codable, Sendable, Hashable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var text: String
    public var html: String?
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var messageID: String
    public var date: Date
    /// Opaque editor state (the composer's rich text as RTF) so a draft reopens exactly as left.
    /// Never sent.
    public var editorState: Data?
    /// An iCalendar part (e.g. an invite reply), sent as `text/calendar` alongside the text.
    public var calendar: OutgoingCalendar?
    /// Set when this message is a reaction ("👍"): the body is then the reaction parts only.
    public var reaction: OutgoingReaction?

    public init(
        from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [],
        subject: String, text: String, html: String? = nil, attachments: [OutgoingAttachment] = [],
        inReplyTo: String? = nil, references: [String] = [], messageID: String? = nil, date: Date = Date()
    ) {
        self.from = from; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.text = text; self.html = html; self.attachments = attachments
        self.inReplyTo = inReplyTo; self.references = references
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "tidings.local"
        self.messageID = messageID ?? "\(UUID().uuidString.lowercased())@\(domain)"
        self.date = date
    }

    /// Every address the message is delivered to (SMTP RCPT TO).
    public var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Serializes an `OutgoingMessage` to RFC 5322 / MIME bytes.
///
/// Output is 7-bit clean (quoted-printable text, base64 binaries, RFC 2047 headers, RFC 2231
/// filenames), so it passes any SMTP server without 8BITMIME or SMTPUTF8.
public enum MIMEBuilder {
    public static func build(_ m: OutgoingMessage, userAgent: String = "Tidings") -> Data {
        var headers: [String] = [
            "From: \(address(m.from))",
            "Date: \(rfc5322Date(m.date))",
            "Message-ID: <\(m.messageID)>",
            "Subject: \(encodeHeader(m.subject))",
        ]
        if !m.to.isEmpty { headers.append("To: \(m.to.map(address).joined(separator: ", "))") }
        if !m.cc.isEmpty { headers.append("Cc: \(m.cc.map(address).joined(separator: ", "))") }
        if let parent = m.inReplyTo { headers.append("In-Reply-To: <\(parent)>") }
        if !m.references.isEmpty { headers.append("References: \(m.references.map { "<\($0)>" }.joined(separator: " "))") }
        headers.append("MIME-Version: 1.0")
        headers.append("User-Agent: \(userAgent)")

        let body = bodyPart(m)
        var lines = headers.map(fold)
        lines.append(contentsOf: body.headers)
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body.content
        return Data(text.utf8)
    }

    struct Part {
        var headers: [String]
        var content: String

        var serialized: String { headers.joined(separator: "\r\n") + "\r\n\r\n" + content }
    }

    static func bodyPart(_ m: OutgoingMessage) -> Part {
        if let reaction = m.reaction { return reactionPart(reaction) }
        let textPart = Part(headers: ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                            content: quotedPrintable(m.text))
        var main = textPart
        if let html = m.html {
            let htmlPart = Part(headers: ["Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                                content: quotedPrintable(html))
            main = multipart("alternative", [textPart, htmlPart])
        }
        if let calendar = m.calendar {
            // iTIP over email (RFC 6047): the calendar is an alternative of the text, with the
            // method repeated on the Content-Type so clients don't have to parse it.
            let calendarPart = Part(
                headers: ["Content-Type: text/calendar; charset=utf-8; method=\(calendar.method.rawValue)",
                          "Content-Transfer-Encoding: quoted-printable"],
                content: quotedPrintable(calendar.ics))
            let alternatives = m.html == nil ? [textPart] : [textPart, Part(
                headers: ["Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                content: quotedPrintable(m.html ?? ""))]
            main = multipart("alternative", alternatives + [calendarPart])
        }
        let inline = m.attachments.filter { $0.contentID != nil }
        let regular = m.attachments.filter { $0.contentID == nil }
        if !inline.isEmpty {
            main = multipart("related", [main] + inline.map(attachmentPart))
        }
        if !regular.isEmpty {
            main = multipart("mixed", [main] + regular.map(attachmentPart))
        }
        return main
    }

    static func multipart(_ subtype: String, _ parts: [Part]) -> Part {
        let boundary = "=_tidings_\(UUID().uuidString.lowercased().prefix(16))"
        var content = ""
        for part in parts {
            content += "--\(boundary)\r\n" + part.serialized + "\r\n"
        }
        content += "--\(boundary)--\r\n"
        return Part(headers: ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\""], content: content)
    }

    static func attachmentPart(_ a: OutgoingAttachment) -> Part {
        let ascii = a.filename.allSatisfy { $0.isASCII && $0 != "\"" && $0 != "\\" }
        let dispositionName = ascii
            ? "filename=\"\(a.filename)\""
            : "filename*=utf-8''\(a.filename.addingPercentEncoding(withAllowedCharacters: rfc2231Safe) ?? "attachment")"
        var headers = [
            fold("Content-Type: \(a.mimeType); name=\"\(ascii ? a.filename : encodeHeader(a.filename))\""),
            fold("Content-Disposition: \(a.contentID == nil ? "attachment" : "inline"); \(dispositionName)"),
            "Content-Transfer-Encoding: base64",
        ]
        if let cid = a.contentID { headers.append("Content-ID: <\(cid)>") }
        return Part(headers: headers, content: a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n")
    }

    static let rfc2231Safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        .subtracting(CharacterSet(charactersIn: "æøåÆØÅ")).intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))

    // MARK: Headers

    static func address(_ a: MailAddress) -> String {
        guard let name = a.name, !name.isEmpty else { return a.address }
        if !name.allSatisfy(\.isASCII) { return "\(encodeHeader(name)) <\(a.address)>" }
        let needsQuotes = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return needsQuotes ? "\"\(escaped)\" <\(a.address)>" : "\(name) <\(a.address)>"
    }

    /// RFC 2047 B-encoding for non-ASCII header text, split so each encoded word stays short
    /// and never cuts a UTF-8 sequence.
    public static func encodeHeader(_ s: String) -> String {
        guard !s.allSatisfy(\.isASCII) else { return s }
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if (chunk + String(ch)).utf8.count > 45 {
                words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: " ")
    }

    /// Folds a header line at spaces to stay under 78 characters.
    static func fold(_ line: String) -> String {
        guard line.count > 78 else { return line }
        var out = ""
        var current = ""
        for token in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + token.count + 1 > 76 {
                out += current + "\r\n"
                current = " " + token
            } else {
                current += current.isEmpty ? String(token) : " " + token
            }
        }
        return out + current
    }

    static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    // MARK: Bodies

    /// Quoted-printable with CRLF line endings and soft breaks at 76 columns.
    static func quotedPrintable(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out = ""
        for (index, line) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { out += "\r\n" }
            var length = 0
            let bytes = Array(line.utf8)
            for (i, byte) in bytes.enumerated() {
                let isLast = i == bytes.count - 1
                var piece: String
                switch byte {
                case 33...60, 62...126: piece = String(UnicodeScalar(byte))
                case 32, 9: piece = isLast ? String(format: "=%02X", byte) : String(UnicodeScalar(byte)) // trailing space must be encoded
                default: piece = String(format: "=%02X", byte)
                }
                // A line starting with "." or "From " is safe for SMTP but encode "." to be robust.
                if length == 0, byte == 46 { piece = "=2E" }
                if length + piece.count > 75 {
                    out += "=\r\n"
                    length = 0
                }
                out += piece
                length += piece.count
            }
        }
        return out
    }
}
