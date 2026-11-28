import Foundation

/// Links and phone numbers from the bottom of someone's latest message: their signature.
public struct SignatureInfo: Sendable, Hashable {
    public enum LinkKind: String, Sendable, Hashable { case linkedIn, x, github, mastodon, bluesky, website }

    public struct Link: Sendable, Hashable {
        public var kind: LinkKind
        public var url: String
        public var label: String
    }

    public var links: [Link] = []
    public var phones: [String] = []

    /// Signatures sit in the last lines of what someone wrote.
    static let signatureLineCount = 14
    /// Digits in a phone number, international prefix included.
    static let phoneDigitCount = 8...15

    static let webmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "yahoo.com", "yahoo.dk", "aol.com", "proton.me", "protonmail.com",
        "hey.com", "fastmail.com", "gmx.com", "gmx.net", "mail.dk", "jubii.dk", "hotmail.dk", "live.dk",
    ]

    public static func looksAutomated(_ address: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let normalized = local.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        return SignalClassifier.automatedLocalParts.contains { normalized == $0 || normalized.hasPrefix($0 + "-") }
    }

    /// Reads the last lines of what the sender wrote (quotes removed) — where signatures live.
    public static func extract(from body: String) -> SignatureInfo {
        let lines = MailStore.ownLines(body).map(String.init)
        let tail = lines.suffix(Self.signatureLineCount).joined(separator: "\n")
        var info = SignatureInfo()
        var seen = Set<String>()
        for raw in urls(in: tail) {
            let url = raw.hasPrefix("http") ? raw : "https://" + raw
            guard let host = URL(string: url)?.host?.lowercased(), seen.insert(url.lowercased()).inserted else { continue }
            let path = URL(string: url)?.path ?? ""
            let kind: LinkKind
            switch true {
            case host.hasSuffix("linkedin.com"): kind = .linkedIn
            case host == "x.com" || host.hasSuffix("twitter.com"): kind = .x
            case host.hasSuffix("github.com"): kind = .github
            case host.hasSuffix("bsky.app"): kind = .bluesky
            case path.hasPrefix("/@"): kind = .mastodon
            default: kind = .website
            }
            // Tracking redirects and images aren't anyone's website.
            if kind == .website, host.contains("safelinks") || host.contains("urldefense") || path.hasSuffix(".png") || path.hasSuffix(".jpg") { continue }
            let label = kind == .website ? host.replacingOccurrences(of: "www.", with: "") : String(path.split(separator: "/").last ?? Substring(host))
            info.links.append(Link(kind: kind, url: url, label: label))
        }
        for match in tail.matches(of: /(?:\+|00)?\d[\d \-().]{6,}\d/) {
            let number = String(match.output).trimmingCharacters(in: .whitespaces)
            let digits = number.filter(\.isNumber)
            // Not a date or an order number in disguise.
            guard Self.phoneDigitCount.contains(digits.count), !number.contains("."), seen.insert(digits).inserted else { continue }
            info.phones.append(number)
        }
        return info
    }

    static func urls(in text: String) -> [String] {
        let full = text.matches(of: /(?:https?:\/\/|www\.)[^\s<>"'()\[\]]+/).map { m in
            var s = String(m.output)
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            return s
        }
        // "linkedin.com/in/anna" written without https://
        let bare = text.matches(of: /(?:linkedin\.com\/in\/|github\.com\/)[\w\-]+/).map { String($0.output) }
            .filter { b in !full.contains { $0.contains(b) } }
        return full + bare
    }
}
