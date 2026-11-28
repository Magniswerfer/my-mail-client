import Foundation
import Hummingbird
import MailEngine

/// The HTTP API (`PushAPI` describes it). Every route but pairing and `/health` needs a device
/// token. Bodies are JSON with ISO 8601 dates. Nothing secret ever comes back.
public enum PushServerAPI {
    public typealias Context = BasicRequestContext

    public static func router(engine: PushEngine, limiter: PairingLimiter = PairingLimiter()) -> Router<Context> {
        let router = Router(context: Context.self)
        let store = engine.store
        let secret = engine.config.pairingSecret
        let tag = Tokens.secretTag(secret)

        router.get("health") { _, _ in "ok" }

        router.post("v1/devices") { request, context -> Response in
            // The attempt counts before the body is read, so parallel guesses can't all slip
            // in before the first failure is recorded.
            let client = clientKey(request)
            guard await limiter.begin(client: client) else { throw HTTPError(.tooManyRequests) }
            let body = try await decode(PushAPI.PairRequest.self, request)
            guard Tokens.matches(body.secret, secret) else {
                context.logger.warning("pairing refused")
                throw HTTPError(.unauthorized)
            }
            await limiter.succeeded(client: client)
            let (device, token) = try store.addDevice(name: body.deviceName, secretTag: tag)
            context.logger.info("device paired", metadata: ["device": "\(device.id)"])
            return try json(PushAPI.PairResponse(deviceID: device.id, token: token), status: .created)
        }

        let api = router.group("v1")
        // Every paired device, so a lost or stolen one can be removed from another.
        api.get("devices") { request, context -> Response in
            let me = try authenticate(request, store, tag: tag)
            return try json(try store.devices().map {
                PushAPI.DeviceInfo(id: $0.id, name: $0.name, createdAt: $0.createdAt, lastSeenAt: $0.lastSeenAt, isCurrent: $0.id == me.id)
            })
        }
        api.delete("devices/me") { request, context -> HTTPResponse.Status in
            let me = try authenticate(request, store, tag: tag)
            try store.removeDevice(id: me.id)
            context.logger.info("device unpaired", metadata: ["device": "\(me.id)"])
            return .noContent
        }
        api.delete("devices/:id") { request, context -> HTTPResponse.Status in
            let me = try authenticate(request, store, tag: tag)
            let id = try context.parameters.require("id")
            guard try store.removeDevice(id: id) else { throw HTTPError(.notFound) }
            context.logger.info("device unpaired", metadata: ["device": "\(id)", "by": "\(me.id)"])
            return .noContent
        }
        api.put("devices/me") { request, context -> HTTPResponse.Status in
            let device = try authenticate(request, store, tag: tag)
            let body = try await decode(PushAPI.DeviceUpdate.self, request)
            guard body.apnsToken.count >= 32, body.apnsToken.count <= 200,
                  body.apnsToken.allSatisfy(\.isHexDigit) else { throw HTTPError(.badRequest, message: "apnsToken must be hex") }
            try store.setPushToken(deviceID: device.id, token: body.apnsToken.lowercased(), environment: body.environment.rawValue)
            return .noContent
        }
        api.put("accounts/:login") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store, tag: tag)
            let login = try context.parameters.require("login")
            let body = try await decode(PushAPI.AccountUpload.self, request)
            try await map { try await engine.upsertAccount(login: login, body) }
            return .noContent
        }
        api.delete("accounts/:login") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store, tag: tag)
            try await map { try await engine.removeAccount(login: try context.parameters.require("login")) }
            return .noContent
        }
        api.put("state") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store, tag: tag)
            let body = try await decode(PushAPI.StateUpload.self, request, limit: 16 << 20)
            try await engine.applyState(body.records)
            return .noContent
        }
        api.put("scheduled/:id") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store, tag: tag)
            let id = try context.parameters.require("id")
            let body = try await decode(PushAPI.ScheduledSend.self, request, limit: 40 << 20)
            try await map { try await engine.schedule(id: id, body) }
            return .noContent
        }
        api.delete("scheduled/:id") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store, tag: tag)
            let id = try context.parameters.require("id")
            let cancelled = try await map { try await engine.cancelScheduled(id: id) }
            guard cancelled else { throw HTTPError(.conflict, message: "already sending or sent") }
            return .noContent
        }
        api.get("scheduled") { request, context -> Response in
            _ = try authenticate(request, store, tag: tag)
            return try json(try store.scheduledIDs())
        }
        api.get("status") { request, context -> Response in
            _ = try authenticate(request, store, tag: tag)
            return try json(try await engine.status())
        }
        return router
    }

    // MARK: Helpers

    /// The calling device. Its token must be current and from the current pairing secret.
    static func authenticate(_ request: Request, _ store: ServerStore, tag: String) throws -> ServerStore.Device {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let device = try store.device(token: String(header.dropFirst("Bearer ".count))),
              device.secretTag == tag else {
            throw HTTPError(.unauthorized)
        }
        return device
    }

    /// Who's asking, for the pairing limiter: the address Coolify's proxy saw (the last
    /// X-Forwarded-For entry, which the proxy appends and the client can't forge).
    static func clientKey(_ request: Request) -> String {
        guard let forwarded = request.headers[.init("X-Forwarded-For")!] else { return "direct" }
        return forwarded.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "direct"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ request: Request, limit: Int = 1 << 20) async throws -> T {
        let buffer = try await request.body.collect(upTo: limit)
        do {
            return try PushAPI.decoder.decode(type, from: Data(buffer.readableBytesView))
        } catch {
            throw HTTPError(.badRequest, message: "invalid \(T.self)")
        }
    }

    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try PushAPI.encoder.encode(value)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// Engine errors as HTTP statuses.
    static func map<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as PushEngine.OperationError {
            switch error {
            case .badRequest(let message): throw HTTPError(.badRequest, message: message)
            case .notFound: throw HTTPError(.notFound)
            case .conflict(let message): throw HTTPError(.conflict, message: message)
            }
        }
    }
}

/// Slows down guessing the pairing secret: 5 unsuccessful tries per client a minute, and a
/// ceiling for everyone together (a client can change its address). Every attempt counts when
/// it starts; a successful one is given back.
public actor PairingLimiter {
    var attempts: [String: [Date]] = [:]
    var all: [Date] = []
    let window: TimeInterval
    let maxFailures: Int
    let maxTotal: Int

    public init(maxFailures: Int = 5, maxTotal: Int = 30, window: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.maxTotal = max(maxFailures, maxTotal)
        self.window = window
    }

    func begin(client: String, now: Date = Date()) -> Bool {
        all.removeAll { now.timeIntervalSince($0) > window }
        var mine = (attempts[client] ?? []).filter { now.timeIntervalSince($0) <= window }
        attempts = attempts.filter { !$0.value.isEmpty && $0.value.contains { now.timeIntervalSince($0) <= window } }
        guard mine.count < maxFailures, all.count < maxTotal else { attempts[client] = mine; return false }
        mine.append(now)
        attempts[client] = mine
        all.append(now)
        return true
    }

    func succeeded(client: String) {
        if attempts[client]?.isEmpty == false { attempts[client]?.removeLast() }
        if !all.isEmpty { all.removeLast() }
    }
}
