import Foundation
import Hummingbird
import Logging
import TidingsPush

// tidings-server: the always-on push server (ADR 0007). Configuration comes from the
// environment; see PushServer/README.md.
var logger = Logger(label: "tidings-server")
logger.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .info

do {
    let config = try ServerConfig.fromEnvironment()
    let sender: any PushSender = try config.apns.map { try APNsSender($0, logger: logger) } ?? NoPushSender()
    if !sender.isConfigured { logger.warning("APNS_KEY_P8 not set: syncing and waking snoozes, but sending no pushes") }
    let engine = try PushEngine(config: config, sender: sender, logger: logger)
    try await engine.start()
    let app = Application(router: PushServerAPI.router(engine: engine),
                          configuration: .init(address: .hostname(config.host, port: config.port), serverName: "tidings-server"),
                          logger: logger)
    try await app.runService()
    await engine.stop()
} catch {
    logger.critical("tidings-server stopped: \(error)")
    exit(1)
}
