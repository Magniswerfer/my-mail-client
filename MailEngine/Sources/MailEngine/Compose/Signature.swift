import Foundation

// MARK: - Signatures

/// An image that travels inside the message (a `cid:` part), not fetched from the web.
public struct SignatureImage: Codable, Sendable, Hashable {
    /// Referenced from the signature's HTML as `cid:<contentID>`.
    public var contentID: String
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(contentID: String = SignatureImage.newContentID(), filename: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    /// Signature images are recognisable by their Content-ID, so a draft reopened doesn't take
    /// them for attachments you added.
    public static let contentIDPrefix = "sig-"

    public static func newContentID() -> String { "\(contentIDPrefix)\(UUID().uuidString.lowercased())@tidings" }

    public var dataURI: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

/// A signature: HTML (inline styles, as mail wants it), its embedded images, and the text the
/// plain-text part gets.
public struct Signature: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// A fragment (no <html>/<body>); embedded images as `cid:`, others as http(s) links.
    public var html: String
    public var images: [SignatureImage]
    /// The plain-text version you wrote; nil: made from the HTML.
    public var customPlainText: String?

    public init(id: String = UUID().uuidString, name: String, html: String, images: [SignatureImage] = [],
                customPlainText: String? = nil) {
        self.id = id
        self.name = name
        self.html = html
        self.images = images
        self.customPlainText = customPlainText
    }

    /// A signature made from plain text (the kind Tidings had before HTML signatures). The id
    /// follows from the text, so two devices converting the same signature agree.
    public static func fromPlainText(_ text: String, name: String) -> Signature {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = trimmed.components(separatedBy: "\n").map(SignatureHTML.escape).joined(separator: "<br>")
        return Signature(id: "text-\(SignatureHTML.stableHash(trimmed))", name: name, html: "<div>\(html)</div>",
                         customPlainText: trimmed)
    }

    /// What the plain-text part says (without the "-- " line).
    public var plainText: String {
        if let customPlainText, !customPlainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return customPlainText }
        return SignatureHTML.plainText(html)
    }

    /// The signature in the plain-text part: after the standard "-- " separator line (RFC 3676),
    /// which mail programs (Tidings' send check too) recognise as where the signature starts.
    public var textBlock: String { "-- \n" + plainText }

    /// The signature in the HTML part.
    public var htmlBlock: String { "<div class=\"tidings-signature\">\(html)</div>" }

    /// Its embedded images that the HTML uses, as inline parts of a message.
    public var inlineAttachments: [OutgoingAttachment] {
        let used = SignatureHTML.contentIDs(in: html)
        return images.filter { used.contains($0.contentID) }.map {
            OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data, contentID: $0.contentID)
        }
    }

    /// The HTML with embedded images as data: URIs, to show (or edit) without the message around it.
    public var displayHTML: String { SignatureHTML.inliningImages(html, images) }

    /// Bytes it takes when stored and synced (images included).
    public var storedSize: Int { html.utf8.count + (customPlainText?.utf8.count ?? 0) + images.reduce(0) { $0 + $1.data.count } }

    /// A synced record is at most 1 MB in iCloud and base64 grows images by a third: past this
    /// a signature wouldn't sync, so the editor asks for smaller images.
    public static let maxStoredSize = 600_000
}

extension OutgoingMessage {
    /// Adds the inline image parts of the signatures the HTML uses (once each). Signature parts
    /// already there (a draft built before) are replaced.
    public mutating func addSignatureImages(_ signatures: [Signature]) {
        attachments.removeAll { $0.contentID?.hasPrefix(SignatureImage.contentIDPrefix) == true }
        let used = html.map(SignatureHTML.contentIDs) ?? []
        var seen = Set<String>()
        for signature in signatures {
            for part in signature.inlineAttachments where used.contains(part.contentID ?? "") && seen.insert(part.contentID ?? "").inserted {
                attachments.append(part)
            }
        }
    }
}

// MARK: - HTML

/// Cleaning up, converting and reading signature HTML. String-based (no WebKit), so it works on
/// Linux too.
public enum SignatureHTML {
    /// Takes what you pasted or imported down to what a signature can be: the body's content,
    /// without scripts, forms, frames, event handlers or `javascript:` links. Inline styles,
    /// tables, links and images stay.
    public static func sanitize(_ html: String) -> String {
        var s = html
        if let body = s.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[body.upperBound...])
            if let end = s.range(of: "</body>", options: [.caseInsensitive, .backwards]) { s = String(s[..<end.lowerBound]) }
        }
        for tag in ["script", "style", "head", "title", "iframe", "object", "embed", "form", "noscript", "template", "svg"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        // Tags that stand alone (or were left unclosed) and don't belong in a body.
        s = s.replacingOccurrences(of: "</?(html|body|meta|link|base|script|style|iframe|object|embed|form|input|button|select|textarea|frame|frameset)\\b[^>]*>",
                                   with: "", options: [.regularExpression, .caseInsensitive])
        // Event handlers and scripted links.
        s = s.replacingOccurrences(of: #"\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"(href|src)\s*=\s*(["']?)\s*(javascript|vbscript):[^"'>]*\2"#, with: "$1=\"#\"",
                                   options: [.regularExpression, .caseInsensitive])
        // Editing leftovers.
        s = s.replacingOccurrences(of: #"\s+contenteditable\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text for the text/plain part: one line per line of the signature, no blank runs,
    /// links written out where the text doesn't already say where they go.
    public static func plainText(_ html: String) -> String {
        var s = html
        // Links: "text <url>" unless the text is the address.
        s = replacing(in: s, pattern: #"<a\b[^>]*>([\s\S]*?)</a\s*>"#) { tag in
            let inner = tag.replacingOccurrences(of: #"^<a\b[^>]*>|</a\s*>$"#, with: "", options: [.regularExpression, .caseInsensitive])
            let text = HTMLText.toPlainText(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let href = attribute("href", in: tag), !text.isEmpty else { return inner }
            let target = HTMLText.decodeEntities(href)
            return linkMentioned(text: text, href: target) ? inner : "\(inner) &lt;\(escape(target))&gt;"
        }
        let text = HTMLText.toPlainText(s)
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whether the link's text already tells where it goes ("creativeoak.io" for
    /// https://creativeoak.io/, the address of a mailto:, the number of a tel:).
    static func linkMentioned(text: String, href: String) -> Bool {
        func bare(_ s: String) -> String {
            var t = s.lowercased()
            for prefix in ["mailto:", "tel:", "https://", "http://", "www."] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
            if let q = t.firstIndex(where: { $0 == "?" }) { t = String(t[..<q]) }
            while t.hasSuffix("/") { t.removeLast() }
            return t.filter { !$0.isWhitespace && $0 != "-" }
        }
        let target = bare(href)
        guard !target.isEmpty, !href.hasPrefix("#") else { return true }
        return bare(text) == target || bare(text).hasPrefix(target) || target.hasPrefix(bare(text)) && bare(text).contains(".")
    }

    /// The `cid:` references in the HTML.
    public static func contentIDs(in html: String) -> Set<String> {
        var ids = Set<String>()
        for match in matches(in: html, pattern: #"["'(]\s*cid:([^"')\s]+)"#) { ids.insert(match) }
        return ids
    }

    /// Embedded images as data: URIs (for a preview or the editor).
    public static func inliningImages(_ html: String, _ images: [SignatureImage]) -> String {
        var s = html
        for image in images { s = s.replacingOccurrences(of: "cid:\(image.contentID)", with: image.dataURI) }
        return s
    }

    /// The other way: data: images become embedded images referenced as `cid:`. Images already
    /// in `existing` with the same bytes keep their Content-ID. Returns only the images the HTML
    /// uses.
    public static func extractingImages(_ html: String, existing: [SignatureImage] = []) -> (html: String, images: [SignatureImage]) {
        var images: [SignatureImage] = []
        var counter = 0
        let out = replacing(in: html, pattern: #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+"#) { uri in
            guard let comma = uri.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]).filter { !$0.isWhitespace }) else { return uri }
            let mime = String(uri.dropFirst("data:".count).prefix { $0 != ";" }).lowercased()
            if let known = (images + existing).first(where: { $0.data == data }) {
                if !images.contains(known) { images.append(known) }
                return "cid:\(known.contentID)"
            }
            counter += 1
            let ext = mime.split(separator: "/").last.map { $0 == "jpeg" ? "jpg" : String($0) } ?? "png"
            let image = SignatureImage(filename: "signature-\(images.count + 1).\(ext.replacingOccurrences(of: "svg+xml", with: "svg"))",
                                       mimeType: mime, data: data)
            images.append(image)
            return "cid:\(image.contentID)"
        }
        let used = contentIDs(in: out)
        for image in existing where used.contains(image.contentID) && !images.contains(where: { $0.contentID == image.contentID }) {
            images.append(image)
        }
        return (out, images)
    }

    /// The remote (http/https) image addresses in the HTML.
    public static func remoteImageURLs(in html: String) -> [String] {
        var seen = Set<String>()
        return matches(in: html, pattern: #"<img\b[^>]*?\bsrc\s*=\s*["'](https?://[^"']+)["']"#)
            .map { HTMLText.decodeEntities($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Replaces a remote image address with an embedded image (keeping its size attributes).
    public static func embedding(_ url: String, as image: SignatureImage, in html: String) -> String {
        let escaped = escape(url)
        return html.replacingOccurrences(of: "\"\(url)\"", with: "\"cid:\(image.contentID)\"")
            .replacingOccurrences(of: "\"\(escaped)\"", with: "\"cid:\(image.contentID)\"")
            .replacingOccurrences(of: "'\(url)'", with: "'cid:\(image.contentID)'")
    }

    // MARK: Helpers

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// FNV-1a: the same on every device and every run (Swift's `hashValue` isn't).
    public static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let r = Range(m.range(at: group), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    static func matches(in s: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    static func replacing(in s: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return s }
        var out = ""
        var last = s.startIndex
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound]
            out += transform(String(s[r]))
            last = r.upperBound
        }
        out += s[last...]
        return out
    }
}

// MARK: - Which signature

/// "This signature", or none at all.
public enum SignatureChoice: Codable, Sendable, Hashable {
    case none
    case signature(String)

    public var signatureID: String? { if case .signature(let id) = self { id } else { nil } }
}

/// What an address uses when no rule says otherwise.
public struct SignatureDefaults: Codable, Sendable, Hashable {
    /// New mail; nil: none.
    public var newMail: SignatureChoice?
    /// Replies and forwards; nil: as new mail.
    public var replies: SignatureChoice?

    public init(newMail: SignatureChoice? = nil, replies: SignatureChoice? = nil) {
        self.newMail = newMail
        self.replies = replies
    }
}

/// An exception to the defaults, by who the mail goes to: "everyone is at creativeoak.dk →
/// the short one".
public struct SignatureRule: Codable, Sendable, Hashable, Identifiable {
    public enum Match: String, Codable, Sendable, CaseIterable {
        /// Every recipient is at one of the domains (internal mail).
        case everyRecipientIn
        /// At least one recipient is at one of the domains.
        case anyRecipientIn
        /// At least one recipient is somewhere else (external mail).
        case anyRecipientOutside
    }

    public enum Context: String, Codable, Sendable, CaseIterable {
        case all, newMail, replies
    }

    public var id: String
    /// Sending from this address only; nil: any.
    public var fromAddress: String?
    public var context: Context
    public var match: Match
    /// Domains like "creativeoak.dk" (a leading "@" is fine); a subdomain counts as its domain.
    public var domains: [String]
    public var use: SignatureChoice

    public init(id: String = UUID().uuidString, fromAddress: String? = nil, context: Context = .all,
                match: Match = .everyRecipientIn, domains: [String] = [], use: SignatureChoice = .none) {
        self.id = id
        self.fromAddress = fromAddress
        self.context = context
        self.match = match
        self.domains = domains
        self.use = use
    }

    /// Normalised domains: lowercased, without "@" or spaces.
    public var cleanDomains: [String] {
        domains.map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@.")) }
            .filter { !$0.isEmpty }
    }

    func applies(from: String, kind: ComposeKind, recipients: [String]) -> Bool {
        if let fromAddress, fromAddress.lowercased() != from.lowercased() { return false }
        switch context {
        case .all: break
        case .newMail: if kind != .new { return false }
        case .replies: if kind == .new { return false }
        }
        let domains = cleanDomains
        guard !domains.isEmpty, !recipients.isEmpty else { return false }
        func inside(_ address: String) -> Bool {
            let domain = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
            return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
        switch match {
        case .everyRecipientIn: return recipients.allSatisfy(inside)
        case .anyRecipientIn: return recipients.contains(where: inside)
        case .anyRecipientOutside: return recipients.contains { !inside($0) }
        }
    }
}

/// Your signatures' rules: defaults per address and exceptions by recipient.
public struct SignatureSettings: Codable, Sendable, Hashable {
    /// By lowercased address.
    public var defaults: [String: SignatureDefaults]
    /// In order; the first that applies wins.
    public var rules: [SignatureRule]

    public init(defaults: [String: SignatureDefaults] = [:], rules: [SignatureRule] = []) {
        self.defaults = defaults
        self.rules = rules
    }

    public func defaults(for address: String) -> SignatureDefaults { defaults[address.lowercased()] ?? SignatureDefaults() }

    public mutating func setDefaults(_ value: SignatureDefaults, for address: String) { defaults[address.lowercased()] = value }

    /// The signature for a message: a rule that applies, else the address's default for new
    /// mail or for replies and forwards. Nil: no signature.
    public func choose(from address: String, kind: ComposeKind, recipients: [String]) -> String? {
        if let rule = rules.first(where: { $0.applies(from: address, kind: kind, recipients: recipients) }) {
            return rule.use.signatureID
        }
        let d = defaults(for: address)
        let choice = kind == .new ? d.newMail : (d.replies ?? d.newMail)
        return choice?.signatureID
    }

    /// Without a signature that no longer exists.
    public mutating func forget(signatureID: String) {
        for (address, var d) in defaults {
            if d.newMail?.signatureID == signatureID { d.newMail = nil }
            if d.replies?.signatureID == signatureID { d.replies = nil }
            defaults[address] = d
        }
        rules.removeAll { $0.use.signatureID == signatureID }
    }
}
