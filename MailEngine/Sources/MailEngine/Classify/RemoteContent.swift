import Foundation
import GRDB

/// HTML ready for the reader, with what was done to it (SPEC §8).
public struct PreparedHTML: Sendable, Hashable {
    public var html: String
    /// Tracking pixels removed (always, regardless of image settings).
    public var trackersRemoved: Int
    /// Links whose tracking parameters were stripped.
    public var linksCleaned: Int
    /// Remote images left in the message (shown only if allowed).
    public var remoteImages: Int
}

/// Privacy for HTML mail: strip trackers always; leave real images for the policy to allow.
public enum RemoteContent {
    /// Hosts that exist only to record opens.
    static let trackerHosts = [
        "list-manage.com", "mailchimp.com", "sendgrid.net", "sendgrid.com", "mandrillapp.com", "mailgun.org",
        "sparkpostmail.com", "hubspotemail.net", "hs-analytics.net", "mktoresp.com", "mailtrack.io", "mixmax.com",
        "yesware.com", "getnotify.com", "bananatag.com", "streak.com", "superhuman.com", "pixel.wp.com",
        "exacttarget.com", "e.customeriomail.com", "klaviyomail.com", "trk.klclick.com", "returnpath.net",
        "emltrk.com", "t.co", "doubleclick.net", "google-analytics.com", "facebook.com/tr", "salesforce.com/track",
    ]
    /// Path fragments typical of open-tracking URLs.
    static let trackerPathHints = ["/open", "/track", "/trk", "pixel", "beacon", "/wf/open", "/o.gif", "/e/o", "openrate", "/imp?", "/mo/"]
    /// Query parameters that only exist for tracking.
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "fbclid", "gclid", "dclid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id", "yclid", "igshid", "trk",
    ]

    public static func prepare(_ html: String) -> PreparedHTML {
        var trackers = 0
        var remote = 0
        var output = replacing(in: html, pattern: #"<img\b[^>]*>"#) { tag in
            if isTracker(imgTag: tag) { trackers += 1; return "" }
            if let src = attribute("src", in: tag), src.lowercased().hasPrefix("http") { remote += 1 }
            return tag
        }
        var cleaned = 0
        output = replacing(in: output, pattern: #"href\s*=\s*"([^"]+)""#) { attr in
            guard let value = attribute("href", in: attr), let stripped = stripTracking(value), stripped != value else { return attr }
            cleaned += 1
            return "href=\"\(stripped)\""
        }
        return PreparedHTML(html: output, trackersRemoved: trackers, linksCleaned: cleaned, remoteImages: remote)
    }

    static func isTracker(imgTag tag: String) -> Bool {
        let lower = tag.lowercased()
        func dimension(_ name: String) -> Int? {
            if let v = attribute(name, in: tag) { return Int(v.filter(\.isNumber)) }
            if let style = attribute("style", in: tag)?.lowercased(),
               let range = style.range(of: #"\#(name)\s*:\s*(\d+)"#, options: .regularExpression) {
                return Int(style[range].filter(\.isNumber))
            }
            return nil
        }
        let w = dimension("width"), h = dimension("height")
        if let w, let h, w <= 2, h <= 2 { return true }
        if lower.contains("display:none") || lower.contains("display: none") || lower.contains("visibility:hidden") { return true }
        guard let src = attribute("src", in: tag)?.lowercased(), src.hasPrefix("http") else { return false }
        guard let url = URL(string: src), let host = url.host() else { return false }
        if trackerHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) || (src.contains($0) && $0.contains("/")) }) {
            return true
        }
        let path = (url.path() + "?" + (url.query() ?? "")).lowercased()
        // Only treat path hints as trackers for tiny or dimensionless images, so real images survive.
        return trackerPathHints.contains(where: path.contains) && (w ?? 0) <= 10 && (h ?? 0) <= 10
    }

    /// Removes tracking query parameters. A link that can't be parsed comes back unchanged; nil
    /// only when the cleaned components can't be put back together.
    public static func stripTracking(_ link: String) -> String? {
        let decoded = link.replacingOccurrences(of: "&amp;", with: "&")
        guard var components = URLComponents(string: decoded), let items = components.queryItems, !items.isEmpty else { return link }
        let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return link }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string?.replacingOccurrences(of: "&", with: "&amp;")
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }

    static func replacing(in text: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }
}

// MARK: - Image trust

extension MailStore {
    static func registerPrivacyMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v6-privacy") { db in
            try db.create(table: "imageTrust") { t in
                t.column("sender", .text).primaryKey()   // an address, or "@domain"
                t.column("createdAt", .datetime).notNull()
            }
        }
    }

    /// Remote images load automatically for people you've written to, or senders/domains you approved.
    public func allowsRemoteImages(from address: String, ownAddresses: Set<String>) throws -> Bool {
        let sender = address.lowercased()
        let domain = sender.split(separator: "@").last.map { "@" + $0 } ?? ""
        return try db.read { db in
            if try Int.fetchOne(db, sql: "SELECT count(*) FROM imageTrust WHERE sender IN (?, ?)", arguments: [sender, domain]) ?? 0 > 0 {
                return true
            }
            // Mail you sent (your signature's pictures among them): nothing to protect you from.
            if ownAddresses.contains(where: { $0.lowercased() == sender }) { return true }
            return try Self.hasWritten(to: sender, from: ownAddresses, in: db)
        }
    }

    public func trustImages(from senderOrDomain: String) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO imageTrust (sender, createdAt) VALUES (?, ?)",
                           arguments: [senderOrDomain.lowercased(), Date()])
        }
    }
}

extension MIMEParser {
    /// Inline parts addressed by Content-ID (for `cid:` images in HTML).
    public static func inlineParts(in data: Data) -> [String: (data: Data, mimeType: String)] {
        var result: [String: (Data, String)] = [:]
        for attachment in attachments(in: data) {
            if let cid = attachment.contentID { result[cid] = (attachment.data, attachment.mimeType) }
        }
        return result
    }
}
