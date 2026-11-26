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

/// "About …" conditions with a fake embedder (keyword axes) and a fake model.
@Suite struct AboutConditionTests {
    /// Two axes: shoes and invoices. Everything else is noise on a third axis.
    struct AxisEmbedder: TextEmbedder {
        let dimension = 3
        func embed(_ text: String) -> [Float]? {
            let t = text.lowercased()
            var v: [Float] = [t.contains("sko") || t.contains("shoe") ? 1 : 0, t.contains("faktura") || t.contains("invoice") ? 1 : 0, 0.3]
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            v = v.map { $0 / n }
            return v
        }
    }

    final class CountingVerifier: AboutVerifier, @unchecked Sendable {
        var asked: [String] = []
        func verify(_ condition: AboutCondition, message: StoredMessage) async -> Bool? {
            asked.append(message.subject)
            return !message.subject.contains("Nike Air")   // the model disagrees about one
        }
    }

    func store(_ subjects: [String]) throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-about-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let messages = subjects.enumerated().map { i, subject in
            StoredMessage(accountID: "a", mailbox: "INBOX", uid: UInt32(i + 1), messageID: "m\(i)@x", threadID: "t\(i)", subject: subject,
                          fromName: nil, fromAddress: "x@shop.dk", recipients: "me@x", date: Date().addingTimeInterval(-Double(i) * 60))
        }
        try s.upsert(messages.map { ($0, $0.subject) })
        for m in try s.inboxMessages() { try s.saveEmbedding(AxisEmbedder().embed(MailStore.embeddingText(m))!, for: m.id!) }
        return s
    }

    @Test func calibratedCutSkipsTheModelForUnrelatedMail() async throws {
        let subjects = ["Nye sko", "Nike Air sko", "Faktura 123"] + (0..<40).map { "Nyhedsbrev \($0)" }
        let s = try store(subjects)
        let verifier = CountingVerifier()
        let judge = try #require(OnDeviceRuleJudge(store: s, embedder: AxisEmbedder(), verifier: verifier))
        let about = judge.calibrated(AboutCondition("shoes"))
        #expect(about.threshold > 0.3)

        let inbox = try s.inboxMessages()
        let shoes = try #require(inbox.first { $0.subject == "Nye sko" })
        let nike = try #require(inbox.first { $0.subject == "Nike Air sko" })
        let invoice = try #require(inbox.first { $0.subject == "Faktura 123" })
        #expect(await judge.isAbout(about, message: shoes) == true)
        #expect(await judge.isAbout(about, message: nike) == false)      // passed the cut, model said no
        #expect(await judge.isAbout(about, message: invoice) == false)
        #expect(verifier.asked == ["Nye sko", "Nike Air sko"])           // never asked about the invoice

        // Without a model, the calibrated cut decides on its own.
        let embeddingsOnly = try #require(OnDeviceRuleJudge(store: s, embedder: AxisEmbedder(), verifier: nil))
        #expect(await embeddingsOnly.isAbout(about, message: nike) == true)
        #expect(await embeddingsOnly.isAbout(about, message: invoice) == false)
    }

    @Test func previewAsksTheModelOnlyAboutTheLikeliest() async throws {
        let subjects = (0..<60).map { "Nyhedsbrev \($0)" } + ["Nye sko", "Nike Air sko"]
        let s = try store(subjects)
        let verifier = CountingVerifier()
        let judge = try #require(OnDeviceRuleJudge(store: s, embedder: AxisEmbedder(), verifier: verifier))
        let rule = Rule(name: "Shoes", conditions: [.about(AboutCondition("shoes"))], actions: [.pin])
        let hits = try await RuleEngine(judge: judge).preview(rule, store: s)
        #expect(hits.map(\.subject) == ["Nye sko"])
        #expect(verifier.asked.count <= RuleEngine.modelPreviewLimit)
        #expect(Set(verifier.asked.prefix(2)) == ["Nye sko", "Nike Air sko"])   // ranked first
    }
}

@Suite struct RuleDraftGroundingTests {
    @Test func inventedDetailsAreDroppedAndNamedCategoriesKept() {
        // What the on-device model actually produced for these sentences.
        let zalando = Rule(name: "Zalando", conditions: [.sender(TextMatch(.endsWith, "@zalando.dk")), .hasAttachment(true)],
                           actions: [.markRead]).grounded(in: "Flyt alle mails fra zalando.dk til Reklamer og markér dem som læst")
        #expect(zalando.conditions == [.sender(TextMatch(.endsWith, "@zalando.dk"))])
        #expect(zalando.actions == [.setCategory(.advertising), .markRead])

        let accountant = Rule(name: "a", conditions: [.about(AboutCondition("invoices from my accountant")),
                                                     .sender(TextMatch(.endsWith, "@myaccountant.com"))],
                              actions: [.pin]).grounded(in: "Pin mail from my accountant about invoices")
        #expect(accountant.conditions == [.about(AboutCondition("invoices from my accountant"))])

        let linkedIn = Rule(name: "l", conditions: [.subject(TextMatch(.contains, "LinkedIn")), .sender(TextMatch(.endsWith, "@zalando.dk"))],
                            actions: [.setCategory(.primary), .snooze(hours: 24)]).grounded(in: "Udsæt alt fra LinkedIn til i morgen")
        #expect(linkedIn.conditions == [.subject(TextMatch(.contains, "LinkedIn"))])
        #expect(linkedIn.actions == [.snooze(hours: 24)])

        let crypto = Rule(name: "c", conditions: [.category(.newsletters), .about(AboutCondition("crypto"))], actions: [.done])
            .grounded(in: "Archive newsletters about crypto")
        #expect(crypto.conditions.count == 2)
        #expect(crypto.actions == [.done])   // "newsletters" is the condition, not a move
    }

    @Test func aNamedSenderIsASenderNotATopic() {
        // Found in the click-through: "about: Sofie Hansen" matched a dinner invite and a Nike ad.
        let sofie = Rule(name: "s", conditions: [.about(AboutCondition("Sofie Hansen"))], actions: [.pin])
            .grounded(in: "Fastgør mail fra Sofie Hansen")
        #expect(sofie.conditions == [.sender(TextMatch(.contains, "Sofie Hansen"))])

        let address = Rule(name: "a", conditions: [.about(AboutCondition("sofie@example.com"))], actions: [.pin])
            .grounded(in: "Pin mail from sofie@example.com")
        #expect(address.conditions == [.sender(TextMatch(.contains, "sofie@example.com"))])

        // Lower-case descriptions and topics stay topics.
        let accountant = Rule(name: "m", conditions: [.about(AboutCondition("my accountant"))], actions: [.pin])
            .grounded(in: "Pin mail from my accountant")
        #expect(accountant.conditions == [.about(AboutCondition("my accountant"))])
        let crypto = Rule(name: "c", conditions: [.about(AboutCondition("Crypto"))], actions: [.done])
            .grounded(in: "Archive mail about Crypto")
        #expect(crypto.conditions == [.about(AboutCondition("Crypto"))])
    }
}

@Suite struct ReadingTextTests {
    @Test func dropsQuotesAndSignatureAndJoinsLines() {
        let text = "Hej Magnus,\n\nDette er en lang\ntekst om noget.\n\n\n\nAndet afsnit.\n\n-- \nAnna\n\nOn Mon, Bo wrote:\n> gammelt"
        let paragraphs = ReadingText.paragraphs(text)
        #expect(paragraphs.prefix(3) == ["Hej Magnus,", "Dette er en lang tekst om noget.", "Andet afsnit."])
        #expect(!paragraphs.joined().contains("gammelt"))
        #expect(ReadingText.minutes(String(repeating: "ord ", count: 690)) == 3)
        #expect(ReadingText.minutes("kort") == 1)
    }
}

@Suite(.serialized) struct SameFolderMoveTests {
    /// Done on mail that's already in the Archive (from a smart folder) must not move it onto
    /// itself: on iCloud that's a copy.
    @Test func doneOnArchivedMailDoesNothing() async throws {
        guard let f = try await TriageIntegrationTests().fixture() else { return }
        let thread = try f.thread("website")
        try await f.sync.perform(.done, threadIDs: [thread.threadID])
        try await f.sync.processPendingActions()
        let archive = try await f.server("Archive").count
        let again = try await f.sync.perform(.done, threadIDs: [thread.threadID], from: "Archive")
        #expect(again == nil)
        try await f.sync.processPendingActions()
        #expect(try await f.server("Archive").count == archive)
    }
}
