import Foundation

/// The M0 live test: can we store app state as custom IMAP keywords on this server?
///
/// Runs entirely inside the `TestFence` on messages it creates itself.
public struct KeywordTest: Sendable {
    public struct Step: Sendable, Codable {
        public var name: String
        public var passed: Bool
        public var detail: String
        /// Reported but not required: doesn't affect whether keywords are usable.
        public var informational = false
    }

    public struct Report: Sendable, Codable {
        public var server: String
        public var capabilities: [String]
        public var steps: [Step]
        public var keywordCap: Int?
        public var passed: Bool { steps.filter { !$0.informational }.allSatisfy(\.passed) }
    }

    public var endpoint: IMAPEndpoint
    public var password: String
    /// nil = detect from host. Use `.iCloudSimulation` to run iCloud's code paths against Dovecot.
    public var profile: ServerProfile?
    /// How many extra keywords to try when probing for a cap. Kept small to be polite.
    public var capProbeLimit: Int
    public static let defaultCapProbeLimit = 40

    /// The keyword the test stores: one of ours, so it behaves like Tidings' real state.
    static let testKeyword = "$TidingsPinned"

    public init(endpoint: IMAPEndpoint, password: String, profile: ServerProfile? = nil,
                capProbeLimit: Int = KeywordTest.defaultCapProbeLimit) {
        self.profile = profile
        self.endpoint = endpoint
        self.password = password
        self.capProbeLimit = capProbeLimit
    }

    public func run(log: @Sendable (String) -> Void = { _ in }) async throws -> Report {
        let runID = "probe-" + UUID().uuidString.prefix(8).lowercased()
        let keyword = Self.testKeyword
        var steps: [Step] = []
        func record(_ name: String, _ passed: Bool, _ detail: String, informational: Bool = false) {
            steps.append(Step(name: name, passed: passed, detail: detail, informational: informational))
            log("\(passed ? "✓" : informational ? "ℹ︎" : "✗") \(name): \(detail)")
        }

        var capabilities: [String] = []
        var keywordCap: Int?
        var uid: UInt32?
        var modSeqBefore: UInt64?

        // Connection A: create, flag, move.
        try await MailSession.open(endpoint: endpoint, password: password, profile: profile) { session in
            capabilities = session.capabilities
            let fence = TestFence(session: session, runID: runID)
            let selected = try await fence.prepare(child: "Moved")
            record("PERMANENTFLAGS contains \\*", selected.acceptsArbitraryKeywords,
                   selected.permanentFlags.joined(separator: " "))

            uid = try await fence.append(subject: "Tidings keyword test \(runID)")
            _ = try await session.select(fence.path())
            let marked = try await fence.markedUIDs()
            if uid == nil { uid = marked.last }
            record("APPEND synthetic message", uid != nil, "uid=\(uid.map(String.init) ?? "nil"), marked=\(marked)")
            guard let uid else { return }

            modSeqBefore = try await session.fetchFlags(uids: [uid])[uid]?.modSeq
            try await fence.store(uids: [uid], in: fence.path(), .add, flags: [keyword])
            let after = try await session.fetchFlags(uids: [uid])[uid]
            record("STORE +FLAGS \(keyword) visible on same connection",
                   after?.flags.contains(keyword) == true, "flags=\(after?.flags ?? [])")
            if let before = modSeqBefore, let afterSeq = after?.modSeq {
                record("MODSEQ increases", afterSeq > before, "\(before) → \(afterSeq)")
            } else {
                record("MODSEQ increases", false, "no MODSEQ reported (CONDSTORE inactive?)")
            }
        }
        guard let uid else { return Report(server: endpoint.host, capabilities: capabilities, steps: steps) }

        // Connection B: is the keyword persisted and visible to a fresh session?
        try await MailSession.open(endpoint: endpoint, password: password, profile: profile) { session in
            let fence = TestFence(session: session, runID: runID)
            let selected = try await session.select(fence.path())
            let flags = try await session.fetchFlags(uids: [uid])[uid]?.flags ?? []
            record("Keyword visible from a second connection", flags.contains(keyword), "flags=\(flags)")
            // iCloud returns a fixed FLAGS list and never adds new keywords to it. Nothing in the
            // engine reads mailbox FLAGS, so this is reported only.
            record("Keyword listed in mailbox FLAGS", selected.flags.contains(keyword),
                   selected.flags.joined(separator: " "), informational: true)

            // Survives a move (COPY+EXPUNGE on iCloud).
            try await fence.move(uids: [uid], from: fence.path(), to: fence.path("Moved"))
            _ = try await session.select(fence.path("Moved"))
            let movedUIDs = try await fence.markedUIDs()
            let movedFlags = try await session.fetchFlags(uids: movedUIDs).values.flatMap(\.flags)
            record("Keyword survives move", movedFlags.contains(keyword),
                   "uids=\(movedUIDs) flags=\(Array(Set(movedFlags)).sorted())")

            // Probe for a per-mailbox keyword cap.
            if let target = movedUIDs.first {
                var accepted = 0
                for i in 0..<capProbeLimit {
                    do {
                        try await fence.store(uids: [target], in: fence.path("Moved"), .add, flags: ["$TidingsCap\(i)"])
                        accepted += 1
                    } catch {
                        keywordCap = accepted
                        break
                    }
                }
                record("Keyword cap probe", true,
                       keywordCap.map { "server refused after \($0) extra keywords" } ?? "accepted all \(accepted) extra keywords")
            }

            try await fence.cleanUp(mailbox: fence.path("Moved"))
            try await fence.cleanUp(mailbox: fence.path())
            log("cleaned up messages from run \(runID)")
        }

        return Report(server: endpoint.host, capabilities: capabilities, steps: steps, keywordCap: keywordCap)
    }
}
