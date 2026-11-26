import Foundation
import Testing
@testable import MailEngine

/// Triage against a fresh, seeded Dovecot user per test, with iCloud's quirks simulated
/// (no MOVE: every move goes through COPY + \Deleted + UID EXPUNGE).
@Suite(.serialized) struct TriageIntegrationTests {
    struct Fixture {
        let sync: AccountSync
        let store: MailStore
        let endpoint: IMAPEndpoint
        let dir: URL

        /// UID → flags on the server for one mailbox.
        func server(_ mailbox: String) async throws -> [UInt32: [String]] {
            try await MailSession.open(endpoint: endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
                let boxes = try await session.listMailboxes()
                guard boxes.contains(where: { $0.path == mailbox }) else { return [:] }
                _ = try await session.select(mailbox, readOnly: true)
                return Dictionary(uniqueKeysWithValues: try await session.fetchSummaries().map { ($0.uid, $0.flags) })
            }
        }

        func inbox() throws -> [ThreadSummary] {
            try store.threads(mailbox: "INBOX", ownAddresses: [TestMailFactory.me.address])
        }

        func thread(_ subject: String) throws -> ThreadSummary {
            try #require(try inbox().first { $0.latest.subject.contains(subject) })
        }
    }

    func fixture() async throws -> Fixture? {
        guard (try? await MailSession.probeGreeting(endpoint: IMAPIntegrationTests.endpoint)) != nil else { return nil }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "triage-\(UUID().uuidString.prefix(8))")
        _ = try await TestServerSeeder.seed(endpoint: endpoint, password: "tidings-test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-triage-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "t", displayName: "T", endpoint: endpoint, addresses: [TestMailFactory.me.address])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: .iCloudSimulation)
        try await sync.syncOnce()
        return Fixture(sync: sync, store: store, endpoint: endpoint, dir: dir)
    }

    /// A change the server refuses holds back only later changes to the same messages: Done on
    /// another conversation still goes through in the same pass.
    @Test func aRefusedChangeOnlyHoldsBackItsOwnMessages() async throws {
        guard let f = try await fixture() else { return }
        let threads = try f.inbox()
        let stuck = try #require(threads.first)
        let other = try #require(threads.first { $0.threadID != stuck.threadID })
        let archiveBefore = try await f.server("Archive").count

        try await f.sync.perform(.move(toMailbox: "No Such Folder"), threadIDs: [stuck.threadID], from: "INBOX")
        try await f.sync.perform(.pin, threadIDs: [stuck.threadID])
        try await f.sync.perform(.done, threadIDs: [other.threadID])
        try await f.sync.processPendingActions()

        #expect(try await f.server("Archive").count == archiveBefore + other.messageCount, "Done went through")
        let left = try f.store.pendingActions(accountID: "t")
        #expect(left.count == 2, "the refused move and the pin behind it wait")
        #expect(left.map(\.attempts).sorted() == [0, 1], "only the refused move used a try")
    }

    @Test func doneMovesConversationToArchiveOnServer() async throws {
        guard let f = try await fixture() else { return }
        let dinner = try f.thread("Middag")
        let inboxBefore = try await f.server("INBOX").count
        let archiveBefore = try await f.server("Archive").count

        let change = try #require(try await f.sync.perform(.done, threadIDs: [dinner.threadID]))
        #expect(change.threadCount == 1)
        #expect(try f.inbox().contains { $0.threadID == dinner.threadID } == false, "leaves the stream immediately")

        try await f.sync.processPendingActions()
        #expect(try await f.server("INBOX").count == inboxBefore - 2, "both inbox messages of the thread moved")
        #expect(try await f.server("Archive").count == archiveBefore + 2)
        #expect(try f.store.pendingActions(accountID: "t").isEmpty)

        // Local rows now carry the real Archive UIDs, so a re-sync adds nothing.
        let total = try f.store.count()
        try await f.sync.syncOnce()
        #expect(try f.store.count() == total)
    }

    @Test func undoBeforeServerCancelsWithoutTouchingServer() async throws {
        guard let f = try await fixture() else { return }
        let dinner = try f.thread("Middag")
        let serverBefore = try await f.server("INBOX")
        let change = try #require(try await f.sync.perform(.done, threadIDs: [dinner.threadID]))
        try await f.sync.undo(change)
        #expect(try f.store.pendingActions(accountID: "t").isEmpty)
        #expect(try f.inbox().contains { $0.threadID == dinner.threadID })
        try await f.sync.processPendingActions()
        #expect(try await f.server("INBOX") == serverBefore)
    }

    @Test func undoAfterServerMovesBack() async throws {
        guard let f = try await fixture() else { return }
        let dinner = try f.thread("Middag")
        let inboxCount = try await f.server("INBOX").count
        let change = try #require(try await f.sync.perform(.done, threadIDs: [dinner.threadID]))
        try await f.sync.processPendingActions()
        try await f.sync.undo(change)
        #expect(try f.inbox().contains { $0.threadID == dinner.threadID }, "back in the stream immediately")
        try await f.sync.processPendingActions()
        #expect(try await f.server("INBOX").count == inboxCount)
        let total = try f.store.count()
        try await f.sync.syncOnce()
        #expect(try f.store.count() == total, "no duplicates after the round trip")
    }

    @Test func moveToFolderAndBack() async throws {
        guard let f = try await fixture() else { return }
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { try await $0.create("Projects") }
        try await f.sync.syncOnce()
        let dinner = try f.thread("Middag")
        let inboxCount = try await f.server("INBOX").count

        #expect(try await f.sync.perform(.move(toMailbox: "INBOX"), threadIDs: [dinner.threadID]) == nil, "moving to where it already is does nothing")
        let change = try #require(try await f.sync.perform(.move(toMailbox: "Projects"), threadIDs: [dinner.threadID]))
        #expect(try f.inbox().contains { $0.threadID == dinner.threadID } == false)
        #expect(try f.store.threads(mailbox: "Projects").contains { $0.threadID == dinner.threadID })
        try await f.sync.processPendingActions()
        #expect(try await f.server("Projects").count == 2)
        #expect(try await f.server("INBOX").count == inboxCount - 2)

        try await f.sync.undo(change)
        try await f.sync.processPendingActions()
        #expect(try await f.server("Projects").isEmpty)
        #expect(try await f.server("INBOX").count == inboxCount)
        let total = try f.store.count()
        try await f.sync.syncOnce()
        #expect(try f.store.count() == total, "no duplicates after the round trip")
    }

    @Test func pinAndReadSetServerFlags() async throws {
        guard let f = try await fixture() else { return }
        let sofie = try f.thread("website")
        try await f.sync.perform(.pin, threadIDs: [sofie.threadID])
        try await f.sync.perform(.markRead, threadIDs: [sofie.threadID])
        #expect(try f.thread("website").isPinned)
        #expect(try f.thread("website").unreadCount == 0)
        try await f.sync.processPendingActions()
        let flags = try #require(try await f.server("INBOX")[sofie.latest.uid])
        #expect(flags.contains("\\Flagged"))
        #expect(flags.contains("\\Seen"))

        try await f.sync.perform(.unpin, threadIDs: [sofie.threadID])
        try await f.sync.processPendingActions()
        #expect(try await f.server("INBOX")[sofie.latest.uid]?.contains("\\Flagged") == false)
    }

    /// Reply Later (L) is a keyword on the newest message: it must survive the push to the
    /// server and the next sync, or the conversation drops back into the stream.
    @Test func replyLaterSurvivesTheNextSync() async throws {
        guard let f = try await fixture() else { return }
        let sofie = try f.thread("website")
        try await f.sync.perform(.replyLater, threadIDs: [sofie.threadID])
        #expect(try f.thread("website").isReplyLater)
        try await f.sync.processPendingActions()
        let flags = try #require(try await f.server("INBOX")[sofie.latest.uid])
        #expect(flags.contains(replyLaterKeyword))
        try await f.sync.syncOnce()
        #expect(try f.thread("website").isReplyLater)
    }

    /// iCloud answers OK to our keywords on Inbox mail but doesn't store them. Once that's been
    /// seen, a sync keeps our keywords locally; on servers that keep them, server truth wins.
    @Test func ourKeywordsStayLocalOnServersThatDropThem() async throws {
        guard let f = try await fixture() else { return }
        let sofie = try f.thread("website")
        try await f.sync.perform(.replyLater, threadIDs: [sofie.threadID])
        try await f.sync.processPendingActions()
        #expect(await f.sync.serverKeepsKeywords() == true)   // Dovecot keeps them

        // The keyword vanishes on the server, as it does on iCloud.
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
            _ = try await session.select("INBOX")
            try await session.store(uids: [sofie.latest.uid], .remove, flags: [replyLaterKeyword])
        }

        try f.store.setSetting(AccountSync.keepsKeywordsKey, "false", accountID: "t")
        try await f.sync.syncOnce()
        #expect(try f.thread("website").isReplyLater)

        try f.store.setSetting(AccountSync.keepsKeywordsKey, "true", accountID: "t")
        try await f.sync.syncOnce()
        #expect(try f.thread("website").isReplyLater == false)
    }

    @Test func snoozeRoundTripsThroughServerKeywords() async throws {
        guard let f = try await fixture() else { return }
        let sofie = try f.thread("website")
        let wake = Date().addingTimeInterval(3600).rounded()
        try await f.sync.perform(.snooze(until: wake), threadIDs: [sofie.threadID])
        #expect(try f.inbox().contains { $0.threadID == sofie.threadID } == false)
        try await f.sync.processPendingActions()

        let snoozed = try await f.server(AccountSync.snoozedMailbox)
        #expect(snoozed.count == 1)
        #expect(snoozed.values.first?.contains(SnoozeKeywords.marker) == true)

        // A brand-new store (fresh install / another device) learns the wake time from the keywords.
        let fresh = try MailStore(path: f.dir.appendingPathComponent("fresh.sqlite").path)
        let other = AccountSync(account: await f.sync.account, password: "tidings-test", store: fresh,
                                cache: MessageCache(directory: f.dir.appendingPathComponent("cache2")), profile: .iCloudSimulation)
        try await other.syncOnce()
        let restored = try #require(try fresh.threads(mailbox: AccountSync.snoozedMailbox).first)
        #expect(restored.snoozedUntil == wake)
    }

    @Test func dueSnoozeWakesToTopOfInboxWithoutKeywords() async throws {
        guard let f = try await fixture() else { return }
        let contract = try f.thread("Kontrakt")   // a day old: normally far down the stream
        try await f.sync.perform(.snooze(until: Date().addingTimeInterval(-1)), threadIDs: [contract.threadID])
        try await f.sync.processPendingActions()
        try await f.sync.wakeDueSnoozes()
        try await f.sync.processPendingActions()

        let top = try #require(try f.inbox().first)
        #expect(top.threadID == contract.threadID, "a returned snooze sorts as new mail")
        let flags = try #require(try await f.server("INBOX").values.first { $0.contains("\\Flagged") })
        #expect(SnoozeKeywords.all(in: flags).isEmpty)
        #expect(try await f.server(AccountSync.snoozedMailbox).isEmpty)
    }

    @Test func syncWhileActionIsQueuedNeitherDuplicatesNorReverts() async throws {
        guard let f = try await fixture() else { return }
        let dinner = try f.thread("Middag")
        let sofie = try f.thread("website")
        try await f.sync.perform(.done, threadIDs: [dinner.threadID])
        try await f.sync.perform(.markRead, threadIDs: [sofie.threadID])
        let total = try f.store.count()

        // Sync runs before the queue drains: the server still has the old state.
        try await f.sync.syncOnceWithoutDraining()
        #expect(try f.store.count() == total, "the moved messages are not re-added from the server INBOX")
        #expect(try f.inbox().contains { $0.threadID == dinner.threadID } == false)
        #expect(try f.thread("website").unreadCount == 0, "the local read state is not reverted")
    }

    @Test func interruptedMoveResumesWithoutDuplicate() async throws {
        guard let f = try await fixture() else { return }
        let sofie = try f.thread("website")
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
            _ = try await session.select("INBOX")
            // Simulate a crash after COPY + STORE \Deleted, before EXPUNGE.
            try await session.run(.uidCopy(MailSession.uidSet([sofie.latest.uid])!, .init(.init(string: "Archive"))), name: "COPY")
            try await session.store(uids: [sofie.latest.uid], .add, flags: ["\\Deleted"])
            let before = try await session.fetchSummaries().count
            // The retry skips the COPY and only expunges.
            try await session.move(uids: [sofie.latest.uid], to: "Archive")
            #expect(try await session.fetchSummaries().count == before - 1)
        }
        let archive = try await f.server("Archive")
        #expect(archive.count == 13, "12 seeded + exactly one copy")
    }
}

extension Date {
    /// Whole seconds, as stored in the wake keyword.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

extension AccountSync {
    /// Test hook: a sync pass that leaves the action queue alone.
    func syncOnceWithoutDraining() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            for path in ["INBOX", "Archive"] {
                try await self.syncMailbox(session, path: path, role: path == "INBOX" ? .inbox : .archive)
            }
        }
    }
}
