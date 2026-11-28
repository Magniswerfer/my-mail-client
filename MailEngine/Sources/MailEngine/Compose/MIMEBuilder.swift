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
/// filenames), so it passes any SMTP server without 8BITMIME or SMTPUTF8. Every line stays
/// within 78 characters, and nothing the user typed can break out of its header (CR/LF in a
/// subject, name or filename becomes a space).
///
/// The body is shaped the way Apple Mail, Gmail and Outlook send it themselves:
///
///     multipart/mixed                      (only with attachments)
///       multipart/alternative
///         text/plain
///         multipart/related; type="text/html"   (only with inline images)
///           text/html
///           image/png (Content-ID)
///         text/calendar; method=…               (only for invite replies)
///       application/pdf (attachment)
public enum MIMEBuilder {
    public static func build(_ m: OutgoingMessage, userAgent: String = "Tidings") -> Data {
        var headers: [String] = [
            "Date: \(rfc5322Date(m.date))",
            "From: \(address(m.from))",
        ]
        if !m.to.isEmpty { headers.append("To: \(m.to.map(address).joined(separator: ", "))") }
        if !m.cc.isEmpty { headers.append("Cc: \(m.cc.map(address).joined(separator: ", "))") }
        if m.to.isEmpty, m.cc.isEmpty {
            // Bcc only: an empty group keeps the message well-formed without naming anyone
            // (RFC 5322 §3.6.3), and spam filters don't flag a missing To.
            headers.append("To: undisclosed-recipients:;")
        }
        headers.append("Subject: \(encodeText(clean(m.subject)))")
        headers.append("Message-ID: <\(messageID(m.messageID))>")
        if let parent = m.inReplyTo.map(messageID), !parent.isEmpty { headers.append("In-Reply-To: <\(parent)>") }
        let references = m.references.map(messageID).filter { !$0.isEmpty }
        if !references.isEmpty { headers.append("References: \(references.map { "<\($0)>" }.joined(separator: " "))") }
        headers.append("MIME-Version: 1.0")
        headers.append("User-Agent: \(clean(userAgent))")

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

    static func textPart(_ subtype: String, _ content: String, extra: String = "") -> Part {
        Part(headers: ["Content-Type: text/\(subtype); charset=utf-8\(extra)", "Content-Transfer-Encoding: quoted-printable"],
             content: quotedPrintable(content))
    }

    static func bodyPart(_ m: OutgoingMessage) -> Part {
        if let reaction = m.reaction { return reactionPart(reaction) }
        // Inline (cid:) images only mean something next to the HTML that shows them.
        let inline = m.html == nil ? [] : m.attachments.filter { $0.contentID != nil }
        let regular = m.attachments.filter { m.html == nil || $0.contentID == nil }

        var alternatives = [textPart("plain", m.text)]
        if let html = m.html {
            let htmlPart = textPart("html", html)
            // The images belong to the HTML, not to the text alternative beside it (RFC 2387).
            alternatives.append(inline.isEmpty ? htmlPart
                : multipart("related", [htmlPart] + inline.map(attachmentPart), parameters: "; type=\"text/html\""))
        }
        if let calendar = m.calendar {
            // iTIP over email (RFC 6047): the calendar is an alternative of the text, with the
            // method repeated on the Content-Type so clients don't have to parse it.
            alternatives.append(textPart("calendar", calendar.ics, extra: "; method=\(calendar.method.rawValue)"))
        }
        var main = alternatives.count == 1 ? alternatives[0] : multipart("alternative", alternatives)
        if !regular.isEmpty {
            main = multipart("mixed", [main] + regular.map(attachmentPart))
        }
        return main
    }

    static func multipart(_ subtype: String, _ parts: [Part], parameters: String = "") -> Part {
        // "=_" can't occur in quoted-printable or base64 output, so the boundary never collides.
        let boundary = "=_tidings_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24))"
        var content = ""
        for part in parts {
            content += "--\(boundary)\r\n" + part.serialized + "\r\n"
        }
        content += "--\(boundary)--\r\n"
        return Part(headers: ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\(parameters)"].map(fold), content: content)
    }

    static func attachmentPart(_ a: OutgoingAttachment) -> Part {
        let filename = clean(a.filename).trimmingCharacters(in: .whitespaces)
        let name = filename.isEmpty ? "attachment" : filename
        let ascii = name.allSatisfy { $0.isASCII && $0 != "\"" && $0 != "\\" }
        let disposition = a.contentID == nil ? "attachment" : "inline"
        let simple = "Content-Disposition: \(disposition); filename=\"\(name)\""
        let dispositionHeader = ascii && simple.count <= 78
            ? simple
            : "Content-Disposition: \(disposition);\r\n" + rfc2231("filename", name)
        var headers = [
            // `name=` is for clients that predate Content-Disposition; RFC 2047 inside the quotes
            // is what every client sends and reads there.
            fold("Content-Type: \(mimeType(a.mimeType)); name=\"\(ascii ? name : encodeHeader(name))\""),
            dispositionHeader,
            "Content-Transfer-Encoding: base64",
        ]
        if let cid = a.contentID.map(messageID), !cid.isEmpty { headers.append("Content-ID: <\(cid)>") }
        let base64 = a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Part(headers: headers, content: base64.isEmpty ? "" : base64 + "\r\n")
    }

    /// An RFC 2231 extended parameter: percent-encoded UTF-8, split into numbered continuations
    /// (`filename*0*=utf-8''…; filename*1*=…`) so no line goes past 78 characters.
    static func rfc2231(_ attribute: String, _ value: String) -> String {
        var chunks: [String] = []
        var current = ""
        // Split between characters, never inside one's UTF-8 bytes: some clients decode each
        // continuation on its own.
        for ch in value {
            let piece = String(ch).addingPercentEncoding(withAllowedCharacters: rfc2231Safe) ?? "_"
            if !current.isEmpty, current.count + piece.count > 54 { chunks.append(current); current = "" }
            current += piece
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
        if chunks.count == 1 { return " \(attribute)*=utf-8''\(chunks[0])" }
        return chunks.enumerated().map { i, chunk in
            " \(attribute)*\(i)*=" + (i == 0 ? "utf-8''" : "") + chunk + (i == chunks.count - 1 ? "" : ";")
        }.joined(separator: "\r\n")
    }

    /// attribute-char (RFC 2231): ASCII letters, digits and the token punctuation, unescaped.
    static let rfc2231Safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    /// A Content-Type that is a well-formed `type/subtype`, or application/octet-stream.
    static func mimeType(_ raw: String) -> String {
        let type = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        let parts = type.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(token.contains) }) else {
            return "application/octet-stream"
        }
        return type
    }

    // MARK: Headers

    /// Header text as one line: CR, LF and other control characters (the way to inject a
    /// header) become spaces.
    static func clean(_ s: String) -> String {
        let unified = s.replacingOccurrences(of: "\r\n", with: " ")
        return String(String.UnicodeScalarView(unified.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
        }))
    }

    /// A Message-ID's inside (no angle brackets, no whitespace).
    static func messageID(_ s: String) -> String {
        String(clean(s).filter { !$0.isWhitespace && $0 != "<" && $0 != ">" })
    }

    static func address(_ a: MailAddress) -> String {
        let addr = messageID(a.address)
        guard let raw = a.name, case let name = clean(raw).trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name != addr else { return addr }
        if !name.allSatisfy(\.isASCII) || name.contains("=?") { return "\(encodeHeader(name, force: true)) <\(addr)>" }
        let needsQuotes = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return needsQuotes ? "\"\(escaped)\" <\(addr)>" : "\(name) <\(addr)>"
    }

    /// RFC 2047 B-encoding for non-ASCII header text, split so each encoded word stays short
    /// (64 characters at most, room to sit in a folded line or a quoted parameter) and never
    /// cuts a UTF-8 sequence. ASCII text goes as is, unless it looks like an encoded
    /// word itself ("=?…?="), which a client would otherwise decode.
    public static func encodeHeader(_ s: String) -> String { encodeHeader(s, force: false) }

    static func encodeHeader(_ s: String, force: Bool) -> String {
        guard force || !s.allSatisfy(\.isASCII) || s.contains("=?") else { return s }
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if !chunk.isEmpty, (chunk + String(ch)).utf8.count > 39 {
                words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: " ")
    }

    /// Unstructured header text (a subject) the way Apple Mail and Gmail write it: plain
    /// words stay readable, and only runs of words that need it become encoded words: Q for
    /// mostly-Latin text ("Re: =?utf-8?Q?M=C3=B8de?= i morgen"), B for emoji and other scripts.
    static func encodeText(_ s: String) -> String {
        func needsEncoding(_ word: Substring) -> Bool { !word.allSatisfy(\.isASCII) || word.contains("=?") }
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        guard words.contains(where: needsEncoding) else { return s }
        var out: [String] = []
        var run: [Substring] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(encodedWords(run.joined(separator: " ")))
            run = []
        }
        for word in words {
            if needsEncoding(word) { run.append(word) } else { flush(); out.append(String(word)) }
        }
        flush()
        return out.joined(separator: " ")
    }

    /// `text` as encoded words of at most 64 characters each, never cutting a character.
    static func encodedWords(_ text: String) -> String {
        let qSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!*+-/".utf8)
        func q(_ ch: Character) -> String {
            String(ch).utf8.map { byte in
                byte == 32 ? "_" : qSafe.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
            }.joined()
        }
        let qLength = text.reduce(0) { $0 + q($1).count }
        // Q keeps mostly-Latin text legible; B is far shorter for emoji and non-Latin scripts.
        let bLength = (text.utf8.count + 2) / 3 * 4
        let useQ = qLength <= bLength * 3 / 2
        let budget = 64 - "=?utf-8?Q??=".count
        var words: [String] = []
        var chunk = ""
        var chunkBytes = Data()
        func emit() {
            guard !chunk.isEmpty || !chunkBytes.isEmpty else { return }
            words.append(useQ ? "=?utf-8?Q?\(chunk)?=" : "=?utf-8?B?\(chunkBytes.base64EncodedString())?=")
            chunk = ""; chunkBytes = Data()
        }
        for ch in text {
            let bytes = Data(String(ch).utf8)
            let fits = useQ ? chunk.count + q(ch).count <= budget : (chunkBytes.count + bytes.count + 2) / 3 * 4 <= budget
            if !fits { emit() }
            if useQ { chunk += q(ch) }
            chunkBytes += bytes
        }
        emit()
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
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    // MARK: Bodies

    /// Quoted-printable with CRLF line endings and soft breaks at 76 columns.
    ///
    /// A line (or soft-broken piece) never starts with "." or "From ": the first is SMTP's
    /// end-of-data marker, the second gets rewritten to ">From " by mbox delivery, which
    /// changes the body and breaks the DKIM signature.
    static func quotedPrintable(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let from = Array("From ".utf8)
        var out = ""
        for (index, line) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { out += "\r\n" }
            var length = 0
            let bytes = Array(line.utf8)
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                let isLast = i == bytes.count - 1
                var piece: String
                switch byte {
                case 33...60, 62...126: piece = String(UnicodeScalar(byte))
                case 32, 9: piece = isLast ? String(format: "=%02X", byte) : String(UnicodeScalar(byte)) // trailing space must be encoded
                default: piece = String(format: "=%02X", byte)
                }
                if length + piece.count > 75 {
                    out += "=\r\n"
                    length = 0
                }
                if length == 0 {
                    if byte == 46 { piece = "=2E" }
                    if byte == 70, bytes[i...].starts(with: from) { piece = "=46" }
                }
                out += piece
                length += piece.count
                i += 1
            }
        }
        return out
    }
}
