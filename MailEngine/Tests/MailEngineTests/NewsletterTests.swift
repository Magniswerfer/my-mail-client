import Foundation
import Testing
@testable import MailEngine

@Suite struct NewsletterTests {
    @Test func unsubscribeHeaders() {
        let both = UnsubscribeOptions.parse(listUnsubscribe: "<mailto:leave@list.dk?subject=unsubscribe>, <https://list.dk/u/abc>",
                                            listUnsubscribePost: "List-Unsubscribe=One-Click")
        #expect(both?.oneClick == URL(string: "https://list.dk/u/abc"))
        #expect(both?.mailto == "leave@list.dk")
        #expect(both?.mailtoSubject == "unsubscribe")
        let noPost = UnsubscribeOptions.parse(listUnsubscribe: "<https://list.dk/u/abc>", listUnsubscribePost: nil)
        #expect(noPost?.oneClick == nil && noPost?.web == URL(string: "https://list.dk/u/abc"), "no Post header → open the page")
        let http = UnsubscribeOptions.parse(listUnsubscribe: "<http://list.dk/u>", listUnsubscribePost: "List-Unsubscribe=One-Click")
        #expect(http?.oneClick == nil, "one-click only over HTTPS")
        #expect(UnsubscribeOptions.parse(listUnsubscribe: nil, listUnsubscribePost: nil) == nil)
    }

    @Test func sendersAttachmentsAndKeywords() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("news-\(UUID()).sqlite").path)
        func m(_ uid: UInt32, from: String, category: MailCategory, mailbox: String = "INBOX", flags: String = "") -> StoredMessage {
            var x = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: "t\(uid)", subject: "S\(uid)",
                                  fromName: "Shop", fromAddress: from, date: Date().addingTimeInterval(-Double(uid) * 60), flags: flags,
                                  category: category)
            x.hasAttachments = uid == 1
            return x
        }
        var a = m(1, from: "news@shop.dk", category: .newsletters)
        a.unsubscribe = UnsubscribeOptions(oneClick: URL(string: "https://shop.dk/u"))
        a.attachments = [AttachmentInfo(filename: "katalog.pdf", mimeType: "application/pdf", size: 1000, contentID: nil, isInline: false),
                         AttachmentInfo(filename: "logo.png", mimeType: "image/png", size: 10, contentID: "logo", isInline: true)]
        let b = m(2, from: "News@Shop.dk", category: .newsletters, flags: "\\Seen")
        let c = m(3, from: "news@shop.dk", category: .advertising, mailbox: "Archive", flags: readLaterKeyword)
        let d = m(4, from: "anna@x.dk", category: .primary)
        try s.upsert([a, b, c, d].map { ($0, "x") })

        let senders = try s.senders(ownAddresses: ["me@x.dk"])
        #expect(senders.first?.address == "news@shop.dk")
        #expect(senders.first?.count == 3 && senders.first?.inInbox == 2 && senders.first?.unread == 1)
        #expect(senders.first?.category == .newsletters)
        #expect(senders.first?.canUnsubscribe == true)
        #expect(try s.unsubscribeOptions(for: "NEWS@shop.dk")?.0.oneClick == URL(string: "https://shop.dk/u"))
        #expect(Set(try s.threadIDs(from: "news@shop.dk")) == ["t1", "t2"])
        #expect(try s.threadIDs(withKeyword: readLaterKeyword) == ["t3"])
        let files = try s.attachmentEntries()
        #expect(files.map(\.info.filename) == ["katalog.pdf"], "inline images aren't attachments")
    }
}
