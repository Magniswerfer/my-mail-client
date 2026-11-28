import Foundation

/// An email address with an optional display name.
public struct MailAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    public var name: String?
    public var address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }

    public var description: String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}

public struct AttachmentInfo: Sendable, Hashable, Codable {
    public var filename: String?
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
}

/// The parts of a message the engine needs (SPEC §3 tier 1).
public struct ParsedMessage: Sendable {
    public var headers: [(name: String, value: String)]
    public var subject: String
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: [String]
    public var references: [String]
    /// Best plain-text rendering of the body (text/plain, or HTML converted to text).
    public var plainText: String
    /// The HTML body, if the message has one.
    public var html: String?
    public var attachments: [AttachmentInfo]
    /// Decoded iCalendar documents (`text/calendar`, `application/ics`, `.ics` files).
    public var calendarParts: [String] = []
    /// What the message's reaction parts say, before any checks (see `reaction`): the body of an
    /// RFC 9078 `Content-Disposition: reaction` part, and the emoji of a Gmail
    /// `text/vnd.google.email-reaction+json` part.
    public var reactionParts = ReactionParts()

    /// The meeting invite, update, cancellation or reply this message carries, if any.
    public var invite: CalendarInvite? {
        calendarParts.lazy.compactMap(CalendarInvite.parse).first
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A small, forgiving RFC 5322 / MIME parser.
///
/// Real mail violates the RFCs constantly, so every step falls back instead of throwing:
/// an unknown charset becomes UTF-8 then Latin-1, a missing boundary becomes a single part,
/// a bad encoded-word is kept verbatim.
public enum MIMEParser {
    public static func parse(_ data: Data) -> ParsedMessage {
        let entity = Entity.parse([UInt8](data)[...])
        var body = BodyCollector()
        body.collect(entity)

        let plain = body.text ?? body.html.map(HTMLText.toPlainText) ?? ""
        func value(_ name: String) -> String? { entity.header(name) }
        return ParsedMessage(
            headers: entity.headers,
            subject: value("Subject").map { HeaderText.singleLine(EncodedWords.decode($0)) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            from: AddressParser.parse(value("From") ?? ""),
            to: AddressParser.parse(value("To") ?? ""),
            cc: AddressParser.parse(value("Cc") ?? ""),
            replyTo: AddressParser.parse(value("Reply-To") ?? ""),
            date: value("Date").flatMap(DateParser.parse),
            messageID: value("Message-ID").flatMap { MessageIDs.parse($0).first },
            inReplyTo: MessageIDs.parse(value("In-Reply-To") ?? ""),
            references: MessageIDs.parse(value("References") ?? ""),
            plainText: plain.trimmingCharacters(in: .whitespacesAndNewlines),
            html: body.html,
            attachments: body.attachments,
            calendarParts: body.calendars,
            reactionParts: body.reactions
        )
    }
}

/// Walks the entity tree and sorts each leaf into the readable body, an attachment, a calendar
/// or a reaction. The first text/plain and the first text/html win (so inside
/// multipart/alternative the plain part is the text, the HTML part the html).
struct BodyCollector {
    var text: String?
    var html: String?
    var attachments: [AttachmentInfo] = []
    var calendars: [String] = []
    var reactions = ReactionParts()

    mutating func collect(_ entity: Entity) {
        let type = entity.contentType
        if type.type == "multipart" {
            collectMultipart(entity)
            return
        }
        if type.type == "message", type.subtype == "rfc822" {
            // Forwarded message: count it as an attachment, don't merge its body.
            attachments.append(AttachmentInfo(
                filename: entity.filename ?? "forwarded.eml", mimeType: type.full,
                size: entity.body.count, contentID: nil, isInline: false))
            return
        }
        let isAttachment = entity.isAttachment
        if !isAttachment, collectReaction(entity, type: type) { return }
        if isCalendar(entity, type: type) {
            calendars.append(entity.decodedText)
            // The invite's own alternative part isn't a file; a real .ics attachment still is.
            if !isAttachment { return }
        }
        if !isAttachment, type.type == "text" {
            collectText(entity, subtype: type.subtype)
            return
        }
        attachments.append(AttachmentInfo(
            filename: entity.filename, mimeType: type.full, size: entity.decodedBody.count,
            contentID: entity.contentID, isInline: entity.disposition == "inline"))
    }

    private mutating func collectMultipart(_ entity: Entity) {
        guard !entity.children.isEmpty else {
            // Declared multipart but no boundary lines: show the raw body rather than nothing.
            if text == nil { text = Charsets.decode(Array(entity.body), charset: nil) }
            return
        }
        for child in entity.children { collect(child) }
    }

    /// Records a reaction part. True when the part is only machine-readable and needs no
    /// further handling.
    private mutating func collectReaction(_ entity: Entity, type: ContentType) -> Bool {
        if type.full == ReactionParts.gmailType {
            // Gmail's machine-readable reaction: not something to show or list as a file.
            if reactions.gmail == nil { reactions.gmail = ReactionParts.gmailEmoji(entity.decodedText) }
            return true
        }
        if entity.disposition == "reaction", type.type == "text", reactions.rfc9078 == nil {
            // RFC 9078: the body is the emoji. It stays the readable text too.
            reactions.rfc9078 = entity.decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return false
    }

    private func isCalendar(_ entity: Entity, type: ContentType) -> Bool {
        type.full == "text/calendar" || type.full == "application/ics"
            || entity.filename?.lowercased().hasSuffix(".ics") == true
    }

    /// A later text part of a kind already found (e.g. a second text/plain alternative) is dropped.
    private mutating func collectText(_ entity: Entity, subtype: String) {
        switch subtype {
        case "plain" where text == nil: text = entity.decodedText
        case "html" where html == nil: html = entity.decodedText
        default: break
        }
    }
}

// MARK: - Entities

struct ContentType {
    var type: String
    var subtype: String
    var parameters: [String: String]
    var full: String { "\(type)/\(subtype)" }

    static let defaultText = ContentType(type: "text", subtype: "plain", parameters: ["charset": "us-ascii"])

    static func parse(_ raw: String?) -> ContentType {
        guard let raw else { return defaultText }
        let (value, params) = HeaderParameters.parse(raw)
        let parts = value.lowercased().split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return ContentType(type: "text", subtype: "plain", parameters: params)
        }
        return ContentType(type: parts[0], subtype: parts[1], parameters: params)
    }
}

struct Entity {
    var headers: [(name: String, value: String)]
    var body: ArraySlice<UInt8>
    var children: [Entity] = []

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: ContentType { ContentType.parse(header("Content-Type")) }

    var disposition: String? {
        header("Content-Disposition").map { HeaderParameters.parse($0).value.lowercased() }
    }

    /// Has a filename or says `attachment`: a file, whatever its type.
    var isAttachment: Bool { disposition == "attachment" || filename != nil }

    var contentID: String? {
        header("Content-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
    }

    var filename: String? {
        if let d = header("Content-Disposition"), let name = HeaderParameters.parse(d).parameters["filename"] {
            return AttachmentNames.sanitize(EncodedWords.decode(name))
        }
        return contentType.parameters["name"].map { AttachmentNames.sanitize(EncodedWords.decode($0)) }
    }

    var decodedBody: [UInt8] {
        switch header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return Base64Lenient.decode(body)
        case "quoted-printable": return QuotedPrintable.decode(body, isHeader: false)
        default: return Array(body)
        }
    }

    /// Decoded text with line endings normalized to "\n" (the wire format is CRLF).
    var decodedText: String {
        Charsets.decode(decodedBody, charset: contentType.parameters["charset"])
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Deeper multipart nesting is left unparsed: real mail never gets close, and a crafted
    /// message could otherwise recurse without bound.
    static let maxMultipartDepth = 20

    static func parse(_ bytes: ArraySlice<UInt8>, depth: Int = 0) -> Entity {
        let (headerBytes, body) = splitHeader(bytes)
        var entity = Entity(headers: HeaderBlock.parse(headerBytes), body: body)
        let type = entity.contentType
        if type.type == "multipart", depth < maxMultipartDepth, let boundary = type.parameters["boundary"], !boundary.isEmpty {
            entity.children = Multipart.split(body, boundary: boundary).map { parse($0, depth: depth + 1) }
        }
        return entity
    }

    /// Splits at the first empty line (CRLF CRLF or LF LF).
    static func splitHeader(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var i = bytes.startIndex
        // A part that starts with a blank line has no headers.
        if bytes.starts(with: [13, 10]) { return (bytes[i..<i], bytes[(i + 2)...]) }
        if bytes.first == 10 { return (bytes[i..<i], bytes[(i + 1)...]) }
        while i < bytes.endIndex {
            if bytes[i] == 10 {
                let next = i + 1
                if next < bytes.endIndex, bytes[next] == 10 { return (bytes[..<i], bytes[(next + 1)...]) }
                if next + 1 < bytes.endIndex, bytes[next] == 13, bytes[next + 1] == 10 {
                    return (bytes[..<i], bytes[(next + 2)...])
                }
            }
            i += 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }
}

enum HeaderBlock {
    /// Unfolds and splits a header block. Header bytes are decoded as UTF-8 with a Latin-1 fallback
    /// (raw 8-bit headers are common in the wild).
    static func parse(_ bytes: ArraySlice<UInt8>) -> [(name: String, value: String)] {
        let text = Charsets.decode(Array(bytes), charset: "utf-8")
        var result: [(String, String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                if !result.isEmpty { result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            result.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return result
    }
}

enum Multipart {
    static func split(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var lineStart = body.startIndex
        var partStart: Int?
        var i = body.startIndex
        while i <= body.endIndex {
            if i == body.endIndex || body[i] == 10 {
                var line = body[lineStart..<i]
                if line.last == 13 { line = line.dropLast() }
                if line.starts(with: delimiter) {
                    let rest = line.dropFirst(delimiter.count)
                    if let start = partStart {
                        // Part ends before the CRLF that precedes the delimiter line.
                        var end = lineStart
                        if end > start, body[end - 1] == 10 { end -= 1 }
                        if end > start, body[end - 1] == 13 { end -= 1 }
                        parts.append(body[start..<max(start, end)])
                    }
                    if rest.starts(with: [45, 45]) { return parts } // closing "--"
                    partStart = min(i + 1, body.endIndex)
                }
                lineStart = i + 1
            }
            i += 1
        }
        if let start = partStart, start < body.endIndex { parts.append(body[start...]) } // unterminated
        return parts // empty when no delimiter was found; the caller treats the body as text
    }
}

// MARK: - Header values

enum HeaderParameters {
    /// Parses `value; key=val; key*=utf-8''enc%20oded; key*0=a; key*1=b`.
    static func parse(_ raw: String) -> (value: String, parameters: [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in raw {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\", inQuotes { escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == ";", !inQuotes { segments.append(current); current = ""; continue }
            current.append(ch)
        }
        segments.append(current)
        let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""

        var simple: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((n, val, extended))
            } else if extended {
                simple[key] = decodeRFC2231(val, hasCharset: true)
            } else {
                simple[key] = val
            }
        }
        for (key, pieces) in continuations {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            // The charset is named once, on the first piece, and a character's bytes may span
            // pieces (RFC 2231 §4.1): join the bytes, then decode them together.
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (index, piece) in sorted.enumerated() {
                guard piece.2 else { bytes += Array(piece.1.utf8); continue }
                let decoded = percentDecoded(piece.1, hasCharset: index == 0)
                if let named = decoded.charset { charset = named }
                bytes += decoded.bytes
            }
            simple[key] = Charsets.decode(bytes, charset: charset)
        }
        return (value, simple)
    }

    /// `utf-8'da'Faktura%20%C3%A6.pdf` → `Faktura æ.pdf`.
    static func decodeRFC2231(_ value: String, hasCharset: Bool) -> String {
        let decoded = percentDecoded(value, hasCharset: hasCharset)
        return Charsets.decode(decoded.bytes, charset: decoded.charset ?? "utf-8")
    }

    /// The bytes of an extended value, and the charset its `charset'lang'` prefix names.
    static func percentDecoded(_ value: String, hasCharset: Bool) -> (bytes: [UInt8], charset: String?) {
        var charset: String?
        var encoded = Substring(value)
        if hasCharset {
            let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                if !pieces[0].isEmpty { charset = String(pieces[0]) }
                encoded = pieces[2]
            }
        }
        var bytes: [UInt8] = []
        var i = encoded.startIndex
        while i < encoded.endIndex {
            if encoded[i] == "%", let hi = encoded.index(i, offsetBy: 3, limitedBy: encoded.endIndex),
               let byte = UInt8(encoded[encoded.index(after: i)..<hi], radix: 16) {
                bytes.append(byte)
                i = hi
            } else {
                bytes.append(contentsOf: Array(String(encoded[i]).utf8))
                i = encoded.index(after: i)
            }
        }
        return (bytes, charset)
    }
}

/// RFC 2047 encoded words: `=?utf-8?Q?M=C3=B8de?=`, `=?iso-8859-1?B?...?=`.
public enum EncodedWords {
    static let encodedWord = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)

    public static func decode(_ input: String) -> String {
        guard input.contains("=?"), let regex = encodedWord else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var output = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between adjacent encoded words is dropped (RFC 2047 §6.2).
            if !(previousWasEncoded && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                output += gap
            }
            var charset = ns.substring(with: match.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language
            let encoding = ns.substring(with: match.range(at: 2)).lowercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes: [UInt8] = encoding == "b"
                ? Base64Lenient.decode(ArraySlice(Array(text.utf8)))
                : QuotedPrintable.decode(ArraySlice(Array(text.utf8)), isHeader: true)
            // Decoded words may carry CR/LF (=0D=0A); a header value never spans lines.
            output += HeaderText.singleLine(Charsets.decode(bytes, charset: charset))
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        output += ns.substring(from: cursor)
        return output
    }
}

enum MessageIDs {
    /// Extracts `<id>` tokens; also accepts bare ids (seen in broken In-Reply-To headers).
    static func parse(_ raw: String) -> [String] {
        var ids: [String] = []
        var scanner = raw[...]
        while let open = scanner.firstIndex(of: "<") {
            guard let close = scanner[open...].firstIndex(of: ">") else { break }
            let id = scanner[scanner.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ids.append(id) }
            scanner = scanner[scanner.index(after: close)...]
        }
        if ids.isEmpty {
            let bare = raw.trimmingCharacters(in: .whitespaces)
            if bare.contains("@"), !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }
}

public enum AddressParser {
    public static func parse(_ raw: String) -> [MailAddress] {
        var result: [MailAddress] = []
        for item in splitList(raw) {
            var entry = item.trimmingCharacters(in: .whitespaces)
            // Group syntax: "Team: a@x, b@y;" — keep the members.
            if let colon = entry.firstIndex(of: ":"), !entry[..<colon].contains("<"), !entry[..<colon].contains("@") {
                entry = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
                if entry.isEmpty { continue }
            }
            if let open = entry.lastIndex(of: "<"), let close = entry[open...].firstIndex(of: ">") {
                let address = entry[entry.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = entry[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                name = HeaderText.singleLine(EncodedWords.decode(name)).trimmingCharacters(in: .whitespaces)
                let clean = HeaderText.token(address)
                if !clean.isEmpty { result.append(MailAddress(name: name.isEmpty ? nil : name, address: clean)) }
            } else {
                // "addr (Comment Name)" or bare address.
                var address = entry
                var name: String?
                if let open = entry.firstIndex(of: "("), let close = entry.lastIndex(of: ")"), open < close {
                    name = HeaderText.singleLine(EncodedWords.decode(String(entry[entry.index(after: open)..<close])))
                    address = entry[..<open].trimmingCharacters(in: .whitespaces)
                }
                address = HeaderText.token(address)
                if address.contains("@") { result.append(MailAddress(name: name, address: address)) }
            }
        }
        return result
    }

    /// Splits on commas outside quotes, angle brackets and comments.
    static func splitList(_ raw: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var paren = 0
        for ch in raw {
            switch ch {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: angle += 1
            case ">" where !inQuotes: angle = max(0, angle - 1)
            case "(" where !inQuotes: paren += 1
            case ")" where !inQuotes: paren = max(0, paren - 1)
            case "," where !inQuotes && angle == 0 && paren == 0:
                items.append(current); current = ""; continue
            default: break
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(current) }
        return items
    }
}

public enum DateParser {
    static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
    ]

    nonisolated(unsafe) static let formatters: [DateFormatter] = formats.map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = $0
        return f
    }
    static let lock = NSLock()

    public static func parse(_ raw: String) -> Date? {
        // Drop trailing comments like "(CET)" and collapse whitespace.
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lock.lock(); defer { lock.unlock() }
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Transfer encodings and charsets

enum Base64Lenient {
    /// Decodes base64, ignoring whitespace and junk, tolerating missing padding.
    static func decode(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var clean: [UInt8] = []
        clean.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case 65...90, 97...122, 48...57, 43, 47: clean.append(b)
            case 45: clean.append(43)   // base64url "-" → "+"
            case 95: clean.append(47)   // base64url "_" → "/"
            default: continue
            }
        }
        while clean.count % 4 != 0 { clean.append(61) }
        return Data(base64Encoded: Data(clean)).map { [UInt8]($0) } ?? []
    }
}

enum QuotedPrintable {
    static func decode(_ bytes: ArraySlice<UInt8>, isHeader: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 61 { // "="
                let n1 = i + 1, n2 = i + 2
                if n1 < bytes.endIndex, bytes[n1] == 10 { i += 2; continue }                       // soft break LF
                if n2 < bytes.endIndex, bytes[n1] == 13, bytes[n2] == 10 { i += 3; continue }     // soft break CRLF
                if n2 < bytes.endIndex, let h = hex(bytes[n1]), let l = hex(bytes[n2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
                out.append(b); i += 1; continue
            }
            if isHeader, b == 95 { out.append(32); i += 1; continue } // "_" is space in Q-encoding
            out.append(b)
            i += 1
        }
        return out
    }
}

enum Charsets {
    static func decode(_ bytes: [UInt8], charset: String?) -> String {
        let name = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        if name == "utf-8" || name == "utf8" || name == "us-ascii" || name == "ascii" {
            if let s = String(bytes: bytes, encoding: .utf8) { return s }
            return String(bytes: bytes, encoding: .windowsCP1252) ?? latin1(bytes)
        }
        #if canImport(Darwin)
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            // Mislabelled ISO-8859-1 is usually Windows-1252 in practice.
            let effective: String.Encoding = encoding == .isoLatin1 ? .windowsCP1252 : encoding
            if let s = String(bytes: bytes, encoding: effective) { return s }
        }
        #else
        // No CoreFoundation charset table off Apple platforms (ADR 0007): glibc's iconv knows
        // the IANA names. Mislabelled ISO-8859-1 is usually Windows-1252 in practice.
        let effective = (name == "iso-8859-1" || name == "latin1" || name == "iso_8859-1") ? "windows-1252" : name
        if let s = Iconv.decode(bytes, from: effective) { return s }
        #endif
        return String(bytes: bytes, encoding: .utf8) ?? latin1(bytes)
    }

    static func latin1(_ bytes: [UInt8]) -> String { String(bytes.map { Character(Unicode.Scalar($0)) }) }
}

// MARK: - HTML to text

public enum HTMLText {
    /// Converts an HTML body to readable plain text for indexing, previews and AI.
    /// Not a renderer: drops scripts/styles/head, keeps paragraph and list structure.
    public static func toPlainText(_ html: String) -> String {
        // Forward-only scans and `[^<>]` classes: each regex start stops at the next `<`, so an
        // unclosed tag can't make the pass quadratic (one crafted mail would stall sync).
        var s = HTMLScan.removingComments(from: html)
        s = HTMLScan.removingElements(["script", "style", "head", "title"], from: s)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li\\b[^<>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|tr|h[1-6]|table|ul|ol|blockquote)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh]>", with: "\t", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^<>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Normalise whitespace: trim lines, collapse runs of blank lines and spaces.
        let lines = s.components(separatedBy: .newlines).map {
            // Literal tab and no-break space: Linux's regex engine misreads the `\u{…}` escape (ADR 0007).
            $0.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "aelig": "æ", "AElig": "Æ",
        "oslash": "ø", "Oslash": "Ø", "aring": "å", "Aring": "Å", "eacute": "é", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "szlig": "ß", "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—",
        "ndash": "–", "laquo": "«", "raquo": "»", "euro": "€", "zwnj": "", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "bull": "•", "middot": "·",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = s[s.index(after: i)..<semi]
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[String(entity)]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

extension MIMEParser {
    /// The attachments of a raw message with their contents, for forwarding.
    public static func attachments(in data: Data) -> [OutgoingAttachment] {
        var result: [OutgoingAttachment] = []
        func walk(_ entity: Entity) {
            let type = entity.contentType
            if type.type == "multipart" { entity.children.forEach(walk); return }
            let contentID = entity.contentID
            // Inline images are often just a part with a Content-ID (no filename, no disposition).
            let isInlineResource = contentID != nil && entity.disposition != "attachment" && type.type != "text"
            guard entity.isAttachment || isInlineResource else { return }
            result.append(OutgoingAttachment(
                filename: entity.filename ?? "attachment", mimeType: type.full, data: Data(entity.decodedBody),
                contentID: entity.disposition == "attachment" ? nil : contentID))
        }
        walk(Entity.parse([UInt8](data)[...]))
        return result
    }
}
