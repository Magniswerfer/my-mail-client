#if canImport(OSLog)
import OSLog
#endif

/// Sync diagnostics in the unified log (subsystem `hk.gnus.tidings`): what we change on the
/// server (`sync`), what goes to and comes from CloudKit (`cloud`). Only mailbox names, UIDs,
/// flags and record counts; never addresses, subjects or bodies.
///
///     /usr/bin/log show --last 10m --predicate 'subsystem == "hk.gnus.tidings"'
public enum SyncLog {
    #if canImport(OSLog)
    private static let sync = Logger(subsystem: "hk.gnus.tidings", category: "sync")
    private static let cloudLog = Logger(subsystem: "hk.gnus.tidings", category: "cloud")
    private static let imapLog = Logger(subsystem: "hk.gnus.tidings", category: "imap")
    #endif

    /// Sign-in and connection diagnostics (already sanitized: no passwords or payloads).
    public static func imap(_ message: String) {
        #if canImport(OSLog)
        imapLog.notice("\(message, privacy: .public)")
        #endif
    }

    public static func info(_ message: String) {
        #if canImport(OSLog)
        sync.notice("\(message, privacy: .public)")
        #endif
    }

    public static func cloud(_ message: String) {
        #if canImport(OSLog)
        cloudLog.notice("\(message, privacy: .public)")
        #endif
    }
}
