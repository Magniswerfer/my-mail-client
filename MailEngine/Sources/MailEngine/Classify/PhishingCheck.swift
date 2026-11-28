import Foundation
import GRDB

public enum RiskLevel: Int, Sendable, Codable, Comparable, DatabaseValueConvertible {
    case none = 0, caution = 1, danger = 2
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Why a message looks risky, as a stable code the app localizes.
public enum RiskReason: Sendable, Hashable {
    case dmarcFailed
    case dkimFailed
    case spfFailed
    case brandInDisplayName(brand: String, domain: String)
    case addressInDisplayName(shown: String)
    case lookalikeDomain(domain: String, resembles: String)
    case punycodeDomain(domain: String)
    case linkMismatch(shown: String, actual: String)
    case replyToElsewhere(domain: String)

    public var encoded: String {
        switch self {
        case .dmarcFailed: "dmarc"
        case .dkimFailed: "dkim"
        case .spfFailed: "spf"
        case .brandInDisplayName(let b, let d): "brand|\(b)|\(d)"
        case .addressInDisplayName(let s): "nameAddress|\(s)"
        case .lookalikeDomain(let d, let r): "lookalike|\(d)|\(r)"
        case .punycodeDomain(let d): "punycode|\(d)"
        case .linkMismatch(let s, let a): "link|\(s)|\(a)"
        case .replyToElsewhere(let d): "replyTo|\(d)"
        }
    }

    public init?(encoded: String) {
        let p = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func arg(_ i: Int) -> String { p.count > i ? p[i] : "" }
        switch p.first {
        case "dmarc": self = .dmarcFailed
        case "dkim": self = .dkimFailed
        case "spf": self = .spfFailed
        case "brand": self = .brandInDisplayName(brand: arg(1), domain: arg(2))
        case "nameAddress": self = .addressInDisplayName(shown: arg(1))
        case "lookalike": self = .lookalikeDomain(domain: arg(1), resembles: arg(2))
        case "punycode": self = .punycodeDomain(domain: arg(1))
        case "link": self = .linkMismatch(shown: arg(1), actual: arg(2))
        case "replyTo": self = .replyToElsewhere(domain: arg(1))
        default: return nil
        }
    }
}

public struct RiskAssessment: Sendable, Hashable {
    public var level: RiskLevel
    public var reasons: [RiskReason]
    public static let safe = RiskAssessment(level: .none, reasons: [])

    public var encodedReasons: String { reasons.map(\.encoded).joined(separator: "\n") }
    public static func decode(_ raw: String?) -> [RiskReason] {
        (raw ?? "").split(separator: "\n").compactMap { RiskReason(encoded: String($0)) }
    }
}

/// Phishing and spoofing signals on top of iCloud's own spam filter (SPEC §8). Local only:
/// no lookups leave the device. Uncertain mail gets a warning; nothing is moved automatically.
public enum PhishingCheck {
    /// Brands commonly impersonated (global + Danish), with the domains they really send from.
    static let brands: [String: [String]] = [
        "apple": ["apple.com", "icloud.com", "me.com", "email.apple.com", "itunes.com"],
        "icloud": ["apple.com", "icloud.com", "me.com"],
        "paypal": ["paypal.com", "paypal.dk", "e.paypal.com"],
        "microsoft": ["microsoft.com", "outlook.com", "office.com", "live.com"],
        "google": ["google.com", "gmail.com", "accounts.google.com"],
        "amazon": ["amazon.com", "amazon.de", "amazon.co.uk"],
        "netflix": ["netflix.com"],
        "mobilepay": ["mobilepay.dk", "vippsmobilepay.com"],
        "mitid": ["mitid.dk"],
        "e-boks": ["e-boks.dk", "e-boks.com"],
        "skat": ["skat.dk", "skst.dk"],
        "postnord": ["postnord.dk", "postnord.com"],
        "gls": ["gls-group.eu", "gls.dk"],
        "dhl": ["dhl.com", "dhl.dk"],
        "danske bank": ["danskebank.dk", "danskebank.com"],
        "nordea": ["nordea.dk", "nordea.com"],
        "jyske bank": ["jyskebank.dk"],
        "nets": ["nets.eu"],
        "dankort": ["nets.eu", "dankort.dk"],
        "borger.dk": ["borger.dk"],
    ]

    static let brandDomains: [String] = Array(Set(brands.values.flatMap { $0 }))
    /// A couple of mismatched links make the point; more would only crowd the warning.
    static let maxLinkMismatchesReported = 2

    public static func evaluate(_ parsed: ParsedMessage, trustedDomains: Set<String> = []) -> RiskAssessment {
        let sender = Sender(parsed.from.first)
        var reasons = authenticationFailures(parsed)
        if !trustedDomains.contains(sender.base), let reason = brandImpersonation(by: sender) { reasons.append(reason) }
        if let reason = foreignAddressInDisplayName(of: sender) { reasons.append(reason) }
        if let reason = lookalikeDomain(of: sender, trustedDomains: trustedDomains) { reasons.append(reason) }
        if let html = parsed.html {
            for (shown, actual) in mismatchedLinks(in: html).prefix(maxLinkMismatchesReported) {
                reasons.append(.linkMismatch(shown: shown, actual: actual))
            }
        }
        // On its own a different Reply-To is common (support desks, lists); it only adds to other signs.
        if !reasons.isEmpty, let reason = replyToElsewhere(parsed, sender: sender) { reasons.append(reason) }
        return RiskAssessment(level: level(for: reasons), reasons: reasons)
    }

    struct Sender {
        let domain: String
        /// The registrable domain (`registrable(domain)`).
        let base: String
        let displayName: String

        init(_ address: MailAddress?) {
            domain = address?.address.lowercased().split(separator: "@").last.map(String.init) ?? ""
            base = registrable(domain)
            displayName = (address?.name ?? "").lowercased()
        }
    }

    /// What the receiving server measured.
    static func authenticationFailures(_ parsed: ParsedMessage) -> [RiskReason] {
        guard let auth = parsed.header("Authentication-Results")?.lowercased() else { return [] }
        var reasons: [RiskReason] = []
        if auth.contains("dmarc=fail") { reasons.append(.dmarcFailed) }
        if auth.contains("dkim=fail") { reasons.append(.dkimFailed) }
        if auth.contains("spf=fail") { reasons.append(.spfFailed) }
        return reasons
    }

    /// The display name claims a brand the sending domain doesn't belong to. Whole words only:
    /// "Apple Support" counts, "Appleby Bakery" doesn't.
    static func brandImpersonation(by sender: Sender) -> RiskReason? {
        for (brand, domains) in brands where sender.displayName.range(of: #"(^|[^a-z0-9])\#(NSRegularExpression.escapedPattern(for: brand))($|[^a-z0-9])"#, options: .regularExpression) != nil {
            if !domains.contains(where: { sender.domain == $0 || sender.domain.hasSuffix("." + $0) || registrable($0) == sender.base }) {
                return .brandInDisplayName(brand: brand, domain: sender.domain)
            }
        }
        return nil
    }

    /// `"service@apple.com" <x@evil.example>`: the display name shows an address on another domain.
    static func foreignAddressInDisplayName(of sender: Sender) -> RiskReason? {
        guard let shown = sender.displayName.range(of: #"[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})"#, options: .regularExpression) else { return nil }
        let shownAddress = String(sender.displayName[shown])
        let shownDomain = shownAddress.split(separator: "@").last.map(String.init) ?? ""
        return registrable(shownDomain) != sender.base ? .addressInDisplayName(shown: shownAddress) : nil
    }

    static func lookalikeDomain(of sender: Sender, trustedDomains: Set<String>) -> RiskReason? {
        if sender.domain.hasPrefix("xn--") || sender.domain.contains(".xn--") { return .punycodeDomain(domain: sender.domain) }
        guard !trustedDomains.contains(sender.base),
              let target = lookalike(of: sender.base, among: brandDomains.map(registrable) + Array(trustedDomains)) else { return nil }
        return .lookalikeDomain(domain: sender.domain, resembles: target)
    }

    /// Replies would go to a different organisation.
    static func replyToElsewhere(_ parsed: ParsedMessage, sender: Sender) -> RiskReason? {
        guard let replyTo = parsed.replyTo.first?.address.lowercased(),
              let replyDomain = replyTo.split(separator: "@").last.map(String.init),
              registrable(replyDomain) != sender.base else { return nil }
        return .replyToElsewhere(domain: replyDomain)
    }

    static let dangerScore = 4
    static let cautionScore = 2

    static func level(for reasons: [RiskReason]) -> RiskLevel {
        var score = 0
        for reason in reasons {
            switch reason {
            case .dmarcFailed: score += 3
            case .dkimFailed, .spfFailed: score += 1
            case .brandInDisplayName, .addressInDisplayName: score += 3
            case .lookalikeDomain, .punycodeDomain: score += 4
            case .linkMismatch: score += 2
            case .replyToElsewhere: score += 1
            }
        }
        return score >= dangerScore ? .danger : score >= cautionScore ? .caution : .none
    }

    // MARK: Helpers

    /// A cheap stand-in for the public-suffix list: last two labels, three for "co.uk"-style suffixes.
    static func registrable(_ domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let take = secondLevel.contains(labels[labels.count - 2]) && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Domains that look like a known one: digit/letter swaps, "rn"→"m", small edit distance.
    static func lookalike(of domain: String, among known: [String]) -> String? {
        guard !domain.isEmpty, !known.contains(domain) else { return nil }
        let normalized = homoglyphNormalized(domain)
        let name = domain.split(separator: ".").first.map(String.init) ?? domain
        for target in Set(known) where target != domain {
            let targetName = target.split(separator: ".").first.map(String.init) ?? target
            guard targetName.count >= 4 else { continue }
            if homoglyphNormalized(target) == normalized { return target }
            if name != targetName, editDistance(name, targetName) <= (targetName.count >= 7 ? 2 : 1) { return target }
            // "apple-support.com", "paypal-secure.net", "app1e-id.com": a brand name (after undoing
            // look-alike swaps) plus decoration, on a domain the brand doesn't use.
            if name != targetName, homoglyphNormalized(name).contains(targetName), name.count > targetName.count + 2,
               brands.keys.contains(targetName) { return target }
        }
        return nil
    }

    static func homoglyphNormalized(_ s: String) -> String {
        var out = s.lowercased()
        for (a, b) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("3", "e"), ("5", "s"), ("@", "a"), ("-", "")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j - 1], row[j]) + 1
                previous = current
            }
        }
        return row[b.count]
    }

    /// (shown domain, actual domain) for anchors whose text looks like a URL/domain on another site.
    static func mismatchedLinks(in html: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for anchor in HTMLScan.elements("a", in: html) {
            guard let href = Unsubscribe.href(in: anchor.open) else { continue }
            let text = anchor.inner.replacingOccurrences(of: "<[^<>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let actualHost = URL(string: href)?.host()?.lowercased(),
                  let shownRange = text.range(of: #"^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}"#, options: .regularExpression) else { continue }
            let shownHost = String(text[shownRange]).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            if registrable(shownHost) != registrable(actualHost) { result.append((shownHost, actualHost)) }
        }
        return result
    }
}

extension MailStore {
    static func registerRiskMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v7-risk") { db in
            try db.alter(table: "message") { t in
                t.add(column: "riskLevel", .integer).notNull().defaults(to: 0)
                t.add(column: "riskReasons", .text)
            }
            try db.create(table: "trustedSender") { t in
                t.column("address", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
            }
        }
    }

    /// "It's safe": clears warnings for this sender now and in future.
    public func markSafe(sender: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO trustedSender (address, createdAt) VALUES (?, ?)", arguments: [sender.lowercased(), Date()])
            try db.execute(sql: "UPDATE message SET riskLevel = 0, riskReasons = NULL WHERE lower(fromAddress) = ?", arguments: [sender.lowercased()])
        }
    }

    public func isTrustedSender(_ address: String) throws -> Bool {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM trustedSender WHERE address = ?", arguments: [address.lowercased()]) ?? 0 > 0 }
    }

    /// Domains you've written to: never flagged as look-alikes of themselves, and protected from
    /// look-alikes of them.
    public func correspondentDomains(ownAddresses: Set<String>) throws -> Set<String> {
        guard !ownAddresses.isEmpty else { return [] }
        let mine = ownAddresses.map { $0.lowercased() }
        let rows = try db.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT recipients FROM message WHERE lower(fromAddress) IN (\(mine.map { _ in "?" }.joined(separator: ",")))",
                                arguments: StatementArguments(mine))
        }
        var domains = Set<String>()
        for row in rows {
            for address in AddressParser.parse(row) {
                if let d = address.address.lowercased().split(separator: "@").last { domains.insert(PhishingCheck.registrable(String(d))) }
            }
        }
        return domains
    }
}
