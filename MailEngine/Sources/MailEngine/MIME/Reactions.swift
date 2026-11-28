import Foundation

/// The raw reaction parts of a message, as the parser found them.
public struct ReactionParts: Sendable, Hashable {
    /// Body of the first non-attachment `Content-Disposition: reaction` part (RFC 9078), trimmed.
    public var rfc9078: String?
    /// Emoji of a Gmail `text/vnd.google.email-reaction+json` part (`{"version":1,"emoji":"👍"}`).
    public var gmail: String?

    public init(rfc9078: String? = nil, gmail: String? = nil) {
        self.rfc9078 = rfc9078
        self.gmail = gmail
    }

    static let gmailType = "text/vnd.google.email-reaction+json"

    static func gmailEmoji(_ json: String) -> String? {
        struct Payload: Decodable { var version: Int; var emoji: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)), payload.version == 1 else { return nil }
        return payload.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A message that is a reaction to another one ("👍 to your message").
public struct ReactionMark: Sendable, Hashable {
    /// The Message-ID reacted to (the reaction's In-Reply-To), without angle brackets.
    public var target: String
    /// The emoji; empty when the sender took their reaction back.
    public var emoji: String

    public init(target: String, emoji: String) {
        self.target = target
        self.emoji = emoji
    }

    public var isRemoval: Bool { emoji.isEmpty }
}

extension ParsedMessage {
    /// What this message reacts to, if it's a reaction: Gmail's JSON part, an RFC 9078
    /// `Content-Disposition: reaction` part, or Outlook's fallback mail. Only a reply
    /// (In-Reply-To) can be one.
    public var reaction: ReactionMark? { ReactionDetector.detect(self) }

    /// The sender's client asks not to be reacted to (`x-ms-reactions: disallow`, Outlook).
    public var reactionsDisallowed: Bool {
        header("x-ms-reactions")?.trimmingCharacters(in: .whitespaces).lowercased() == "disallow"
    }
}

/// Recognizes reaction mail in its three shapes. Never relies on wording: Outlook's
/// "reacted to your message" is localized.
enum ReactionDetector {
    /// Outlook's reaction names (from its image file names and text markers).
    static let outlookEmoji: [String: String] = [
        "like": "👍", "heart": "❤️", "celebrate": "🎉", "laugh": "😆", "surprised": "😮", "sad": "😢",
    ]

    static func detect(_ parsed: ParsedMessage) -> ReactionMark? {
        guard let target = parsed.inReplyTo.first else { return nil }
        if let body = parsed.reactionParts.rfc9078, body.isEmpty || isEmojiText(body) {
            return ReactionMark(target: target, emoji: body)
        }
        if let emoji = parsed.reactionParts.gmail, isEmojiText(emoji) {
            return ReactionMark(target: target, emoji: emoji)
        }
        if let html = parsed.html, let emoji = outlookHTML(html) {
            return ReactionMark(target: target, emoji: emoji)
        }
        if let emoji = outlookText(parsed.plainText) {
            return ReactionMark(target: target, emoji: emoji)
        }
        return nil
    }

    static let maxReactionEmoji = 16
    /// Outlook's own part is just the reaction line; longer text is a real reply quoting a reaction.
    static let maxOutlookReactionText = 400
    static let minOutlookRuleLength = 5

    /// Only emoji (and spaces), a handful at most: a reaction, not a short reply.
    static func isEmojiText(_ s: String) -> Bool {
        let chars = s.filter { !$0.isWhitespace }
        guard !chars.isEmpty, chars.count <= maxReactionEmoji else { return false }
        return chars.allSatisfy { c in !c.isASCII && c.unicodeScalars.contains { $0.properties.isEmoji } }
    }

    // MARK: Outlook

    /// `<img alt="like" src="https://outlook-1.cdn.office.net/assets/reaction/like.png">` before
    /// the quoted original, or `<img alt="0" src="">` for a removed reaction. Returns the emoji,
    /// "" for a removal, nil when this isn't Outlook's reaction mail.
    static func outlookHTML(_ html: String) -> String? {
        let own = ownPart(html)
        guard HTMLText.toPlainText(own).count < maxOutlookReactionText else { return nil }
        for tag in imageTags(in: own) {
            let alt = attribute("alt", in: tag)
            let src = attribute("src", in: tag) ?? ""
            if let name = reactionImageName(src), let emoji = outlookEmoji[name] { return emoji }
            if alt == "0", src.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        }
        return nil
    }

    /// The HTML before the quoted original (Outlook's `divRplyFwdMsg`, a rule, or a blockquote).
    static func ownPart(_ html: String) -> String {
        var end = html.endIndex
        for marker in ["divRplyFwdMsg", "<hr", "<blockquote"] {
            if let range = html.range(of: marker, options: .caseInsensitive), range.lowerBound < end { end = range.lowerBound }
        }
        return String(html[..<end])
    }

    /// `https://outlook-1.cdn.office.net/assets/reaction/like.png` → "like".
    static func reactionImageName(_ src: String) -> String? {
        guard let url = URL(string: src.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host.hasSuffix(".office.net") || host.hasSuffix(".office.com") else { return nil }
        let parts = url.path.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 3] == "assets", parts[parts.count - 2] == "reaction",
              parts[parts.count - 1].hasSuffix(".png") else { return nil }
        return String(parts[parts.count - 1].dropLast(4))
    }

    static let textMarker = try? NSRegularExpression(
        pattern: #"^\s*\[(like|heart|celebrate|laugh|surprised|sad|0)\]\s+.+:\s*$"#, options: [.caseInsensitive])

    /// The plain-text form: first line `[like]     Name reacted to your message:` (in any language),
    /// then a line of underscores above the quoted original.
    static func outlookText(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let regex = textMarker else { return nil }
        let first = lines[0]
        let ns = first as NSString
        guard let match = regex.firstMatch(in: first, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let rule = lines[1]
        guard rule.count >= minOutlookRuleLength, rule.allSatisfy({ $0 == "_" }) else { return nil }
        let name = ns.substring(with: match.range(at: 1)).lowercased()
        return name == "0" ? "" : outlookEmoji[name]
    }

    // MARK: Small HTML helpers

    static let imageTag = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    static func imageTags(in html: String) -> [String] {
        guard let imageTag else { return [] }
        let ns = html as NSString
        return imageTag.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// An attribute's value in one tag, entities decoded; nil when absent.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return HTMLText.decodeEntities(ns.substring(with: match.range(at: group)))
        }
        return nil
    }
}
