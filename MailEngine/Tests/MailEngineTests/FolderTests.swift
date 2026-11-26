import Foundation
import Testing
@testable import MailEngine

/// Folder management: create, rename, move, delete, on a plain Dovecot (folders at the top)
/// and on one whose folders all live under `INBOX.` (like NordicWay).
@Suite(.serialized) struct FolderTests {
    // MARK: Paths

    @Test func pathsUnderANamespacePrefix() throws {
        let sep: Character = "."
        #expect(FolderPath.child(named: "Receipts", of: nil, separator: sep, prefix: "INBOX.") == "INBOX.Receipts")
        #expect(FolderPath.child(named: "Acme", of: "INBOX.Clients", separator: sep, prefix: "INBOX.") == "INBOX.Clients.Acme")
        #expect(FolderPath.name(of: "INBOX.Clients.Acme", separator: sep) == "Acme")
        #expect(FolderPath.parent(of: "INBOX.Clients.Acme", separator: sep, prefix: "INBOX.") == "INBOX.Clients")
        #expect(FolderPath.parent(of: "INBOX.Clients", separator: sep, prefix: "INBOX.") == nil)
        #expect(FolderPath.depth(of: "INBOX.Clients.Acme", separator: sep, prefix: "INBOX.") == 1)
        #expect(FolderPath.depth(of: "INBOX.Clients", separator: sep, prefix: "INBOX.") == 0)
        #expect(FolderPath.renamed("INBOX.Clients.Acme", from: "INBOX.Clients", to: "INBOX.Kunder", separator: sep) == "INBOX.Kunder.Acme")
        #expect(FolderPath.renamed("INBOX.ClientsOld", from: "INBOX.Clients", to: "INBOX.Kunder", separator: sep) == nil)
        #expect(FolderPath.isWithin("INBOX.Clients.Acme", "INBOX.Clients", separator: sep))
        #expect(!FolderPath.isWithin("INBOX.Clientship", "INBOX.Clients", separator: sep))
    }

    @Test func pathsAtTheTop() throws {
        let sep: Character = "/"
        #expect(FolderPath.child(named: "Receipts", of: nil, separator: sep, prefix: "") == "Receipts")
        #expect(FolderPath.child(named: "2026", of: "Receipts", separator: sep, prefix: "") == "Receipts/2026")
        #expect(FolderPath.parent(of: "Receipts/2026", separator: sep, prefix: "") == "Receipts")
        #expect(FolderPath.parent(of: "Receipts", separator: sep, prefix: "") == nil)
        #expect(FolderPath.name(of: "Receipts/2026", separator: sep) == "2026")
        #expect(FolderPath.parent(of: "Receipts", separator: nil, prefix: "") == nil)
    }

    @Test func namesAreChecked() throws {
        #expect(try FolderPath.validated("  Kvitteringer æøå ", separator: ".") == "Kvitteringer æøå")
        #expect(throws: FolderError.invalidName) { try FolderPath.validated("   ", separator: ".") }
        #expect(throws: FolderError.invalidName) { try FolderPath.validated("inbox", separator: ".") }
        #expect(throws: FolderError.invalidName) { try FolderPath.validated("a*b", separator: ".") }
        #expect(throws: FolderError.containsSeparator(".")) { try FolderPath.validated("v1.2", separator: ".") }
        #expect(try FolderPath.validated("v1.2", separator: "/") == "v1.2")
    }

    @Test func nonASCIINamesGoOutAsModifiedUTF7() {
        #expect(String(decoding: Array(MailSession.mailboxName("INBOX.Sent").bytes), as: UTF8.self) == "INBOX.Sent")
        let encoded = MailSession.mailboxName("Kvitteringer æøå")
        #expect(String(decoding: Array(encoded.bytes), as: UTF8.self) == "Kvitteringer &AOYA+ADl-")
        #expect(String(decoding: Array(MailSession.mailboxName("R&D").bytes), as: UTF8.self) == "R&-D")
    }

    // MARK: Against Dovecot

    static let plainPort: UInt16 = 31143
    static let namespacePort: UInt16 = 31145

    static func available(_ port: UInt16) async -> Bool {
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: "probe")
        return (try? await MailSession.probeGreeting(endpoint: endpoint)) != nil
    }

    struct Fixture {
        let sync: AccountSync
        let store: MailStore
        let endpoint: IMAPEndpoint
        let prefix: String
        let separator: Character
        let password = "tidings-test"

        func serverFolders() async throws -> [String] {
            try await MailSession.open(endpoint: endpoint, password: password) { try await $0.listMailboxes().map(\.path) }
        }

        func serverCount(_ path: String) async throws -> Int {
            try await MailSession.open(endpoint: endpoint, password: password) { try await $0.select(path, readOnly: true).exists }
        }

        func localFolders() throws -> [String] { try store.mailboxStates(accountID: "folders").map(\.path) }

        func localMailbox(of subject: String) throws -> String? {
            try store.db.read { db in
                try String.fetchOne(db, sql: "SELECT mailbox FROM message WHERE subject = ?", arguments: [subject])
            }
        }
    }

    /// A fresh user with one message in the Inbox and a Sent folder, synced once.
    func fixture(port: UInt16) async throws -> Fixture? {
        guard await Self.available(port) else { return nil }
        let user = "folders-\(UUID().uuidString.prefix(8))"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: user)
        let password = "tidings-test"
        try await MailSession.open(endpoint: endpoint, password: password) { session in
            let sent = port == Self.namespacePort ? "INBOX.Sent" : "Sent"
            try await session.ensureMailbox(sent)
            let mail = Data("From: anna@example.dk\r\nTo: \(user)@x.dk\r\nSubject: Kontrakt\r\nMessage-ID: <k-\(user)@x>\r\nDate: Thu, 26 Nov 2026 10:00:00 +0100\r\n\r\nHej\r\n".utf8)
            _ = try await session.append(to: "INBOX", message: mail)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-folders-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "folders", displayName: "Folders", endpoint: endpoint, addresses: ["\(user)@x.dk"])
        let sync = AccountSync(account: account, password: password, store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("Cache")))
        try await sync.syncOnce()
        let layout = AccountSync.folderLayout(store: store, accountID: "folders")
        return Fixture(sync: sync, store: store, endpoint: endpoint, prefix: layout.prefix, separator: layout.separator ?? "/")
    }

    @Test(arguments: [plainPort, namespacePort])
    func createRenameMoveDelete(port: UInt16) async throws {
        guard let f = try await fixture(port: port) else { return }
        let sync = f.sync, p = f.prefix, s = String(f.separator)
        if port == Self.namespacePort {
            #expect(p == "INBOX.")
            #expect(f.separator == ".")
        } else {
            #expect(p == "")
        }

        // Create at the top and inside another folder.
        let clients = try await sync.createFolder(named: "Clients")
        #expect(clients == "\(p)Clients")
        let acme = try await sync.createFolder(named: "Acme", in: clients)
        #expect(acme == "\(p)Clients\(s)Acme")
        let receipts = try await sync.createFolder(named: "Kvitteringer æøå")
        #expect(receipts == "\(p)Kvitteringer æøå")
        var server = try await f.serverFolders()
        #expect(server.contains(clients) && server.contains(acme) && server.contains(receipts))
        #expect(try Set(f.localFolders()).isSuperset(of: [clients, acme, receipts]), "new folders show before the next sync")
        #expect(FolderPath.name(of: acme, separator: f.separator) == "Acme")

        // Refused: a duplicate (any case), INBOX, a name holding the separator.
        await #expect(throws: FolderError.alreadyExists("\(p)clients")) { try await sync.createFolder(named: "clients") }
        await #expect(throws: FolderError.inbox) { try await sync.renameFolder("INBOX", to: "Old") }
        await #expect(throws: FolderError.inbox) { try await sync.deleteFolder("INBOX", allowSpecial: true) }
        await #expect(throws: FolderError.containsSeparator(f.separator)) { try await sync.createFolder(named: "a\(s)b") }

        // Special folders need a warning first.
        let sent = try #require(try await sync.path(for: .sent))
        await #expect(throws: FolderError.specialFolder(sent)) { try await sync.renameFolder(sent, to: "Outgoing") }
        await #expect(throws: FolderError.specialFolder(sent)) { try await sync.deleteFolder(sent) }

        // Put a message in Acme.
        let thread = try #require(try f.store.threads(mailbox: "INBOX").first?.threadID)
        try await sync.perform(.move(toMailbox: acme), threadIDs: [thread])
        try await sync.processPendingActions()
        #expect(try f.localMailbox(of: "Kontrakt") == acme)

        // Rename the parent: the subfolder and its mail follow, on the server and here.
        let kunder = try await sync.renameFolder(clients, to: "Kunder")
        let kunderAcme = "\(p)Kunder\(s)Acme"
        #expect(kunder == "\(p)Kunder")
        server = try await f.serverFolders()
        #expect(server.contains(kunder) && server.contains(kunderAcme))
        #expect(!server.contains(clients) && !server.contains(acme))
        #expect(try f.localMailbox(of: "Kontrakt") == kunderAcme)
        #expect(try f.localFolders().contains(kunderAcme))
        #expect(try !f.localFolders().contains(acme))
        #expect(try await f.serverCount(kunderAcme) == 1)

        // Move a subfolder to the top, then inside another folder.
        let topAcme = try await sync.moveFolder(kunderAcme, into: nil)
        #expect(topAcme == "\(p)Acme")
        #expect(try f.localMailbox(of: "Kontrakt") == topAcme)
        let nested = try await sync.moveFolder(topAcme, into: receipts)
        #expect(nested == "\(receipts)\(s)Acme")
        #expect(try await f.serverCount(nested) == 1)
        #expect(try f.localMailbox(of: "Kontrakt") == nested)
        await #expect(throws: FolderError.intoItself) { try await sync.moveFolder(receipts, into: nested) }

        // The message is still readable from its new place.
        let message = try #require(try f.store.messages(inThread: thread).first { $0.mailbox == nested })
        let raw = try await sync.rawMessage(message)
        #expect(String(decoding: raw, as: UTF8.self).contains("Subject: Kontrakt"))

        // A sync after all that agrees with what we did.
        try await sync.syncOnce()
        #expect(try f.localMailbox(of: "Kontrakt") == nested)
        #expect(try Set(f.localFolders()).isSuperset(of: [kunder, receipts, nested]))

        // Delete the folder with a subfolder: both go, with their mail.
        let deleted = try await sync.deleteFolder(receipts)
        #expect(deleted == [nested, receipts])
        server = try await f.serverFolders()
        #expect(!server.contains(receipts) && !server.contains(nested))
        #expect(try f.localMailbox(of: "Kontrakt") == nil)
        #expect(try !f.localFolders().contains(receipts))
        try await sync.syncOnce()
        #expect(try f.localFolders().contains(kunder))
    }

    /// A move queued before a rename reaches the server first, into the folder's old name,
    /// and the message ends up in the renamed folder.
    @Test(arguments: [plainPort, namespacePort])
    func queuedMoveLandsBeforeTheRename(port: UInt16) async throws {
        guard let f = try await fixture(port: port) else { return }
        let projects = try await f.sync.createFolder(named: "Projects")
        let thread = try #require(try f.store.threads(mailbox: "INBOX").first?.threadID)
        try await f.sync.perform(.move(toMailbox: projects), threadIDs: [thread])   // queued, not sent
        let renamed = try await f.sync.renameFolder(projects, to: "Projekter")
        #expect(try await f.serverCount(renamed) == 1)
        #expect(try await f.serverCount("INBOX") == 0)
        #expect(try f.localMailbox(of: "Kontrakt") == renamed)
    }

    /// "Use as Archive": Done goes there from then on, and a sync keeps the choice.
    @Test func chosenArchiveWins() async throws {
        guard let f = try await fixture(port: Self.namespacePort) else { return }
        let old = try await f.sync.createFolder(named: "Gemt")
        try await f.sync.chooseFolder(old, for: .archive)
        #expect(try await f.sync.path(for: .archive) == old)
        try await f.sync.syncOnce()
        #expect(try await f.sync.path(for: .archive) == old)
        let thread = try #require(try f.store.threads(mailbox: "INBOX").first?.threadID)
        try await f.sync.perform(.done, threadIDs: [thread])
        try await f.sync.processPendingActions()
        #expect(try await f.serverCount(old) == 1)
        // Renaming the chosen folder keeps the choice.
        let renamed = try await f.sync.renameFolder(old, to: "Arkiveret", allowSpecial: true)
        #expect(await f.sync.chosenFolder(for: .archive) == renamed)
        #expect(try await f.sync.path(for: .archive) == renamed)
    }
}
