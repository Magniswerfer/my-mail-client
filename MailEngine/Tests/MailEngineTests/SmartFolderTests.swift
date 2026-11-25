import Foundation
import Testing
@testable import MailEngine

@Suite struct SmartFolderTests {
    let me = "magnus@tidings.test"

    func store() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-smart-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        for (path, role) in [("INBOX", MailboxRole.inbox), ("Sent Messages", .sent), ("Archive", .archive)] {
            try s.save(MailboxState(accountID: "a", path: path, role: role, uidValidity: 1, uidNext: nil, highestModSeq: nil,
                                    messageCount: 0, lastSync: nil))
        }
        return s
    }

    func message(_ uid: UInt32, thread: String, mailbox: String = "INBOX", from: String = "anna@firma.dk", daysAgo: Double,
                 subject: String = "Hej", flags: String = "", attachment: Bool = false, category: MailCategory = .primary) -> (StoredMessage, String) {
        var m = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: thread, subject: subject,
                              fromName: nil, fromAddress: from, recipients: "x", date: Date().addingTimeInterval(-daysAgo * 86_400))
        m.flags = flags
        m.hasAttachments = attachment
        m.category = category
        return (m, subject)
    }

    @Test func operatorsParse() throws {
        let q = SearchQuery(parsing: "is:pinned is:waiting faktura")
        #expect(q.pinned == true && q.waiting == true && q.terms == ["faktura"])
        let now = Date()
        let cal = Calendar.current
        #expect(SearchQuery.date("thisyear", now: now) == cal.dateInterval(of: .year, for: now)?.start)
        #expect(SearchQuery.date("30d", now: now) == cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now)))
        #expect(SearchQuery.date("2y", now: now) == cal.date(byAdding: .year, value: -2, to: cal.startOfDay(for: now)))
        #expect(SearchQuery.date("2025-03-01") != nil)
        #expect(SearchQuery.date("soon") == nil)
        #expect(SearchQuery(parsing: "after:thisyear").after != nil)
    }

    @Test func conversationsGroupThreadsAndWaitingMeansYouWroteLast() throws {
        let s = try store()
        try s.upsert([
            // A: Anna asked, I answered last → waiting.
            message(1, thread: "A", daysAgo: 3, subject: "Faktura spørgsmål"),
            message(2, thread: "A", mailbox: "Sent Messages", from: me, daysAgo: 2, subject: "Re: Faktura spørgsmål"),
            // B: I asked, Bo answered → not waiting.
            message(3, thread: "B", mailbox: "Sent Messages", from: me, daysAgo: 4, subject: "Faktura?"),
            message(4, thread: "B", from: "bo@x.dk", daysAgo: 1, subject: "Re: Faktura?", flags: "\\Flagged"),
            // C: archived receipt with an attachment.
            message(5, thread: "C", mailbox: "Archive", from: "shop@x.dk", daysAgo: 10, subject: "Kvittering", attachment: true,
                    category: .transactions),
        ])
        let engine = SearchEngine(store: s)

        let waiting = try engine.conversations(SearchQuery(parsing: "is:waiting"))
        #expect(try s.threads(representedBy: waiting).map(\.threadID) == ["A"])

        // Two messages of thread B match "faktura": one conversation, represented by the newest.
        let faktura = try engine.conversations(SearchQuery(parsing: "faktura"))
        let threads = try s.threads(representedBy: faktura, ownAddresses: [me])
        #expect(threads.map(\.threadID) == ["B", "A"])
        #expect(threads.first?.latest.uid == 4)
        #expect(threads.first?.messageCount == 2)
        #expect(try engine.conversationCount(SearchQuery(parsing: "faktura")) == 2)

        #expect(try engine.conversationCount(SearchQuery(parsing: "is:pinned")) == 1)
        #expect(try engine.conversations(SearchQuery(parsing: SmartFolder.attachments.query)).count == 1)   // any mailbox
        #expect(try engine.conversationCount(SearchQuery(parsing: "category:transactions after:30d")) == 1)
    }

    @Test func savedSearchesRoundTripWithoutBuiltIns() throws {
        let s = try store()
        let mine = SmartFolder(name: "Anna", query: "from:anna")
        try s.saveSmartFolders([SmartFolder.attachments, mine])
        #expect(try s.smartFolders() == [mine])
    }
}

@Suite struct RelatedAndContactSearchTests {
    func store(_ items: [(subject: String, from: String, name: String?)]) throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-related-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let messages = items.enumerated().map { i, item in
            StoredMessage(accountID: "a", mailbox: "INBOX", uid: UInt32(i + 1), messageID: "m\(i)@x", threadID: "t\(i)", subject: item.subject,
                          fromName: item.name, fromAddress: item.from, recipients: "me@x", date: Date().addingTimeInterval(-Double(i) * 60))
        }
        try s.upsert(messages.map { ($0, $0.subject) })
        for m in try s.inboxMessages() {
            try s.saveEmbedding(AboutConditionTests.AxisEmbedder().embed(MailStore.embeddingText(m))!, for: m.id!)
        }
        return s
    }

    @Test func relatedFindsMeaningNotWordsAndSkipsKeywordHits() throws {
        let s = try store([("Nike: nye løbesko", "a@shop.dk", nil), ("Shoe sale this weekend", "b@shop.com", nil)]
                          + (0..<40).map { ("Nyhedsbrev \($0)", "news@x.dk", nil) })
        let engine = SearchEngine(store: s)
        let shoeHit = try #require(try s.inboxMessages().first { $0.subject.hasPrefix("Shoe") })
        let related = try engine.related(to: "sko", embedder: AboutConditionTests.AxisEmbedder(), excluding: [shoeHit.id!])
        #expect(related.map(\.subject) == ["Nike: nye løbesko"])
    }

    @Test func contactMatchesNamePrefixAndPrefersTheBusiestSender() throws {
        let s = try store([("Hej", "anna@firma.dk", "Anna Holm"), ("Møde", "anna@firma.dk", "Anna Holm"),
                           ("Tilbud", "annoncer@shop.dk", "Annoncer")])
        let engine = SearchEngine(store: s)
        let hit = try #require(try engine.contact(for: SearchQuery(parsing: "ann")))
        #expect(hit.address == "anna@firma.dk" && hit.messageCount == 2 && hit.name == "Anna Holm")
        #expect(try engine.contact(for: SearchQuery(parsing: "holm")) != nil)
        #expect(try engine.contact(for: SearchQuery(parsing: "anna has:attachment")) == nil)   // operators: no card
    }
}

@Suite(.serialized) struct AttachmentBrowserTests {
    @Test func listsAreKeptAtSyncAndFilesComeBackFromTheMessage() async throws {
        guard let f = try await TriageIntegrationTests().fixture() else { return }
        let entries = try f.store.attachmentEntries()
        let entry = try #require(entries.first)
        #expect(entries.allSatisfy { !$0.info.isInline })
        let message = try #require(try f.store.message(id: entry.messageLocalID))
        let raw = try await f.sync.rawMessage(message)
        let file = try #require(MIMEParser.attachmentFile(entry.info, in: raw))
        #expect(file.filename == entry.filename)
        #expect(!file.data.isEmpty)
        // Nothing left to index: everything came with the sync.
        #expect(try await f.sync.indexAttachmentsFromCache() == 0)
    }

    @Test func missingListsAreFilledFromTheCache() async throws {
        guard let f = try await TriageIntegrationTests().fixture() else { return }
        let entry = try #require(try f.store.attachmentEntries().first)
        let message = try #require(try f.store.message(id: entry.messageLocalID))
        _ = try await f.sync.rawMessage(message)          // now cached
        try await f.store.db.write { try $0.execute(sql: "UPDATE message SET attachmentList = NULL WHERE id = ?", arguments: [entry.messageLocalID]) }
        let gone = try f.store.attachmentEntries().contains { $0.messageLocalID == entry.messageLocalID }
        #expect(!gone)
        #expect(try await f.sync.indexAttachmentsFromCache() == 1)
        let back = try f.store.attachmentEntries().contains { $0.messageLocalID == entry.messageLocalID }
        #expect(back)
    }
}
