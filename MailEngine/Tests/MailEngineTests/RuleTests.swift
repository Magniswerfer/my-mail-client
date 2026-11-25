import Foundation
import Testing
@testable import MailEngine

@Suite struct RuleMatchingTests {
    func message(from name: String = "Zalando", address: String = "news@zalando.dk", subject: String = "Nye sko til dig",
                 category: MailCategory = .advertising, attachments: Bool = false, preview: String = "Spar 30% på sneakers") -> StoredMessage {
        StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: "<1@x>", threadID: "t1", subject: subject,
                      fromName: name, fromAddress: address, recipients: "Magnus <magnus@tidings.test>", date: Date(),
                      flags: "", size: 100, hasAttachments: attachments, category: category, preview: preview)
    }

    @Test func textMatchIsCaseAndAccentInsensitive() {
        #expect(TextMatch(.contains, "SKO").matches("Nye sko til dig"))
        #expect(TextMatch(.contains, "cafe").matches("Café Noir"))
        #expect(TextMatch(.endsWith, "@zalando.dk").matches("news@ZALANDO.dk"))
        #expect(TextMatch(.beginsWith, "nye").matches("Nye sko"))
        #expect(!TextMatch(.beginsWith, "sko").matches("Nye sko"))
        #expect(TextMatch(.equals, "nye sko").matches("Nye Sko"))
        #expect(TextMatch(.doesNotContain, "faktura").matches("Nye sko"))
        #expect(!TextMatch(.contains, "  ").matches("anything"))   // empty value never matches
    }

    @Test func allAndAnyConditions() async {
        let engine = RuleEngine()
        let all = Rule(name: "Zalando ads", conditions: [.sender(TextMatch(.endsWith, "@zalando.dk")), .category(.advertising)],
                       actions: [.done])
        #expect(await engine.matches(all, message()))
        #expect(await !engine.matches(all, message(category: .newsletters)))
        var any = all
        any.matchAll = false
        #expect(await engine.matches(any, message(category: .newsletters)))
        #expect(await !engine.matches(any, message(address: "x@y.dk", category: .primary)))
    }

    @Test func senderMatchesNameOrAddress() async {
        let engine = RuleEngine()
        let byName = Rule(name: "n", conditions: [.sender(TextMatch(.contains, "zalando"))], actions: [.pin])
        #expect(await engine.matches(byName, message(address: "noreply@mailer.com")))
        let notFrom = Rule(name: "n", conditions: [.sender(TextMatch(.doesNotContain, "zalando"))], actions: [.pin])
        #expect(await !engine.matches(notFrom, message(address: "noreply@mailer.com")))   // the name still says Zalando
    }

    @Test func stopProcessingEndsTheList() async {
        let engine = RuleEngine()
        let first = Rule(name: "1", conditions: [.category(.advertising)], actions: [.markRead], stopProcessing: true)
        let second = Rule(name: "2", conditions: [.category(.advertising)], actions: [.done])
        let disabled = Rule(name: "0", isEnabled: false, conditions: [.category(.advertising)], actions: [.pin])
        let matched = await engine.matchingRules([disabled, first, second], for: message())
        #expect(matched.map(\.name) == ["1"])
    }

    @Test func mergedActionsKeepLastCategoryAndFirstExit() {
        let a = Rule(name: "a", conditions: [.category(.advertising)], actions: [.setCategory(.newsletters), .snooze(hours: 2), .pin])
        let b = Rule(name: "b", conditions: [.category(.advertising)], actions: [.setCategory(.updates), .done, .pin, .markRead])
        #expect(RuleAction.merged([a, b]) == [.setCategory(.updates), .pin, .markRead, .snooze(hours: 2)])
    }

    struct FakeJudge: RuleJudge {
        func isAbout(_ condition: AboutCondition, message: StoredMessage) async -> Bool? {
            message.subject.localizedCaseInsensitiveContains("sko") ? true : false
        }
    }

    @Test func aboutConditionsAskTheJudgeOnlyWhenNeeded() async {
        let shoes = Rule(name: "Shoes", conditions: [.about(AboutCondition("about shoes")), .category(.advertising)], actions: [.pin])
        #expect(await RuleEngine(judge: FakeJudge()).matches(shoes, message()))
        #expect(await !RuleEngine(judge: FakeJudge()).matches(shoes, message(subject: "Faktura")))
        #expect(await !RuleEngine().matches(shoes, message()))   // no model: an "about" condition never matches
    }

    @Test func rulesRoundTripThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-rules-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let rules = [
            Rule(name: "B", conditions: [.subject(TextMatch(.contains, "x"))], actions: [.moveToFolder("Kvitteringer")]),
            Rule(name: "A", conditions: [.about(AboutCondition("about shoes", examples: [.init(text: "Nike", matches: true)]))],
                 actions: [.snooze(hours: nil), .notify]),
        ]
        try store.saveRules(rules)
        #expect(try store.rules() == rules)
        try store.saveRules([rules[1]])
        #expect(try store.rules().map(\.name) == ["A"])
    }
}

/// Rules against the local Dovecot: new mail arrives, rules act through the normal queue.
@Suite(.serialized) struct RuleIntegrationTests {
    func fixture() async throws -> TriageIntegrationTests.Fixture? {
        try await TriageIntegrationTests().fixture()
    }

    func deliver(_ f: TriageIntegrationTests.Fixture, subject: String, from: MailAddress) async throws {
        let raw = TestMailFactory.text(from: from, to: [TestMailFactory.me], subject: subject, date: Date(),
                                       id: "<\(UUID().uuidString)@tidings.test>", body: "Hej, \(subject)")
        try await MailSession.open(endpoint: f.endpoint, password: "tidings-test", profile: .iCloudSimulation) { session in
            _ = try await session.append(to: "INBOX", message: raw)
        }
        try await f.sync.syncOnce()
    }

    @Test func rulesOnlySeeNewMailAndActOnTheServer() async throws {
        guard let f = try await fixture() else { return }
        let shop = MailAddress(name: "Shoe Shop", address: "news@shoes.example")
        let rule = Rule(name: "Shoes to Archive", conditions: [.sender(TextMatch(.endsWith, "@shoes.example"))],
                        actions: [.setCategory(.advertising), .markRead, .done])
        // Would match mail that was there before: the account's first sync isn't "new mail".
        let everything = Rule(name: "Pin everything", conditions: [.hasAttachment(false)], actions: [.pin])
        try f.store.saveRules([rule, everything])
        #expect(try await f.sync.runRules(engine: RuleEngine()).matched == 0)
        #expect(try f.store.ruleRuns().isEmpty)
        try f.store.saveRules([rule])

        try await deliver(f, subject: "Sale on boots", from: shop)
        #expect(try f.inbox().contains { $0.latest.subject == "Sale on boots" })
        let report = try await f.sync.runRules(engine: RuleEngine())
        #expect(report.matched == 1)
        #expect(try f.inbox().contains { $0.latest.subject == "Sale on boots" } == false)

        try await f.sync.processPendingActions()
        let archived = try await f.server("Archive")
        #expect(archived.values.contains { $0.contains("\\Seen") })

        // A second pass finds nothing new.
        #expect(try await f.sync.runRules(engine: RuleEngine()).checked == 0)

        // History, and undo brings it back with its old category.
        let run = try #require(try f.store.ruleRuns(ruleID: rule.id).first)
        #expect(run.actions == [.setCategory(.advertising), .markRead, .done])
        try await f.sync.undo(run)
        let back = try #require(try f.inbox().first { $0.latest.subject == "Sale on boots" })
        #expect(back.latest.category == run.previousCategory)
        #expect(back.unreadCount == 1)
        #expect(try f.store.ruleRuns(ruleID: rule.id).first?.undoneAt != nil)
    }

    @Test func runOnInboxNowActsOnExistingMail() async throws {
        guard let f = try await fixture() else { return }
        let target = try f.thread("website")
        let rule = Rule(name: "Pin Sofie", conditions: [.subject(TextMatch(.contains, "website"))], actions: [.pin])
        let report = try await f.sync.runRuleOnInbox(rule, engine: RuleEngine())
        #expect(report.matched >= 1)
        #expect(try f.thread("website").isPinned)
        let preview = try await RuleEngine().preview(rule, store: f.store)
        #expect(preview.contains { $0.threadID == target.threadID })
    }
}
