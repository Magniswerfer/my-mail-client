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
}
