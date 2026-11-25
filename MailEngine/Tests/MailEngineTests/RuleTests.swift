import Foundation
import Testing
@testable import MailEngine

@Suite struct RuleTests {
    let shoe = RuleInput(fromAddress: "news@zalando.dk", fromName: "Zalando", recipients: "magnus@example.dk",
                         subject: "Nye sneakers til dig", ownText: "Se vores nye sko", category: .advertising)

    @Test func structuredConditionsAllAndAny() {
        var rule = MailRule(name: "Zalando", conditions: [.from("zalando"), .subject("SNEAKERS")], actions: [.markDone])
        #expect(RuleEvaluator.evaluate(rule, shoe) == .match, "case-insensitive contains")
        rule.conditions.append(.hasAttachment)
        #expect(RuleEvaluator.evaluate(rule, shoe) == .noMatch)
        rule.match = .any
        #expect(RuleEvaluator.evaluate(rule, shoe) == .match)
        rule.isEnabled = false
        #expect(RuleEvaluator.evaluate(rule, shoe) == .noMatch)
        #expect(RuleEvaluator.check(.category(.advertising), shoe) == true)
        #expect(RuleEvaluator.check(.body("sko"), shoe) == true)
    }

    @Test func topicsOnlyWhenTheyCanChangeTheResult() {
        let all = MailRule(name: "Shoes", conditions: [.from("ikea"), .about("shoes")], actions: [.markDone])
        #expect(RuleEvaluator.evaluate(all, shoe) == .noMatch, "a failing cheap condition skips the model")
        let any = MailRule(name: "Shoes", match: .any, conditions: [.from("zalando"), .about("shoes")], actions: [.markDone])
        #expect(RuleEvaluator.evaluate(any, shoe) == .match, "a passing cheap condition skips the model")
        let topic = MailRule(name: "Shoes", conditions: [.from("zalando"), .about("shoes")], actions: [.markDone])
        #expect(RuleEvaluator.evaluate(topic, shoe) == .needsJudge(["shoes"]))
        #expect(RuleEvaluator.resolve(topic, verdicts: ["shoes": true]))
        #expect(!RuleEvaluator.resolve(topic, verdicts: ["shoes": false]))
        #expect(topic.usesNaturalLanguage)
    }

    @Test func storageOrderAndSeenLog() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID()).sqlite").path)
        let a = MailRule(name: "A", conditions: [.from("x")], actions: [.pin])
        let b = MailRule(name: "B", conditions: [.about("shoes")], actions: [.moveToFolder("Shopping")], stopProcessing: true)
        try s.saveRules([b, a])
        #expect(try s.rules().map(\.name) == ["B", "A"])
        #expect(try s.rules().first == b, "round-trips through JSON")

        let m1 = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: "m1@x", threadID: "t", subject: "Hi",
                               fromAddress: "anna@x.dk", date: Date())
        let mine = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 2, messageID: "m2@x", threadID: "t", subject: "Re: Hi",
                                 fromAddress: "magnus@example.dk", date: Date())
        try s.upsert([(m1, "hej"), (mine, "hej")])
        let waiting = try s.messagesAwaitingRules(ownAddresses: ["magnus@example.dk"])
        #expect(waiting.map(\.uid) == [1], "your own mail isn't run through rules")
        try s.markSeenByRules(waiting)
        #expect(try s.messagesAwaitingRules(ownAddresses: ["magnus@example.dk"]).isEmpty)
    }

    @Test func sentenceSketchBecomesARule() throws {
        let rule = try #require(RuleSketchMapper.rule(from: .init(name: "Sko", from: "", subjectContains: "", about: "shoes",
                                                                  action: "move to folder", target: "Shopping"),
                                                      sentence: "Alle mails om sko skal i Shopping"))
        #expect(rule.conditions == [.about("shoes")])
        #expect(rule.actions == [.moveToFolder("Shopping")])
        #expect(RuleSketchMapper.rule(from: .init(name: "", from: "", subjectContains: "", about: "", action: "pin", target: ""),
                                      sentence: "x") == nil, "no condition, no rule")
        #expect(RuleSketchMapper.rule(from: .init(name: "", from: "bank.dk", subjectContains: "", about: "", action: "set category",
                                                  target: "Transactions"), sentence: "x")?.actions == [.setCategory(.transactions)])
    }
}

@Suite struct SmartFolderTests {
    let me = "magnus@example.dk"

    @Test func savedFoldersAndThreadsAnywhere() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("smart-\(UUID()).sqlite").path)
        try s.saveSmartFolders(SmartFolder.builtIns() + [SmartFolder(name: "Bank", query: "from:bank.dk")])
        #expect(try s.smartFolders().map(\.name) == ["Bank"], "built-ins aren't stored")

        let inbox = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: "i@x", threadID: "t1", subject: "Hej",
                                  fromAddress: "anna@x.dk", recipients: me, date: Date().addingTimeInterval(-7200))
        let archived = StoredMessage(accountID: "a", mailbox: "Archive", uid: 2, messageID: "a@x", threadID: "t2", subject: "Faktura",
                                     fromAddress: "bank@bank.dk", recipients: me, date: Date().addingTimeInterval(-3600))
        let mine = StoredMessage(accountID: "a", mailbox: "Sent Messages", uid: 3, messageID: "s@x", threadID: "t1",
                                 subject: "Re: Hej", fromAddress: me, recipients: "Anna <anna@x.dk>", date: Date())
        try s.upsert([(inbox, "hej"), (archived, "faktura"), (mine, "svar")])
        let threads = try s.threads(mailbox: nil, threadIDs: ["t2", "t1"], ownAddresses: [me])
        #expect(threads.map(\.threadID) == ["t1", "t2"], "newest first, any mailbox")
        #expect(try s.threads(mailbox: nil, threadIDs: []).isEmpty)
        #expect(try s.waitingForReplyThreadIDs(ownAddresses: [me]) == ["t1"])
        #expect(Set(try s.threadIDs(forMessageIDs: threads.compactMap(\.latest.id))) == ["t1", "t2"])
        #expect(try s.threads(mailbox: "INBOX", ownAddresses: [me]).map(\.threadID) == ["t1"], "mailbox filter unchanged")
    }

    @Test func cosine() {
        #expect(abs(VectorMath.cosine([1, 0], [1, 0]) - 1) < 0.0001)
        #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 0.0001)
        #expect(VectorMath.cosine([1], [1, 2]) == 0)
    }
}
