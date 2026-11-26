import Foundation
import Testing
@testable import MailEngine

@Suite struct AICategoryTests {
    let me = "magnus@example.dk"

    func message(_ uid: UInt32, thread: String, from: String, mailbox: String = "INBOX") -> StoredMessage {
        StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: thread, subject: "S\(uid)",
                      fromAddress: from, date: Date().addingTimeInterval(Double(uid)))
    }

    @Test func backfillThenNewMailAndYourChoicesStick() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("aic-\(UUID()).sqlite").path)
        try s.upsert([message(1, thread: "t1", from: "vc@fund.com"), message(2, thread: "t1", from: "vc@fund.com"),
                      message(3, thread: "t2", from: me), message(4, thread: "t3", from: "x@y.dk", mailbox: "Archive")].map { ($0, "x") })
        let investors = AICategory(name: "Investors", description: "Updates and questions from our investors")
        try s.saveAICategories([investors])
        #expect(try s.aiCategories().first?.about.description == "Updates and questions from our investors")

        let first = try s.messagesToSort(into: investors.id, ownAddresses: [me])
        #expect(first.map(\.uid) == [2], "backfill: newest per Inbox conversation, not yours, not archived")
        try s.assign(threadID: "t1", to: investors.id)
        try s.markSorted(into: investors.id, upTo: first.last!.id!)
        #expect(try s.messagesToSort(into: investors.id, ownAddresses: [me]).isEmpty)

        try s.upsert([(message(5, thread: "t5", from: "lp@fund.com"), "new")])
        #expect(try s.messagesToSort(into: investors.id, ownAddresses: [me]).map(\.uid) == [5], "then only new mail")

        try s.setMembership(threadID: "t1", categoryID: investors.id, isMember: false)
        try s.assign(threadID: "t1", to: investors.id)
        #expect(try s.threadIDs(inAICategory: investors.id).isEmpty, "taking it out sticks over the model")
        try s.setMembership(threadID: "t9", categoryID: investors.id, isMember: true)
        #expect(try s.aiCategoryMembership()["t9"] == [investors.id])

        try s.resetAICategory(investors.id)
        #expect(try s.threadIDs(inAICategory: investors.id) == ["t9"], "reset keeps your own choices")
        try s.saveAICategories([])
        #expect(try s.aiCategoryMembership().isEmpty, "deleting a category drops its members")
    }

    /// "Always for this sender": older saved categories still load, the sender's conversations
    /// go in as your choice (surviving a reset), and one you took out stays out.
    @Test func alwaysForSender() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("aic-\(UUID()).sqlite").path)
        var shop = AICategory(name: "Shops", description: "")
        let old = try JSONEncoder().encode(shop)
        var json = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["senders"] = nil
        let decoded = try JSONDecoder().decode(AICategory.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.senders.isEmpty)

        shop.senders = ["news@shop.dk"]
        #expect(shop.includesSender("News@Shop.dk"))
        try s.saveAICategories([shop])
        #expect(try s.aiCategories().first?.senders == ["news@shop.dk"])

        try s.upsert([message(1, thread: "t1", from: "News@shop.dk"), message(2, thread: "t2", from: "news@shop.dk", mailbox: "Archive"),
                      message(3, thread: "t3", from: "a@b.dk")].map { ($0, "x") })
        #expect(Set(try s.threadIDs(fromSender: "news@shop.dk")) == ["t1", "t2"])

        try s.assign(threadID: "t1", to: shop.id)                 // the model first
        try s.assign(threadID: "t1", to: shop.id, byYou: true)    // then "always": now yours
        try s.setMembership(threadID: "t2", categoryID: shop.id, isMember: false)
        try s.assign(threadID: "t2", to: shop.id, byYou: true)
        #expect(try s.membershipSource(threadID: "t1", categoryID: shop.id) == 1)
        #expect(try s.membershipSource(threadID: "t2", categoryID: shop.id) == -1, "taken out stays out")
        try s.resetAICategory(shop.id)
        #expect(try s.threadIDs(inAICategory: shop.id) == ["t1"])

        try s.restoreMembership(threadID: "t1", categoryID: shop.id, source: nil)
        #expect(try s.membershipSource(threadID: "t1", categoryID: shop.id) == nil)
    }
}
