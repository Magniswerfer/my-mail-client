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
    /// `TIDINGS_PLAINTEXT_HOSTS`, for a test server on a private network).
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
            return host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
                || host.hasPrefix("::ffff:")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            let octets = parts.compactMap { UInt8($0) }
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        // A single label ("router", "nas") is a local name; a bare number is an IPv4 shorthand.
        return !host.contains(".") || host.first?.isNumber == true && host.allSatisfy { $0.isHexDigit || $0 == "." || $0 == "x" }
    }
}
