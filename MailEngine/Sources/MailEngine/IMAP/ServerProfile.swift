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
