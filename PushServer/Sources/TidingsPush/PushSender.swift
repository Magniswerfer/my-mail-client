import APNS
import APNSCore
import Crypto
import Foundation
import Logging
import MailEngine
import NIOPosix

/// One alert for one device.
public struct Push: Sendable, Hashable {
    public var title: String
    public var body: String
    /// Shown instead of `title` when set: a key in the app's String Catalog (so the phone shows
    /// it in its own language), with `%@` arguments.
    public var titleKey: String?
    public var titleArgs: [String] = []
    /// Groups alerts by conversation.
    public var threadID: String?
    /// A second push with the same id replaces the first.
    public var collapseID: String?
    /// The app's notification category (Done / Mark as Read buttons).
    public var category: String?
    /// Next to `aps`: `PushAPI.PayloadKey`.
    public var info: [String: String]
}

public enum PushOutcome: Sendable, Equatable {
    case sent
    /// APNs says the token is gone (app removed, token rotated): stop using it.
    case deviceGone
    case failed(String)
}

/// Sends alerts. `APNsSender` in production; tests record instead or talk to a local fake APNs.
public protocol PushSender: Sendable {
    var isConfigured: Bool { get }
    func send(_ push: Push, to token: String, environment: PushAPI.PushEnvironment) async -> PushOutcome
    func shutdown() async
}

/// Sends nothing (no APNs key configured yet); the server still syncs and wakes snoozes.
public struct NoPushSender: PushSender {
    public init() {}
    public var isConfigured: Bool { false }
    public func send(_ push: Push, to token: String, environment: PushAPI.PushEnvironment) async -> PushOutcome {
        .failed("APNs is not configured")
    }
    public func shutdown() async {}
}

/// Token-based APNs (a `.p8` key; ES256 JWTs over HTTP/2), one client per environment.
public final class APNsSender: PushSender {
    let topic: String
    let production: APNSClient<JSONDecoder, JSONEncoder>
    let sandbox: APNSClient<JSONDecoder, JSONEncoder>
    let logger: Logger

    public init(_ config: ServerConfig.APNsConfig, logger: Logger) throws {
        let key = try P256.Signing.PrivateKey(pemRepresentation: config.privateKeyPEM)
        func client(_ environment: APNSEnvironment) -> APNSClient<JSONDecoder, JSONEncoder> {
            let target = config.overrideURL.map { APNSEnvironment.custom(url: $0, port: config.overridePort ?? 443) } ?? environment
            return APNSClient(configuration: .init(authenticationMethod: .jwt(privateKey: key, keyIdentifier: config.keyID,
                                                                              teamIdentifier: config.teamID),
                                                   environment: target),
                              eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                              responseDecoder: JSONDecoder(), requestEncoder: JSONEncoder())
        }
        topic = config.topic
        production = client(.production)
        sandbox = client(.development)
        self.logger = logger
    }

    public var isConfigured: Bool { true }

    struct Payload: Encodable, Sendable {
        var info: [String: String]
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in info { try container.encode(value, forKey: Key(stringValue: key)) }
        }
    }

    public func send(_ push: Push, to token: String, environment: PushAPI.PushEnvironment) async -> PushOutcome {
        var notification = APNSAlertNotification(
            alert: .init(title: push.titleKey.map { .localized(key: $0, arguments: push.titleArgs) } ?? .raw(push.title),
                         body: .raw(push.body)),
            // Kept for a day if the phone is off; mail older than that isn't news.
            expiration: .timeIntervalSince1970InSeconds(Int(Date().timeIntervalSince1970) + 86_400),
            priority: .immediately, topic: topic, payload: Payload(info: push.info), sound: .default,
            threadID: push.threadID, category: push.category)
        notification.collapseID = push.collapseID
        do {
            _ = try await (environment == .production ? production : sandbox).sendAlertNotification(notification, deviceToken: token)
            return .sent
        } catch let error as APNSError {
            if error.responseStatus == 410 || error.reason == .unregistered || error.reason == .badDeviceToken {
                return .deviceGone
            }
            return .failed("APNs \(error.responseStatus): \(error.reason?.reason ?? "unknown")")
        } catch {
            return .failed(String(describing: error))
        }
    }

    public func shutdown() async {
        try? await production.shutdown()
        try? await sandbox.shutdown()
    }
}
