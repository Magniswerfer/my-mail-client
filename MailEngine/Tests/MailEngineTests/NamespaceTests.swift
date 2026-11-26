import Foundation
import Testing
@testable import MailEngine

/// Servers whose folders all live under `INBOX.` (Dovecot with an `INBOX.` namespace, e.g.
/// NordicWay): a top-level "Snoozed" is refused there ("nonexistent namespace").
@Suite struct NamespaceTests {
    @Test func prefixIsFoundOnlyWhenEveryFolderIsUnderIt() {
        let dotted = [MailboxListing(path: "INBOX", separator: ".", attributes: []),
                      MailboxListing(path: "INBOX.Sent", separator: ".", attributes: []),
                      MailboxListing(path: "INBOX.Archive", separator: ".", attributes: [])]
        #expect(AccountSync.personalPrefix(in: dotted) == "INBOX.")
        let flat = [MailboxListing(path: "INBOX", separator: "/", attributes: []),
                    MailboxListing(path: "Sent Messages", separator: "/", attributes: []),
                    MailboxListing(path: "INBOX/Receipts", separator: "/", attributes: [])]
        #expect(AccountSync.personalPrefix(in: flat) == "")
        #expect(AccountSync.isSnoozedMailbox("Snoozed"))
        #expect(AccountSync.isSnoozedMailbox("INBOX.Snoozed"))
        #expect(!AccountSync.isSnoozedMailbox("Clients.Snoozed"))
        #expect(MailboxRoleResolver.role(path: "INBOX.Trash", separator: ".", attributes: []) == .trash)
        #expect(MailboxRoleResolver.role(path: "INBOX.Clients.Trash", separator: ".", attributes: []) == nil)
        #expect(MailboxRoleResolver.role(path: "Clients/Archive", separator: "/", attributes: []) == nil)
    }

    @Test func bareFolderNamesGoUnderThePrefix() {
        #expect(AccountSync.underPrefix("Receipts", "INBOX.") == "INBOX.Receipts")
        #expect(AccountSync.underPrefix("INBOX.Receipts", "INBOX.") == "INBOX.Receipts")
        #expect(AccountSync.underPrefix("inbox.Receipts", "INBOX.") == "inbox.Receipts")
        #expect(AccountSync.underPrefix("INBOX", "INBOX.") == "INBOX")
        #expect(AccountSync.underPrefix("Receipts", "") == "Receipts")
        let refusal = "UID MOVE failed: no(Client tried to access nonexistent namespace. (Mailbox name should probably be prefixed with: INBOX.) (0.001 + 0.000 secs).)"
        #expect(AccountSync.namespaceHint(in: refusal) == "INBOX.")
        #expect(AccountSync.namespaceHint(in: "UID MOVE failed: no(Mailbox doesn't exist)") == nil)
    }

    /// Against a Dovecot set up like that (see the commit for the config). Skipped unless
    /// TIDINGS_NAMESPACE_PORT points at one.
    @Test func snoozeAndSentFollowTheServer() async throws {
        guard let port = ProcessInfo.processInfo.environment["TIDINGS_NAMESPACE_PORT"].flatMap(UInt16.init) else { return }
        let user = "ns-\(UUID().uuidString.prefix(8))"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: user)
        let password = "tidings-test"
        // Seed: one message in the Inbox, three in INBOX.Sent, one in "INBOX.Sent Messages".
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            try await session.ensureMailbox("INBOX.Sent")
            try await session.ensureMailbox("INBOX.Sent Messages")
            func mail(_ n: Int) -> Data {
                Data("From: a@b.dk\r\nTo: \(user)@x.dk\r\nSubject: S\(n)\r\nMessage-ID: <ns\(n)-\(user)@x>\r\nDate: Thu, 26 Nov 2026 10:00:00 +0100\r\n\r\nHi\r\n".utf8)
            }
            _ = try await session.append(to: "INBOX", message: mail(0))
            for n in 1...3 { _ = try await session.append(to: "INBOX.Sent", message: mail(n)) }
            _ = try await session.append(to: "INBOX.Sent Messages", message: mail(9))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-ns-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(displayName: "NS", endpoint: endpoint, addresses: ["\(user)@x.dk"])
        let sync = AccountSync(account: account, password: password, store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("Cache")))
        try await sync.syncOnce()

        // The Sent role goes to the folder with the mail, not the first one listed.
        let sent = try await sync.path(for: .sent)
        #expect(sent == "INBOX.Sent")

        // Snooze: into INBOX.Snoozed, created on the way.
        let thread = try #require(try store.threads(mailbox: "INBOX").first?.threadID)
        try await sync.perform(.snooze(until: Date().addingTimeInterval(3600)), threadIDs: [thread])
        try await sync.catchUp()
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            let boxes = try await session.listMailboxes().map(\.path)
            #expect(boxes.contains("INBOX.Snoozed"))
            let snoozed = try await session.select("INBOX.Snoozed", readOnly: true).exists
            #expect(snoozed == 1)
            let inbox = try await session.select("INBOX", readOnly: true).exists
            #expect(inbox == 0)
        }

        // And back.
        try await sync.perform(.unsnooze, threadIDs: [thread])
        try await sync.catchUp()
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            let inbox = try await session.select("INBOX", readOnly: true).exists
            let snoozed = try await session.select("INBOX.Snoozed", readOnly: true).exists
            #expect(inbox == 1)
            #expect(snoozed == 0)
        }

        // Trash isn't synced, but Move to Trash still finds INBOX.Trash (not a top-level folder).
        try await sync.perform(.trash, threadIDs: [thread])
        try await sync.catchUp()
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            let trash = try await session.select("INBOX.Trash", readOnly: true).exists
            let inbox = try await session.select("INBOX", readOnly: true).exists
            #expect(trash == 1)
            #expect(inbox == 0)
            let boxes = try await session.listMailboxes().map(\.path)
            #expect(!boxes.contains("Deleted Messages"))
        }
    }

    /// A move queued to a bare folder name ("Receipts", from a rule written for another account,
    /// or queued before the prefix was known) lands in INBOX.Receipts. When the prefix isn't
    /// known yet, the server's refusal teaches it and the next attempt goes through.
    @Test func bareMoveTargetsFollowTheServer() async throws {
        guard let port = ProcessInfo.processInfo.environment["TIDINGS_NAMESPACE_PORT"].flatMap(UInt16.init) else { return }
        let user = "nsm-\(UUID().uuidString.prefix(8))"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: user)
        let password = "tidings-test"
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            try await session.ensureMailbox("INBOX.Receipts")
            for n in 1...2 {
                _ = try await session.append(to: "INBOX", message: Data("From: a@b.dk\r\nTo: \(user)@x.dk\r\nSubject: R\(n)\r\nMessage-ID: <nsm\(n)-\(user)@x>\r\nDate: Thu, 26 Nov 2026 10:00:00 +0100\r\n\r\nHi\r\n".utf8))
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-nsm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(displayName: "NS", endpoint: endpoint, addresses: ["\(user)@x.dk"])
        let sync = AccountSync(account: account, password: password, store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("Cache")))
        try await sync.syncOnce()
        let threads = try store.threads(mailbox: "INBOX").compactMap(\.threadID)
        #expect(threads.count == 2)

        // Prefix known: straight there.
        try await sync.perform(.move(toMailbox: "Receipts"), threadIDs: [threads[0]])
        try await sync.catchUp()

        // Prefix not known yet: the first attempt is refused, the second lands.
        try store.setSetting(AccountSync.personalPrefixKey, "", accountID: account.id)
        try await sync.perform(.move(toMailbox: "Receipts"), threadIDs: [threads[1]])
        try? await sync.catchUp()
        try await sync.catchUp()

        try await MailSession.open(endpoint: endpoint, password: password) { session in
            let receipts = try await session.select("INBOX.Receipts", readOnly: true).exists
            let inbox = try await session.select("INBOX", readOnly: true).exists
            #expect(receipts == 2)
            #expect(inbox == 0)
        }
        #expect(try store.pendingActions(accountID: account.id).isEmpty)
    }
}
