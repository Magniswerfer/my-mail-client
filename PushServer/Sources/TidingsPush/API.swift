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

        router.get("health") { _, _ in "ok" }

        router.post("v1/devices") { request, context -> Response in
            guard await limiter.allow() else { throw HTTPError(.tooManyRequests) }
            let body = try await decode(PushAPI.PairRequest.self, request)
            guard Tokens.matches(body.secret, secret) else {
                await limiter.failed()
                context.logger.warning("pairing refused")
                throw HTTPError(.unauthorized)
            }
            let (device, token) = try store.addDevice(name: body.deviceName)
            context.logger.info("device paired", metadata: ["device": "\(device.id)"])
            return try json(PushAPI.PairResponse(deviceID: device.id, token: token), status: .created)
        }

        let api = router.group("v1")
        api.put("devices/me") { request, context -> HTTPResponse.Status in
            let device = try authenticate(request, store)
            let body = try await decode(PushAPI.DeviceUpdate.self, request)
            guard body.apnsToken.count >= 32, body.apnsToken.count <= 200,
                  body.apnsToken.allSatisfy(\.isHexDigit) else { throw HTTPError(.badRequest, message: "apnsToken must be hex") }
            try store.setPushToken(deviceID: device.id, token: body.apnsToken.lowercased(), environment: body.environment.rawValue)
            return .noContent
        }
        api.delete("devices/me") { request, context -> HTTPResponse.Status in
            let device = try authenticate(request, store)
            try store.removeDevice(id: device.id)
            context.logger.info("device unpaired", metadata: ["device": "\(device.id)"])
            return .noContent
        }
        api.put("accounts/:login") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store)
            let login = try context.parameters.require("login")
            let body = try await decode(PushAPI.AccountUpload.self, request)
            try await map { try await engine.upsertAccount(login: login, body) }
            return .noContent
        }
        api.delete("accounts/:login") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store)
            try await map { try await engine.removeAccount(login: try context.parameters.require("login")) }
            return .noContent
        }
        api.put("state") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store)
            let body = try await decode(PushAPI.StateUpload.self, request, limit: 16 << 20)
            try await engine.applyState(body.records)
            return .noContent
        }
        api.put("scheduled/:id") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store)
            let id = try context.parameters.require("id")
            let body = try await decode(PushAPI.ScheduledSend.self, request, limit: 40 << 20)
            try await map { try await engine.schedule(id: id, body) }
            return .noContent
        }
        api.delete("scheduled/:id") { request, context -> HTTPResponse.Status in
            _ = try authenticate(request, store)
            let id = try context.parameters.require("id")
            let cancelled = try await map { try await engine.cancelScheduled(id: id) }
            guard cancelled else { throw HTTPError(.conflict, message: "already sending or sent") }
            return .noContent
        }
        api.get("status") { request, context -> Response in
            _ = try authenticate(request, store)
            return try json(try await engine.status())
        }
        return router
    }

    // MARK: Helpers

    static func authenticate(_ request: Request, _ store: ServerStore) throws -> ServerStore.Device {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let device = try store.device(token: String(header.dropFirst("Bearer ".count))) else {
            throw HTTPError(.unauthorized)
        }
        return device
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

/// Slows down guessing the pairing secret: after 5 wrong tries, pairing waits a minute.
public actor PairingLimiter {
    var failures: [Date] = []
    let window: TimeInterval
    let maxFailures: Int

    public init(maxFailures: Int = 5, window: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.window = window
    }

    func allow(now: Date = Date()) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) > window }
        return failures.count < maxFailures
    }

    func failed(now: Date = Date()) { failures.append(now) }
}
