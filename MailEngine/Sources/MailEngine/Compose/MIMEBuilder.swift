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
    /// RFC 5322 §2.1.1: lines SHOULD stay within 78 characters.
    static let maxHeaderLineLength = 78
    /// Folded continuation lines are kept a little shorter so the leading space still fits.
    static let foldedLineLength = 76
    /// RFC 2045 §6.7: an encoded line is at most 76 characters, the soft-break "=" included.
    static let maxQuotedPrintableLineLength = 75
    /// UTF-8 bytes per RFC 2047 encoded word, so the word stays under 75 characters once base64'd.
    static let maxEncodedWordBytes = 45

    public static func build(_ m: OutgoingMessage, userAgent: String = "Tidings") -> Data {
        var headers: [String] = [
            "From: \(address(m.from))",
            "Date: \(rfc5322Date(m.date))",
            "Message-ID: \(angleBracketed(m.messageID))",
            "Subject: \(encodeHeader(m.subject))",
        ]
        if !m.to.isEmpty { headers.append("To: \(addressList(m.to))") }
        if !m.cc.isEmpty { headers.append("Cc: \(addressList(m.cc))") }
        if let parent = m.inReplyTo { headers.append("In-Reply-To: \(angleBracketed(parent))") }
        if !m.references.isEmpty { headers.append("References: \(m.references.map(angleBracketed).joined(separator: " "))") }
        headers.append("MIME-Version: 1.0")
        headers.append("User-Agent: \(singleLine(userAgent))")

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

        static func quotedPrintableText(_ text: String, contentType: String, extraHeaders: [String] = []) -> Part {
            Part(headers: ["Content-Type: \(contentType)"] + extraHeaders + ["Content-Transfer-Encoding: quoted-printable"],
                 content: quotedPrintable(text))
        }
    }

    /// The structure, innermost first: text (+ HTML, + iTIP calendar) as alternatives, inline
    /// images around that as `related`, regular attachments around everything as `mixed`.
    static func bodyPart(_ m: OutgoingMessage) -> Part {
        if let reaction = m.reaction { return reactionPart(reaction) }
        var alternatives = [Part.quotedPrintableText(m.text, contentType: "text/plain; charset=utf-8")]
        if let html = m.html {
            alternatives.append(.quotedPrintableText(html, contentType: "text/html; charset=utf-8"))
        }
        if let calendar = m.calendar {
            // iTIP over email (RFC 6047): the calendar is an alternative of the text, with the
            // method repeated on the Content-Type so clients don't have to parse it.
            alternatives.append(.quotedPrintableText(
                calendar.ics, contentType: "text/calendar; charset=utf-8; method=\(calendar.method.rawValue)"))
        }
        var main = alternatives.count == 1 ? alternatives[0] : multipart("alternative", alternatives)
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
        let filename = singleLine(a.filename)
        let isPlainQuotable = filename.allSatisfy { $0.isASCII && $0 != "\"" && $0 != "\\" }
        let dispositionName = isPlainQuotable
            ? "filename=\"\(filename)\""
            : "filename*=utf-8''\(filename.addingPercentEncoding(withAllowedCharacters: rfc2231Safe) ?? "attachment")"
        var headers = [
            fold("Content-Type: \(singleLine(a.mimeType)); name=\"\(isPlainQuotable ? filename : encodeHeader(filename))\""),
            fold("Content-Disposition: \(a.contentID == nil ? "attachment" : "inline"); \(dispositionName)"),
            "Content-Transfer-Encoding: base64",
        ]
        if let cid = a.contentID { headers.append("Content-ID: \(angleBracketed(cid))") }
        return Part(headers: headers, content: a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n")
    }

    /// RFC 2231 `attr-char`: ASCII letters, digits and the few symbols allowed unencoded.
    static let rfc2231Safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")

    // MARK: Headers

    /// Header text can come from received mail (a forwarded attachment's decoded filename, a
    /// reply's subject), where an encoded word may hide a line break. A raw CR or LF would end
    /// the header and let the sender inject headers or body into our message, so they become spaces.
    static func singleLine(_ s: String) -> String {
        func isLineBreak(_ c: Character) -> Bool { c.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }
        guard s.contains(where: isLineBreak) else { return s }
        return String(s.map { isLineBreak($0) ? " " : $0 })
    }

    static func angleBracketed(_ id: String) -> String { "<\(singleLine(id))>" }

    static func addressList(_ addresses: [MailAddress]) -> String { addresses.map(address).joined(separator: ", ") }

    static func address(_ a: MailAddress) -> String {
        let mailbox = angleBracketed(a.address)
        guard let name = a.name.map(singleLine), !name.isEmpty else { return singleLine(a.address) }
        if !name.allSatisfy(\.isASCII) { return "\(encodeHeader(name)) \(mailbox)" }
        let needsQuotes = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return needsQuotes ? "\"\(escaped)\" \(mailbox)" : "\(name) \(mailbox)"
    }

    /// RFC 2047 B-encoding for non-ASCII header text, split so each encoded word stays short
    /// and never cuts a UTF-8 sequence. Line breaks become spaces (see `singleLine`).
    public static func encodeHeader(_ s: String) -> String {
        let s = singleLine(s)
        guard !s.allSatisfy(\.isASCII) else { return s }
        func encodedWord(_ chunk: String) -> String { "=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=" }
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if chunk.utf8.count + String(ch).utf8.count > maxEncodedWordBytes {
                words.append(encodedWord(chunk))
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(encodedWord(chunk)) }
        return words.joined(separator: " ")
    }

    static func fold(_ line: String) -> String {
        guard line.count > maxHeaderLineLength else { return line }
        var out = ""
        var current = ""
        for token in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + token.count + 1 > foldedLineLength {
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
                var piece = quotedPrintablePiece(byte, isLastOnLine: i == bytes.count - 1)
                // SMTP dot-stuffing would cover a leading "." too; encoding it keeps the body intact
                // through relays that get that wrong.
                if length == 0, byte == UInt8(ascii: ".") { piece = "=2E" }
                if length + piece.count > maxQuotedPrintableLineLength {
                    out += "=\r\n"
                    length = 0
                }
                out += piece
                length += piece.count
            }
        }
        return out
    }

    /// RFC 2045 §6.7: printable ASCII except "=" stays literal; a space or tab only when it
    /// isn't the last character of the line (trailing whitespace is stripped in transit).
    static func quotedPrintablePiece(_ byte: UInt8, isLastOnLine: Bool) -> String {
        let isLiteral = (33...60).contains(byte) || (62...126).contains(byte)
        let isInnerWhitespace = (byte == 32 || byte == 9) && !isLastOnLine
        return isLiteral || isInnerWhitespace ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
    }
}
