import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The push server's HTTP API (ADR 0007), shared by the server and the apps. Every call but
/// pairing and `/health` carries `Authorization: Bearer <device token>`.
///
/// | Call | Body | Answer |
/// |---|---|---|
/// | `POST /v1/devices` | `PairRequest` | `PairResponse` |
/// | `PUT /v1/devices/me` | `DeviceUpdate` | — |
/// | `DELETE /v1/devices/me` | — | — |
/// | `PUT /v1/accounts/{login}` | `AccountUpload` | — |
/// | `DELETE /v1/accounts/{login}` | — | — |
/// | `PUT /v1/state` | `StateUpload` | — |
/// | `PUT /v1/scheduled/{id}` | `ScheduledSend` | — |
/// | `DELETE /v1/scheduled/{id}` | — | — |
/// | `GET /v1/scheduled` | — | `[String]` (ids still waiting to go out) |
/// | `GET /v1/status` | — | `ServerStatus` |
public enum PushAPI {
    public struct PairRequest: Codable, Sendable, Hashable {
        public var secret: String
        public var deviceName: String
        public init(secret: String, deviceName: String) {
            self.secret = secret
            self.deviceName = deviceName
        }
    }

    public struct PairResponse: Codable, Sendable, Hashable {
        public var deviceID: String
        public var token: String
        public init(deviceID: String, token: String) {
            self.deviceID = deviceID
            self.token = token
        }
    }

    /// Which APNs endpoint a device's token belongs to: debug builds get sandbox tokens.
    public enum PushEnvironment: String, Codable, Sendable, Hashable {
        case sandbox, production
    }

    public struct DeviceUpdate: Codable, Sendable, Hashable {
        /// Hex, as iOS hands it over.
        public var apnsToken: String
        public var environment: PushEnvironment
        public init(apnsToken: String, environment: PushEnvironment) {
            self.apnsToken = apnsToken
            self.environment = environment
        }
    }

    /// An account and, the first time or when it changes, the server's own app-specific
    /// password for it. The password is never sent back.
    /// A paired device as `GET /v1/devices` lists it (never its token).
    public struct DeviceInfo: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var createdAt: Date
        public var lastSeenAt: Date
        /// The device making the call.
        public var isCurrent: Bool
        public init(id: String, name: String, createdAt: Date, lastSeenAt: Date, isCurrent: Bool) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.isCurrent = isCurrent
        }
    }

    public struct AccountUpload: Codable, Sendable, Hashable {
        public var record: CloudAccountRecord
        public var password: String?
        public init(record: CloudAccountRecord, password: String?) {
            self.record = record
            self.password = password
        }
    }

    /// Your whole state of `MailStore.pushStateTypes`; what's missing is removed.
    public struct StateUpload: Codable, Sendable, Hashable {
        public var records: [StateRecord]
        public init(records: [StateRecord]) { self.records = records }
    }

    /// Send-later mail handed to the server.
    public struct ScheduledSend: Codable, Sendable, Hashable {
        /// The account's login.
        public var account: String
        public var sendAt: Date
        public var kind: ComposeKind
        public var message: OutgoingMessage
        public init(account: String, sendAt: Date, kind: ComposeKind, message: OutgoingMessage) {
            self.account = account
            self.sendAt = sendAt
            self.kind = kind
            self.message = message
        }
    }

    public struct AccountStatus: Codable, Sendable, Hashable {
        public var login: String
        public var hasPassword: Bool
        /// "connecting", "syncing", "idle", "failed".
        public var state: String
        public var lastSync: Date?
        public var error: String?
        public init(login: String, hasPassword: Bool, state: String, lastSync: Date?, error: String?) {
            self.login = login
            self.hasPassword = hasPassword
            self.state = state
            self.lastSync = lastSync
            self.error = error
        }
    }

    public struct ServerStatus: Codable, Sendable, Hashable {
        public var version: String
        public var pushConfigured: Bool
        public var devices: Int
        public var scheduled: Int
        public var accounts: [AccountStatus]
        public init(version: String, pushConfigured: Bool, devices: Int, scheduled: Int, accounts: [AccountStatus]) {
            self.version = version
            self.pushConfigured = pushConfigured
            self.devices = devices
            self.scheduled = scheduled
            self.accounts = accounts
        }
    }

    /// Keys of the custom part of a push, next to `aps`.
    public enum PayloadKey {
        public static let messageID = "messageID"
        /// The account's login (local account ids differ per device).
        public static let account = "account"
        /// "mail" or "wake".
        public static let kind = "kind"
    }

    /// `apns-collapse-id` for one message, so a second push for it replaces the first.
    public static func collapseID(account: String, messageID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a: stable, short, not a secret.
        for byte in "\(account.lowercased())|\(messageID)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "mail-" + String(hash, radix: 16)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// The apps' side of the API.
public struct PushServerClient: Sendable {
    public enum ClientError: Error, Sendable, Equatable {
        case badURL
        case http(Int, String)
    }

    public var baseURL: URL
    public var token: String?
    let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func pair(secret: String, deviceName: String) async throws -> PushAPI.PairResponse {
        try await call("POST", "v1/devices", body: PushAPI.PairRequest(secret: secret, deviceName: deviceName), as: PushAPI.PairResponse.self)
    }

    public func updateDevice(_ update: PushAPI.DeviceUpdate) async throws {
        try await call("PUT", "v1/devices/me", body: update)
    }

    public func unpair() async throws {
        try await call("DELETE", "v1/devices/me")
    }

    /// Every device paired with the server.
    public func devices() async throws -> [PushAPI.DeviceInfo] {
        try await call("GET", "v1/devices", as: [PushAPI.DeviceInfo].self)
    }

    /// Unpairs another device (a lost or stolen one): its token stops working at once.
    public func removeDevice(id: String) async throws {
        try await call("DELETE", "v1/devices/\(Self.pathComponent(id))")
    }

    public func putAccount(login: String, _ upload: PushAPI.AccountUpload) async throws {
        try await call("PUT", "v1/accounts/\(Self.pathComponent(login))", body: upload)
    }

    public func deleteAccount(login: String) async throws {
        try await call("DELETE", "v1/accounts/\(Self.pathComponent(login))")
    }

    public func putState(_ upload: PushAPI.StateUpload) async throws {
        try await call("PUT", "v1/state", body: upload)
    }

    public func schedule(id: String, _ send: PushAPI.ScheduledSend) async throws {
        try await call("PUT", "v1/scheduled/\(Self.pathComponent(id))", body: send)
    }

    public func cancelScheduled(id: String) async throws {
        try await call("DELETE", "v1/scheduled/\(Self.pathComponent(id))")
    }

    /// Send-later ids the server hasn't sent yet (the rest went out).
    public func scheduledIDs() async throws -> [String] {
        try await call("GET", "v1/scheduled", as: [String].self)
    }

    public func status() async throws -> PushAPI.ServerStatus {
        try await call("GET", "v1/status", as: PushAPI.ServerStatus.self)
    }

    /// https, or http to this machine only.
    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host()?.isEmpty == false
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "")
        default: return false
        }
    }

    static func pathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~@"))) ?? s
    }

    @discardableResult
    func call(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL.hasDirectoryPath ? baseURL : baseURL.appendingPathComponent("")) else {
            throw ClientError.badURL
        }
        // The pairing secret, the device token and app passwords travel here: HTTPS only,
        // except to this machine (a dev server).
        guard Self.isAllowed(url) else { throw ClientError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try PushAPI.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ClientError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return data
    }

    func call<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, as type: T.Type) async throws -> T {
        try PushAPI.decoder.decode(type, from: try await call(method, path, body: body))
    }
}
