import Foundation

/// Connection settings for one IMAP account.
public struct IMAPEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var username: String

    public init(host: String, port: UInt16, useTLS: Bool, username: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
    }

    /// iCloud Mail. Username is the full address (the local part also works).
    public static func iCloud(address: String) -> IMAPEndpoint {
        IMAPEndpoint(host: "imap.mail.me.com", port: 993, useTLS: true, username: address)
    }
}

/// Server-specific behaviour the engine must work around.
/// See docs/research/icloud-imap.md for where each of these comes from.
public struct ServerProfile: Sendable, Hashable {
    /// `ENABLE` answers with a bare tagged OK and no `* ENABLED` line; treat OK as success.
    public var enableOmitsEnabledResponse: Bool
    /// The pre-auth capability list is incomplete; always re-issue `CAPABILITY` after login.
    public var requiresCapabilityAfterLogin: Bool
    /// Upper bound on concurrent connections we open per account.
    public var maxConnections: Int
    /// Re-issue IDLE before this interval elapses.
    public var idleRefresh: Duration
    /// Capabilities to treat as absent even if advertised. Used to simulate iCloud on Dovecot.
    public var ignoredCapabilities: Set<String> = []

    public static let iCloud = ServerProfile(
        enableOmitsEnabledResponse: true,
        requiresCapabilityAfterLogin: true,
        maxConnections: 3,
        idleRefresh: .seconds(25 * 60)
    )

    public static let generic = ServerProfile(
        enableOmitsEnabledResponse: false,
        requiresCapabilityAfterLogin: true,
        maxConnections: 4,
        idleRefresh: .seconds(25 * 60)
    )

    /// iCloud's behaviour on any server: hides the extensions iCloud lacks so fallbacks are exercised.
    public static let iCloudSimulation: ServerProfile = {
        var p = ServerProfile.iCloud
        p.ignoredCapabilities = ["MOVE", "SPECIAL-USE", "NOTIFY", "COMPRESS=DEFLATE", "LIST-EXTENDED", "OBJECTID"]
        return p
    }()

    public static func detect(host: String) -> ServerProfile {
        host.hasSuffix("mail.me.com") ? .iCloud : .generic
    }
}

/// Where a password may go without TLS. The account form only offers "no encryption" for this
/// machine; the engine enforces the same rule, so a synced or uploaded account setting can't
/// make a device send its password in the clear.
public enum TransportPolicy {
    /// Extra hosts allowed without TLS, set once at startup (the push server's
    /// `TIDINGS_PLAINTEXT_IMAP_HOSTS`, for a test server on a private network).
    nonisolated(unsafe) public static var additionalPlaintextHosts: Set<String> = []

    public static func allowsPlaintext(host: String) -> Bool {
        let host = host.lowercased()
        return ["127.0.0.1", "localhost", "::1"].contains(host) || additionalPlaintextHosts.contains(host)
    }
}

/// Hosts that name this machine or a private network, by name or address literal. Used where
/// untrusted input picks a host (an unsubscribe link, an uploaded server setting), so it can't
/// point the app or the push server at a router, a NAS, or a cloud metadata service.
/// A public name that resolves to a private address isn't caught: pair this with an allow-list
/// where it matters.
public enum NetworkTarget {
    public static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.isEmpty || host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".localdomain"] where host.hasSuffix(suffix) { return true }
        if host.contains(":") {   // IPv6 literal: loopback, unspecified, unique local, link-local, v4-mapped
            guard let bytes = ipv6(host) else { return true }   // unparseable: refuse rather than guess
            if bytes[0..<10].allSatisfy({ $0 == 0 }) { return true }   // ::, ::1, ::a.b.c.d, ::ffff:a.b.c.d
            return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        }
        if let address = ipv4(host) {
            let (a, b) = (address >> 24, (address >> 16) & 0xFF)
            switch (a, b) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        // A single label ("router", "nas") is a local name.
        return !host.contains(".")
    }

    /// An IPv4 literal the way the system resolver reads one (`inet_aton`): one to four parts,
    /// each decimal, `0x` hex or `0`-led octal, so `0177.0.0.1` and `2130706433` are 127.0.0.1.
    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            let text = part.lowercased()
            let value: UInt64?
            if text.hasPrefix("0x") { value = text.count == 2 ? 0 : UInt64(text.dropFirst(2), radix: 16) }
            else if text.count > 1, text.hasPrefix("0") { value = UInt64(text.dropFirst(), radix: 8) }
            else { value = UInt64(text, radix: 10) }
            guard let value, value <= UInt32.max else { return nil }
            values.append(value)
        }
        let last = values.removeLast()
        guard values.allSatisfy({ $0 <= 0xFF }), last < UInt64(1) << (8 * (4 - values.count)) else { return nil }
        let high = values.enumerated().reduce(UInt64(0)) { $0 | $1.element << (8 * (3 - $1.offset)) }
        return UInt32(high | last)
    }

    /// The 16 bytes of an IPv6 literal (with `::` and a trailing dotted IPv4), or nil.
    static func ipv6(_ literal: String) -> [UInt8]? {
        let host = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal
        func groups(_ text: Substring) -> [UInt16]? {
            if text.isEmpty { return [] }
            var out: [UInt16] = []
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, piece.contains(".") {
                    guard let v4 = ipv4(String(piece)), piece.split(separator: ".").count == 4 else { return nil }
                    out += [UInt16(v4 >> 16), UInt16(v4 & 0xFFFF)]
                } else {
                    guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                    out.append(value)
                }
            }
            return out
        }
        let halves = host.components(separatedBy: "::")
        var words: [UInt16]
        switch halves.count {
        case 1:
            guard let all = groups(Substring(host)), all.count == 8 else { return nil }
            words = all
        case 2:
            guard let head = groups(Substring(halves[0])), let tail = groups(Substring(halves[1])),
                  head.count + tail.count < 8 else { return nil }
            words = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        default: return nil
        }
        return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}
