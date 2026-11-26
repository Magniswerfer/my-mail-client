import Foundation
import Testing
@testable import MailEngine

/// Incremental sync (RFC 7162) against the local Dovecot, which has CONDSTORE and QRESYNC.
/// Each test runs as a server with QRESYNC, with CONDSTORE only, and with neither (capabilities
/// hidden through the profile); "another client" is a second connection changing the mailbox.
@Suite(.serialized) struct IncrementalSyncTests {
    enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case qresync, condStore, none

        var testDescription: String { rawValue }

        var profile: ServerProfile {
            var profile = ServerProfile.generic
            switch self {
            case .qresync: break
            case .condStore: profile.ignoredCapabilities = ["QRESYNC"]
            case .none: profile.ignoredCapabilities = ["QRESYNC", "CONDSTORE"]
            }
            return profile
        }

        /// The pass a changed mailbox should get.
        func changed(uidCheck: Bool = false) -> AccountSync.MailboxPass {
            switch self {
            case .qresync: .changes(vanished: true, uidCheck: uidCheck)
            case .condStore: .changes(vanished: false, uidCheck: uidCheck)
            case .none: .full
            }
        }

        var unchanged: AccountSync.MailboxPass { self == .none ? .full : .skipped }
    }

    struct Fixture {
        let sync: AccountSync
        let store: MailStore
        let endpoint: IMAPEndpoint
        let folder: String

        /// Another client, changing things on the server.
        func other<T: Sendable>(_ body: (MailSession) async throws -> T) async throws -> T {
            try await MailSession.open(endpoint: endpoint, password: "tidings-test", profile: .generic) { try await body($0) }
        }

        func local(_ mailbox: String = "INBOX") throws -> [UInt32: String] {
            try store.knownFlags(accountID: "i", mailbox: mailbox)
        }

        /// One message's stored flags, without the session-bound \Recent.
        func flags(_ uid: UInt32) throws -> Set<String> {
            Set(try local()[uid]?.split(separator: " ").map(String.init) ?? []).subtracting(["\\Recent"])
        }

        func subjects(_ mailbox: String = "INBOX") throws -> Set<String> {
            Set(try store.threads(mailbox: mailbox).map(\.latest.subject))
        }

        func uid(_ subject: String) throws -> UInt32 {
            try #require(try store.threads(mailbox: "INBOX").first { $0.latest.subject == subject }?.latest.uid)
        }
    }

    static func raw(_ subject: String) -> Data {
        Data("""
            From: Anna Jensen <anna@example.com>\r
            To: me@example.com\r
            Subject: \(subject)\r
            Date: Mon, 2 Nov 2026 10:00:00 +0100\r
            Message-ID: <\(UUID().uuidString)@example.com>\r
            \r
            \(subject).\r

            """.utf8)
    }

    func fixture(_ mode: Mode, port: UInt16 = 31143) async throws -> Fixture? {
        let probe = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: "")
        guard (try? await MailSession.probeGreeting(endpoint: probe)) != nil else { return nil }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: "incr-\(UUID().uuidString.prefix(8))")
        let folder = try await MailSession.open(endpoint: endpoint, password: "tidings-test", profile: .generic) { session in
            for subject in ["One", "Two", "Three", "Four"] {
                _ = try await session.append(to: "INBOX", message: Self.raw(subject))
            }
            // Folders live under INBOX. on the namespace server.
            let prefix = AccountSync.personalPrefix(in: try await session.listMailboxes())
            let folder = prefix + "Projects"
            try await session.ensureMailbox(folder)
            _ = try await session.append(to: folder, message: Self.raw("Plan"))
            return folder
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-incr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "i", displayName: "I", endpoint: endpoint, addresses: ["me@example.com"])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: mode.profile)
        try await sync.syncOnce()
        #expect(await sync.lastPass["INBOX"] == .full, "a first sync reads everything")
        return Fixture(sync: sync, store: store, endpoint: endpoint, folder: folder)
    }

    @Test(arguments: Mode.allCases) func newMailArrives(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        try await f.other { _ = try await $0.append(to: "INBOX", message: Self.raw("Fresh")) }
        try await f.sync.syncOnce()
        #expect(try f.subjects().contains("Fresh"))
        #expect(try f.local().count == 5)
        #expect(await f.sync.lastPass["INBOX"] == mode.changed())
        #expect(await f.sync.lastPass[f.folder] == mode.unchanged)
    }

    @Test(arguments: Mode.allCases) func flagChangesFromAnotherClient(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        let two = try f.uid("Two"), three = try f.uid("Three")
        try await f.other { session in
            _ = try await session.select("INBOX")
            try await session.store(uids: [two], .add, flags: ["\\Flagged", "\\Seen"])
            try await session.store(uids: [three], .add, flags: ["$Label1"])
        }
        try await f.sync.syncOnce()
        #expect(try f.local()[two] == "\\Flagged \\Seen")
        #expect(try f.local()[three] == "$Label1")
        #expect(await f.sync.lastPass["INBOX"] == mode.changed())

        // And back.
        try await f.other { session in
            _ = try await session.select("INBOX")
            try await session.store(uids: [two], .remove, flags: ["\\Flagged"])
        }
        try await f.sync.syncOnce()
        #expect(try f.local()[two] == "\\Seen")
    }

    @Test(arguments: Mode.allCases) func expungesFromAnotherClient(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        let one = try f.uid("One"), four = try f.uid("Four")
        try await f.other { session in
            _ = try await session.select("INBOX")
            try await session.expunge(uids: [one, four])
        }
        try await f.sync.syncOnce()
        #expect(try f.subjects() == ["Two", "Three"])
        // CONDSTORE learns of the expunge from the count and finds it by comparing UIDs.
        #expect(await f.sync.lastPass["INBOX"] == mode.changed(uidCheck: mode == .condStore))
    }

    @Test(arguments: Mode.allCases) func expungeAndNewMailTogether(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        let two = try f.uid("Two")
        try await f.other { session in
            _ = try await session.select("INBOX")
            try await session.expunge(uids: [two])
            _ = try await session.append(to: "INBOX", message: Self.raw("Replacement"))
        }
        try await f.sync.syncOnce()
        #expect(try f.subjects() == ["One", "Three", "Four", "Replacement"])
    }

    @Test(arguments: Mode.allCases) func uidValidityChangeStartsOver(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        #expect(try f.subjects(f.folder) == ["Plan"])
        let before = try #require(try f.store.mailboxStates(accountID: "i").first { $0.path == f.folder }?.uidValidity)
        // Deleting and re-creating a folder gives it a new UIDVALIDITY (and UIDs start at 1 again).
        try await Task.sleep(for: .seconds(1.1))
        try await f.other { session in
            try await session.delete(f.folder)
            try await session.create(f.folder)
            _ = try await session.append(to: f.folder, message: Self.raw("After reset"))
        }
        try await f.sync.syncOnce()
        let after = try #require(try f.store.mailboxStates(accountID: "i").first { $0.path == f.folder }?.uidValidity)
        #expect(after != before)
        #expect(try f.subjects(f.folder) == ["After reset"])
        #expect(await f.sync.lastPass[f.folder] == .full)
    }

    @Test(arguments: Mode.allCases) func unchangedMailboxesAreSkipped(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        try await f.sync.syncOnce()
        let passes = await f.sync.lastPass
        #expect(passes.count >= 2)
        for (path, pass) in passes {
            #expect(pass == mode.unchanged, "\(path)")
        }
        #expect(try f.local().count == 4)
    }

    @Test(arguments: [Mode.qresync, .condStore]) func localDriftIsRepaired(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        // A row lost locally (as an abandoned queued move leaves it) while the server is unchanged.
        try f.store.deleteMessages(accountID: "i", mailbox: "INBOX", uids: [try f.uid("Three")])
        try await f.sync.syncOnce()
        #expect(try f.subjects().contains("Three"), "the count check notices and brings it back")
        #expect(await f.sync.lastPass["INBOX"] == mode.changed(uidCheck: true))
    }

    @Test(arguments: [Mode.qresync, .condStore]) func inFlightMessageIsLookedAtAgain(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        let two = try f.uid("Two")
        let thread = try #require(try f.store.threads(mailbox: "INBOX").first { $0.latest.uid == two }?.threadID)
        // Another client reads and flags it...
        try await f.other { session in
            _ = try await session.select("INBOX")
            try await session.store(uids: [two], .add, flags: ["\\Seen", "\\Flagged"])
        }
        // ...while our own Mark Read for it is still queued: sync leaves it alone.
        _ = try await f.sync.perform(.markRead, threadIDs: [thread])
        try await f.sync.syncWithoutDraining(["INBOX"])
        #expect(try f.flags(two) == ["\\Seen"], "the optimistic local state stays")
        // Our STORE changes nothing on the server (it's already \Seen), so the message's MODSEQ
        // doesn't move: sync must still pick up the \Flagged it skipped.
        try await f.sync.processPendingActions()
        try await f.sync.syncOnce()
        #expect(try f.flags(two) == ["\\Flagged", "\\Seen"])
    }

    @Test(arguments: [Mode.qresync, .condStore]) func rulesSeeIncrementallySyncedMail(_ mode: Mode) async throws {
        guard let f = try await fixture(mode) else { return }
        #expect(try f.store.ruleCandidates(accountID: "i").messages.isEmpty, "mail from the first sync was already there")
        try await f.other { _ = try await $0.append(to: "INBOX", message: Self.raw("Arrived later")) }
        try await f.sync.syncOnce()
        #expect(try f.store.ruleCandidates(accountID: "i").messages.map(\.subject) == ["Arrived later"])
    }

    @Test func namespaceServerSyncsIncrementally() async throws {
        guard let port = ProcessInfo.processInfo.environment["TIDINGS_NAMESPACE_PORT"].flatMap(UInt16.init),
              let f = try await fixture(.qresync, port: port) else { return }
        #expect(f.folder == "INBOX.Projects")
        try await f.other { _ = try await $0.append(to: f.folder, message: Self.raw("Second plan")) }
        try await f.sync.syncOnce()
        #expect(try f.subjects(f.folder) == ["Plan", "Second plan"])
        #expect(await f.sync.lastPass[f.folder] == .changes(vanished: true, uidCheck: false))
        #expect(await f.sync.lastPass["INBOX"] == .skipped)
    }

    @Test func uidRangesMergeAndLookUp() {
        let ranges = UIDRanges([5...9, 1...3, 4...4, 20...20, 15...16])
        #expect(ranges.ranges == [1...9, 15...16, 20...20])
        #expect(ranges.count == 12)
        #expect(ranges.contains(1) && ranges.contains(9) && ranges.contains(16) && ranges.contains(20))
        #expect(!ranges.contains(10) && !ranges.contains(0) && !ranges.contains(21))
        #expect(UIDRanges([1...UInt32.max, 5...6]).ranges == [1...UInt32.max])
    }
}

extension AccountSync {
    /// Test hook: syncs these mailboxes and leaves the action queue alone.
    func syncWithoutDraining(_ paths: [String]) async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            for path in paths {
                try await self.syncMailbox(session, path: path, role: path == "INBOX" ? .inbox : nil)
            }
        }
    }
}
