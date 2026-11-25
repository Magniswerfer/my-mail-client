#if canImport(OSLog)
import OSLog
#endif

/// Sync diagnostics in the unified log (subsystem `hk.gnus.tidings`, category `sync`):
/// what we change on the server, and when the server's flags undo one of our keywords.
/// Only mailbox names, UIDs and flags; never addresses, subjects or bodies.
///
///     log show --last 10m --predicate 'subsystem == "hk.gnus.tidings"'
enum SyncLog {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "hk.gnus.tidings", category: "sync")
    #endif

    static func info(_ message: String) {
        #if canImport(OSLog)
        logger.notice("\(message, privacy: .public)")
        #endif
    }
}
