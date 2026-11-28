import Foundation

/// Everything the server reads from its environment (Coolify variables and secrets).
public struct ServerConfig: Sendable {
    /// Where the server keeps its database, the mail store and nothing else. A persistent volume.
    public var dataDirectory: URL
    public var host = "0.0.0.0"
    public var port = 8080
    /// What a device must show to pair (`TIDINGS_PAIRING_SECRET`).
    public var pairingSecret: String
    /// `TIDINGS_MASTER_KEY`, 32 bytes base64: encrypts the stored passwords.
    public var masterKey: String
    public var apns: APNsConfig?
    /// Plain-text IMAP is refused except to these hosts (the local test server).
    public var plaintextHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    /// When set (`TIDINGS_ALLOWED_MAIL_HOSTS`), uploaded accounts may only use these IMAP and
    /// SMTP hosts, e.g. `imap.mail.me.com,smtp.mail.me.com`. Recommended: it stops a stolen
    /// device token from pointing an account at another server.
    public var allowedMailHosts: Set<String> = []
    /// A send-later message must be due at least this far out (devices hand off only mail due
    /// in more than 5 minutes).
    public var minimumScheduleLead: TimeInterval = 60
    /// At most this many send-later messages wait on the server.
    public var maxScheduled = 200
    /// How often Sent and Snoozed are re-synced next to INBOX's IDLE.
    public var pollInterval: Duration = .seconds(300)

    public struct APNsConfig: Sendable {
        /// The `.p8` file's contents (PEM).
        public var privateKeyPEM: String
        public var keyID: String
        public var teamID: String
        /// The iPhone app's bundle id.
        public var topic: String
        /// For tests: send to this URL instead of Apple (both environments).
        public var overrideURL: String?
        public var overridePort: Int?

        public init(privateKeyPEM: String, keyID: String, teamID: String, topic: String,
                    overrideURL: String? = nil, overridePort: Int? = nil) {
            self.privateKeyPEM = privateKeyPEM
            self.keyID = keyID
            self.teamID = teamID
            self.topic = topic
            self.overrideURL = overrideURL
            self.overridePort = overridePort
        }
    }

    public init(dataDirectory: URL, pairingSecret: String, masterKey: String, apns: APNsConfig?) {
        self.dataDirectory = dataDirectory
        self.pairingSecret = pairingSecret
        self.masterKey = masterKey
        self.apns = apns
    }

    /// From `TIDINGS_*` and `APNS_*` variables. Push is optional (the server still syncs and
    /// wakes snoozes without it); the pairing secret and master key are not.
    static let minimumPairingSecretLength = 16
    /// Polling Sent and Snoozed more often than this only loads the mail server.
    static let minimumPollSeconds = 30
    static let defaultTeamID = "493257NQK3"
    static let defaultTopic = "hk.gnus.tidings"

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfig {
        func required(_ name: String) throws -> String {
            guard let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ConfigError.missing(name) }
            return value
        }
        let secret = try required("TIDINGS_PAIRING_SECRET")
        guard secret.count >= minimumPairingSecretLength else {
            throw ConfigError.invalid("TIDINGS_PAIRING_SECRET must be at least \(minimumPairingSecretLength) characters")
        }
        var apns: APNsConfig?
        if let pem = env["APNS_KEY_P8"], !pem.isEmpty {
            // A PEM kept in a single-line variable has its line breaks written as "\n".
            apns = APNsConfig(privateKeyPEM: pem.replacingOccurrences(of: "\\n", with: "\n"), keyID: try required("APNS_KEY_ID"),
                              teamID: env["APNS_TEAM_ID"] ?? defaultTeamID, topic: env["APNS_TOPIC"] ?? defaultTopic)
        }
        var config = ServerConfig(dataDirectory: URL(fileURLWithPath: env["TIDINGS_DATA_DIR"] ?? "/data", isDirectory: true),
                                  pairingSecret: secret, masterKey: try required("TIDINGS_MASTER_KEY"), apns: apns)
        if let port = env["PORT"].flatMap(Int.init) ?? env["TIDINGS_PORT"].flatMap(Int.init) { config.port = port }
        if let hosts = env["TIDINGS_PLAINTEXT_IMAP_HOSTS"] {
            config.plaintextHosts.formUnion(hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
        if let hosts = env["TIDINGS_ALLOWED_MAIL_HOSTS"] {
            config.allowedMailHosts = Set(hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        }
        if let seconds = env["TIDINGS_POLL_SECONDS"].flatMap(Int.init) { config.pollInterval = .seconds(max(minimumPollSeconds, seconds)) }
        return config
    }
}
