import Foundation

/// Guards live tests against a real mailbox.
///
/// Every mutation goes through the fence, which only allows it when
/// 1. the mailbox is `Tidings-Test` or one of its children, and
/// 2. every target UID was found by searching for this run's `X-Tidings-Test` header.
///
/// Real mail can therefore never be flagged, moved or expunged by a test, even if a test has a bug.
public struct TestFence: Sendable {
    public static let rootMailbox = "Tidings-Test"
    public static let markerHeader = "X-Tidings-Test"

    public let runID: String
    public let session: MailSession

    public init(session: MailSession, runID: String = UUID().uuidString) {
        self.session = session
        self.runID = runID
    }

    public enum Violation: Error, CustomStringConvertible {
        case mailboxOutsideFence(String)
        case unmarkedMessages([UInt32])
        /// The mailbox named isn't the one selected, so a marker check would vouch for the wrong one.
        case mailboxNotSelected(named: String, selected: String?)

        public var description: String {
            switch self {
            case .mailboxOutsideFence(let box): "Refusing to touch mailbox '\(box)': outside \(TestFence.rootMailbox)."
            case .unmarkedMessages(let uids): "Refusing to touch UIDs \(uids): not created by this test run."
            case .mailboxNotSelected(let named, let selected):
                "Refusing to touch '\(named)': the selected mailbox is '\(selected ?? "none")'."
            }
        }
    }

    public func path(_ child: String? = nil) -> String {
        guard let child else { return Self.rootMailbox }
        return "\(Self.rootMailbox)/\(child)"
    }

    public static func isInsideFence(_ path: String) -> Bool {
        path == rootMailbox || path.hasPrefix(rootMailbox + "/") || path.hasPrefix(rootMailbox + ".")
    }

    func checkMailbox(_ path: String) throws {
        guard Self.isInsideFence(path) else { throw Violation.mailboxOutsideFence(path) }
    }

    /// Creates the fence mailbox (and an optional child), selects it, and returns its state.
    public func prepare(child: String? = nil) async throws -> SelectedMailbox {
        try await session.ensureMailbox(path())
        if let child { try await session.ensureMailbox(path(child)) }
        return try await session.select(path())
    }

    public static let syntheticBody = "Synthetic test message created by tidings-probe. Safe to delete."

    /// Builds a synthetic message carrying this run's marker.
    public func syntheticMessage(subject: String, body: String = TestFence.syntheticBody) -> Data {
        let date = Self.rfc5322Date.string(from: Date())
        let messageID = "<\(UUID().uuidString)@tidings.invalid>"
        let raw = [
            "From: Tidings Probe <probe@tidings.invalid>",
            "To: Tidings Probe <probe@tidings.invalid>",
            "Subject: \(subject)",
            "Date: \(date)",
            "Message-ID: \(messageID)",
            "\(Self.markerHeader): \(runID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "",
            body,
            "",
        ].joined(separator: "\r\n")
        return Data(raw.utf8)
    }

    public func append(subject: String, to child: String? = nil) async throws -> UInt32? {
        let target = path(child)
        try checkMailbox(target)
        return try await session.append(to: target, message: syntheticMessage(subject: subject))
    }

    /// UIDs in the currently selected mailbox that carry this run's marker.
    /// Reads the header directly: iCloud fails `UID SEARCH HEADER`.
    public func markedUIDs() async throws -> [UInt32] {
        try await session.fetchHeaderField(Self.markerHeader).filter { $0.value == runID }.keys.sorted()
    }

    /// UIDs carrying a marker from any probe run (used to clean up after interrupted runs).
    public func anyRunMarkedUIDs() async throws -> [UInt32] {
        try await session.fetchHeaderField(Self.markerHeader).filter { !$0.value.isEmpty }.keys.sorted()
    }

    private func checkMarked(_ uids: [UInt32], selected mailbox: String) async throws {
        try checkMailbox(mailbox)
        // STORE and MOVE act on the selected mailbox, which is also where `markedUIDs` looks.
        let selected = session.selected?.path
        guard selected == mailbox else { throw Violation.mailboxNotSelected(named: mailbox, selected: selected) }
        let marked = Set(try await markedUIDs())
        let unmarked = uids.filter { !marked.contains($0) }
        if !unmarked.isEmpty { throw Violation.unmarkedMessages(unmarked) }
    }

    public func store(uids: [UInt32], in mailbox: String, _ change: MailSession.FlagChange, flags: [String]) async throws {
        try await checkMarked(uids, selected: mailbox)
        try await session.store(uids: uids, change, flags: flags)
    }

    public func move(uids: [UInt32], from mailbox: String, to destination: String) async throws {
        try checkMailbox(destination)
        try await checkMarked(uids, selected: mailbox)
        try await session.move(uids: uids, to: destination)
    }

    /// Removes every probe-created message (this run or an interrupted earlier one) from the given
    /// fenced mailbox. Messages without the marker header are never touched.
    public func cleanUp(mailbox: String) async throws {
        try checkMailbox(mailbox)
        _ = try await session.select(mailbox)
        let uids = try await anyRunMarkedUIDs()
        if !uids.isEmpty { try await session.expunge(uids: uids) }
    }

    static let rfc5322Date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}
