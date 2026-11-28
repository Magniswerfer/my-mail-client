import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MailEngine
import Testing
@testable import TidingsPush

enum Fixtures {
    static let secret = "a-pairing-secret-for-tests"

    static func config(apns: ServerConfig.APNsConfig? = nil) throws -> ServerConfig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-server-\(UUID())", isDirectory: true)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var config = ServerConfig(dataDirectory: dir, pairingSecret: secret, masterKey: key, apns: apns)
        config.pollInterval = .seconds(5)
        config.minimumScheduleLead = 0   // the end-to-end tests send a moment later
        return config
    }

    static func json<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(bytes: try PushAPI.encoder.encode(value)) }

    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T {
        try PushAPI.decoder.decode(type, from: Data(buffer.readableBytesView))
    }
}

/// Records pushes instead of sending them.
actor RecordingSender: PushSender {
    var sent: [(Push, String)] = []
    nonisolated var isConfigured: Bool { true }
    func send(_ push: Push, to token: String, environment: PushAPI.PushEnvironment) async -> PushOutcome {
        sent.append((push, token))
        return .sent
    }
    func shutdown() async {}
}

@Suite struct SecretTests {
    @Test func passwordsRoundTripAndDontShowInTheSealedForm() throws {
        let box = try SecretBox(base64: Data(repeating: 7, count: 32).base64EncodedString())
        let sealed = try box.seal("abcd-efgh-ijkl-mnop")
        #expect(try box.open(sealed) == "abcd-efgh-ijkl-mnop")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("abcd"))
        let other = try SecretBox(base64: Data(repeating: 8, count: 32).base64EncodedString())
        #expect(throws: (any Error).self) { try other.open(sealed) }
        #expect(throws: (any Error).self) { try SecretBox(base64: "too-short") }
    }

    @Test func tokensAreRandomAndStoredHashed() throws {
        let a = Tokens.random(), b = Tokens.random()
        #expect(a != b && a.count >= 40)
        #expect(Tokens.hash(a).count == 64 && Tokens.hash(a) != a)
        #expect(Tokens.matches("same", "same") && !Tokens.matches("same", "other"))
    }

    @Test func configComesFromTheEnvironment() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(throws: ConfigError.self) { try ServerConfig.fromEnvironment(["TIDINGS_MASTER_KEY": key]) }
        #expect(throws: ConfigError.self) { try ServerConfig.fromEnvironment(["TIDINGS_PAIRING_SECRET": "short", "TIDINGS_MASTER_KEY": key]) }
        let config = try ServerConfig.fromEnvironment([
            "TIDINGS_PAIRING_SECRET": Fixtures.secret, "TIDINGS_MASTER_KEY": key, "TIDINGS_DATA_DIR": "/tmp/x", "PORT": "9090",
            "APNS_KEY_P8": "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----", "APNS_KEY_ID": "KEY123",
        ])
        #expect(config.port == 9090)
        #expect(config.dataDirectory.path == "/tmp/x")
        #expect(config.apns?.teamID == "493257NQK3")
        #expect(config.apns?.topic == "hk.gnus.tidings")
        #expect(config.apns?.privateKeyPEM.contains("\nabc\n") == true)
    }
}

@Suite struct APITests {
    @Test func pairingNeedsTheSecretAndEveryOtherCallAToken() async throws {
        let engine = try PushEngine(config: try Fixtures.config(), sender: RecordingSender(), logger: Logger(label: "test"))
        let app = Application(router: PushServerAPI.router(engine: engine, limiter: PairingLimiter(maxFailures: 3)))
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/status", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/devices", method: .post,
                                     body: try Fixtures.json(PushAPI.PairRequest(secret: "wrong", deviceName: "x"))) {
                #expect($0.status == .unauthorized)
            }
            let paired = try await client.execute(uri: "/v1/devices", method: .post,
                                                  body: try Fixtures.json(PushAPI.PairRequest(secret: Fixtures.secret, deviceName: "iPhone"))) {
                #expect($0.status == .created)
                return try Fixtures.decode(PushAPI.PairResponse.self, $0.body)
            }
            let auth: HTTPFields = [.authorization: "Bearer \(paired.token)"]
            try await client.execute(uri: "/v1/devices/me", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.DeviceUpdate(apnsToken: "not hex", environment: .sandbox))) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(uri: "/v1/devices/me", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.DeviceUpdate(apnsToken: String(repeating: "ab", count: 32),
                                                                                  environment: .sandbox))) {
                #expect($0.status == .noContent)
            }
            // Plain-text IMAP to anything but the local test server is refused, and a new
            // account needs its password.
            let record = CloudAccountRecord(AccountConfig(displayName: "x", endpoint: IMAPEndpoint(host: "imap.example.com", port: 143,
                                                                                                   useTLS: false, username: "a@example.com"),
                                                          addresses: ["a@example.com"]))
            try await client.execute(uri: "/v1/accounts/a@example.com", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.AccountUpload(record: record, password: "p"))) {
                #expect($0.status == .badRequest)
            }
            var tls = record
            tls.endpoint.useTLS = true
            try await client.execute(uri: "/v1/accounts/a@example.com", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.AccountUpload(record: tls, password: nil))) {
                #expect($0.status == .badRequest)
            }
            let status = try await client.execute(uri: "/v1/status", method: .get, headers: auth) {
                try Fixtures.decode(PushAPI.ServerStatus.self, $0.body)
            }
            #expect(status.devices == 1 && status.accounts.isEmpty && status.pushConfigured)
            try await client.execute(uri: "/v1/devices/me", method: .delete, headers: auth) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/v1/status", method: .get, headers: auth) { #expect($0.status == .unauthorized) }
            // Too many wrong guesses: pairing pauses, even with the right secret.
            for _ in 0..<3 {
                try await client.execute(uri: "/v1/devices", method: .post,
                                         body: try Fixtures.json(PushAPI.PairRequest(secret: "guess", deviceName: "x"))) { _ in }
            }
            try await client.execute(uri: "/v1/devices", method: .post,
                                     body: try Fixtures.json(PushAPI.PairRequest(secret: Fixtures.secret, deviceName: "x"))) {
                #expect($0.status == .tooManyRequests)
            }
        }
    }

    @Test func storedPasswordsAreSealed() async throws {
        let config = try Fixtures.config()
        let engine = try PushEngine(config: config, sender: RecordingSender(), logger: Logger(label: "test"))
        let record = CloudAccountRecord(AccountConfig(displayName: "x", endpoint: IMAPEndpoint(host: "127.0.0.1", port: 1, useTLS: false,
                                                                                               username: "a@example.com"),
                                                      addresses: ["a@example.com"]))
        try await engine.upsertAccount(login: "A@example.com", PushAPI.AccountUpload(record: record, password: "secret-app-password"))
        let raw = try Data(contentsOf: config.dataDirectory.appendingPathComponent("server.sqlite"))
        #expect(raw.range(of: Data("secret-app-password".utf8)) == nil)
        #expect(try engine.store.accounts().map(\.login) == ["a@example.com"])
        try await engine.removeAccount(login: "a@example.com")
        #expect(try engine.store.accounts().isEmpty)
        await engine.stop()
    }

    func record(imap: String = "127.0.0.1", tls: Bool = false, smtp: SMTPEndpoint? = nil) -> CloudAccountRecord {
        CloudAccountRecord(AccountConfig(displayName: "x", endpoint: IMAPEndpoint(host: imap, port: 1, useTLS: tls, username: "a@example.com"),
                                         addresses: ["a@example.com"], smtp: smtp))
    }

    /// A device token alone can't re-point an account at another server and collect its password.
    @Test func changingServerSettingsNeedsThePasswordAgain() async throws {
        let engine = try PushEngine(config: try Fixtures.config(), sender: RecordingSender(), logger: Logger(label: "test"))
        try await engine.upsertAccount(login: "a@example.com", PushAPI.AccountUpload(record: record(), password: "pw"))
        // The same settings without a password: fine (the app does this on every launch).
        try await engine.upsertAccount(login: "a@example.com", PushAPI.AccountUpload(record: record(), password: nil))
        // Another host, or another SMTP server, without the password: refused, nothing stored.
        await #expect(throws: PushEngine.OperationError.self) {
            try await engine.upsertAccount(login: "a@example.com", PushAPI.AccountUpload(record: record(imap: "imap.evil.test", tls: true), password: nil))
        }
        let smtp = SMTPEndpoint(host: "smtp.evil.test", port: 587, security: .startTLS, username: "a@example.com")
        await #expect(throws: PushEngine.OperationError.self) {
            try await engine.upsertAccount(login: "a@example.com", PushAPI.AccountUpload(record: record(smtp: smtp), password: nil))
        }
        #expect(try engine.store.accounts().first?.record.endpoint.host == "127.0.0.1")
        // SMTP without TLS to a real host, and private-network hosts, are refused outright.
        let plain = SMTPEndpoint(host: "smtp.example.com", port: 25, security: .none, username: "a@example.com")
        await #expect(throws: PushEngine.OperationError.self) {
            try await engine.upsertAccount(login: "b@example.com", PushAPI.AccountUpload(record: record(smtp: plain), password: "pw"))
        }
        for host in ["169.254.169.254", "10.0.0.5", "redis", "db.internal"] {
            await #expect(throws: PushEngine.OperationError.self) {
                try await engine.upsertAccount(login: "b@example.com", PushAPI.AccountUpload(record: record(imap: host, tls: true), password: "pw"))
            }
        }
        await engine.stop()
    }

    @Test func allowListLimitsMailHosts() async throws {
        var config = try Fixtures.config()
        config.allowedMailHosts = ["imap.mail.me.com", "smtp.mail.me.com"]
        let engine = try PushEngine(config: config, sender: RecordingSender(), logger: Logger(label: "test"))
        await #expect(throws: PushEngine.OperationError.self) {
            try await engine.upsertAccount(login: "a@example.com", PushAPI.AccountUpload(record: record(imap: "imap.example.com", tls: true), password: "pw"))
        }
        try await engine.checkMailHost("imap.mail.me.com")
        await engine.stop()
    }

    @Test func passwordsAreBoundToTheirAccount() throws {
        let box = try SecretBox(base64: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())
        let sealed = try box.seal("pw", context: "a@example.com")
        #expect(try box.open(sealed, context: "a@example.com") == "pw")
        #expect(throws: (any Error).self) { try box.open(sealed, context: "b@example.com") }
        // Sealed before contexts existed: still opens.
        #expect(try box.open(try box.seal("old"), context: "a@example.com") == "old")
    }

    @Test func devicesCanBeListedAndRevokedAndRotatingTheSecretRetiresThem() async throws {
        let config = try Fixtures.config()
        let engine = try PushEngine(config: config, sender: RecordingSender(), logger: Logger(label: "test"))
        let app = Application(router: PushServerAPI.router(engine: engine))
        try await app.test(.router) { client in
            func pair(_ name: String) async throws -> PushAPI.PairResponse {
                try await client.execute(uri: "/v1/devices", method: .post,
                                         body: try Fixtures.json(PushAPI.PairRequest(secret: Fixtures.secret, deviceName: name))) {
                    try Fixtures.decode(PushAPI.PairResponse.self, $0.body)
                }
            }
            let phone = try await pair("iPhone"), lost = try await pair("Old iPad")
            let auth: HTTPFields = [.authorization: "Bearer \(phone.token)"]
            let listed = try await client.execute(uri: "/v1/devices", method: .get, headers: auth) {
                try Fixtures.decode([PushAPI.DeviceInfo].self, $0.body)
            }
            #expect(Set(listed.map(\.name)) == ["iPhone", "Old iPad"])
            #expect(listed.first { $0.isCurrent }?.id == phone.deviceID)
            try await client.execute(uri: "/v1/devices/\(lost.deviceID)", method: .delete, headers: auth) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/v1/status", method: .get, headers: [.authorization: "Bearer \(lost.token)"]) {
                #expect($0.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/status", method: .get, headers: auth) { #expect($0.status == .ok) }
        }
        await engine.stop()
        // A new pairing secret: devices paired under the old one stop working.
        var rotated = config
        rotated.pairingSecret = "a-completely-new-pairing-secret"
        let engine2 = try PushEngine(config: rotated, sender: RecordingSender(), logger: Logger(label: "test"))
        let device = try #require(try engine2.store.devices().first)
        #expect(device.secretTag != Tokens.secretTag(rotated.pairingSecret))
        await engine2.stop()
    }

    @Test func parallelGuessesAllCount() async {
        let limiter = PairingLimiter(maxFailures: 5)
        var allowed = 0
        for _ in 0..<50 where await limiter.begin(client: "1.2.3.4") { allowed += 1 }
        #expect(allowed == 5)
        // Another client still gets its own tries, up to the shared ceiling.
        #expect(await limiter.begin(client: "5.6.7.8"))
    }
}
