import Foundation
import MailEngine
import SwiftUI

/// Opens the rule editor (from ⌘K, a conversation, or Settings).
struct RuleEditing: Identifiable {
    let id = UUID()
    var rule: MailRule
    var isNew: Bool
}

/// What a rule would have done to recent mail.
struct RulePreview: Sendable {
    var matched: [StoredMessage]
    var checked: Int
    var judged: Bool
}

extension AppModel {
    // MARK: Storage

    func loadRules() {
        rules = (try? store.rules()) ?? []
    }

    func save(rule: MailRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        persistRules()
    }

    func delete(rule: MailRule) {
        rules.removeAll { $0.id == rule.id }
        persistRules()
    }

    func persistRules() {
        try? store.saveRules(rules)
    }

    // MARK: Creating

    func newRule(forSenderOf thread: ThreadSummary? = nil) {
        var conditions: [MailRule.Condition] = []
        var name = ""
        if let thread = thread ?? targetThreads.first {
            let sender = messages(inThread: thread.threadID).last { !ownAddresses.contains($0.fromAddress.lowercased()) } ?? thread.latest
            conditions = [.from(sender.fromAddress)]
            name = sender.senderDisplay
        }
        ruleEditing = RuleEditing(rule: MailRule(name: name, conditions: conditions, actions: [.markDone]), isNew: true)
    }

    /// "All mails about shoes go to Shopping" → an editable rule (on-device model), else a blank
    /// rule named after the sentence.
    func rule(fromSentence sentence: String) async -> MailRule {
        let folders = mailboxes.map(\.displayName)
        if let writer = assistant as? FoundationModelsWriter, let made = await writer.rule(from: sentence, folders: folders) {
            return made
        }
        return MailRule(name: String(sentence.prefix(40)), conditions: [], actions: [], sentence: sentence)
    }

    // MARK: Running

    /// After each sync: new Inbox mail through the rules, in order (SPEC §6).
    func scheduleRules() {
        guard ruleTask == nil else { return }
        ruleTask = Task { [weak self] in
            guard let self else { return }
            let waiting = (try? self.store.messagesAwaitingRules(ownAddresses: self.ownAddresses)) ?? []
            // Muted conversations: new mail goes straight to the Archive, read (SPEC §11).
            let muted = waiting.filter { self.isMuted($0.threadID) }
            for message in muted {
                guard let threadID = message.threadID else { continue }
                self.performQuietly(.markRead, threadID: threadID, accountID: message.accountID)
                self.performQuietly(.done, threadID: threadID, accountID: message.accountID)
            }
            let rest = waiting.filter { m in !muted.contains { $0.id == m.id } }
            if !rest.isEmpty, self.rules.contains(where: \.isEnabled) {
                _ = await self.run(rules: self.rules, on: rest)
            }
            try? self.store.markSeenByRules(waiting)
            self.ruleTask = nil
            if !waiting.isEmpty { self.reload() }
        }
    }

    /// "Run on existing mail" for one rule. Returns how many messages it acted on.
    func runOnExistingMail(_ rule: MailRule) async -> Int {
        let recent = (try? store.recentMailForRules(ownAddresses: ownAddresses, limit: 2_000)) ?? []
        let count = await run(rules: [rule], on: recent)
        reload()
        show(Toast(message: String(localized: "“\(rule.name)” applied to \(count) messages"), symbol: "line.3.horizontal.decrease.circle"))
        return count
    }

    @discardableResult
    func run(rules: [MailRule], on messages: [StoredMessage]) async -> Int {
        var applied = 0
        var handledThreads = Set<String>()
        for message in messages {
            let input = RuleInput(message: message)
            for rule in rules where rule.isEnabled {
                guard await matches(rule, input: input, message: message) else { continue }
                // One run per conversation per rule (moves act on whole conversations).
                let key = "\(rule.id)|\(message.threadID ?? "")"
                if handledThreads.insert(key).inserted {
                    await apply(rule, to: message)
                    applied += 1
                }
                if rule.stopProcessing { break }
            }
        }
        return applied
    }

    func matches(_ rule: MailRule, input: RuleInput, message: StoredMessage) async -> Bool {
        switch RuleEvaluator.evaluate(rule, input) {
        case .match: return true
        case .noMatch: return false
        case .needsJudge(let topics):
            guard let judge = assistant as? FoundationModelsWriter else { return false }
            var verdicts: [String: Bool] = [:]
            for topic in topics {
                if !passesPrefilter(topic, message: message) { verdicts[topic] = false; continue }
                verdicts[topic] = await judge.isAbout(topic, subject: message.subject, sender: message.senderDisplay,
                                                      snippet: input.ownText) ?? false
            }
            return RuleEvaluator.resolve(rule, verdicts: verdicts)
        }
    }

    /// Cheap embedding check before asking the model: clearly unrelated mail is skipped.
    private func passesPrefilter(_ topic: String, message: StoredMessage) -> Bool {
        guard let id = message.id, let vector = try? store.embeddingVector(messageID: id), let topicVector = topicVector(topic) else {
            return true
        }
        return VectorMath.cosine(vector, topicVector) > 0.15
    }

    private func topicVector(_ topic: String) -> [Float]? {
        if let cached = topicVectors[topic] { return cached }
        if topicEmbedder == nil { topicEmbedder = ContextualEmbedder() }
        guard let vector = topicEmbedder?.embed(topic) else { return nil }
        topicVectors[topic] = vector
        return vector
    }

    func apply(_ rule: MailRule, to message: StoredMessage) async {
        guard let threadID = message.threadID else { return }
        let account = message.accountID
        for action in rule.actions {
            switch action {
            case .moveToFolder(let name):
                if let box = folder(named: name, accountID: account) {
                    performQuietly(.move(toMailbox: box.path), threadID: threadID, accountID: account, from: message.mailbox)
                }
            case .setCategory(let category):
                if let id = message.id { try? store.setCategory(category, reason: .rule(rule.name), ids: [id]) }
            case .markDone:
                performQuietly(.done, threadID: threadID, accountID: account, from: message.mailbox)
            case .pin:
                performQuietly(.pin, threadID: threadID, accountID: account)
            case .markRead:
                performQuietly(.markRead, threadID: threadID, accountID: account)
            case .snooze(let days):
                let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                                    of: Date().addingTimeInterval(Double(max(1, days)) * 86_400))
                performQuietly(.snooze(until: morning), threadID: threadID, accountID: account, from: message.mailbox)
            case .replyLater:
                performQuietly(.replyLater, threadID: threadID, accountID: account)
            case .notify:
                await Notifier.shared.notify(message: message, reason: rule.name)
            case .forward(let address):
                await ruleMail(.forward, about: message, to: [MailAddress(name: nil, address: address)], text: nil,
                               send: !rule.usesNaturalLanguage)
            case .autoReply(let text):
                guard shouldAutoReply(to: message) else { continue }
                await ruleMail(.reply, about: message, to: nil, text: text, send: !rule.usesNaturalLanguage)
            case .runShortcut(let name):
                var c = URLComponents(string: "shortcuts://run-shortcut")
                c?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
                                 URLQueryItem(name: "text", value: link(for: message)?.absoluteString ?? message.subject)]
                if let url = c?.url { Platform.openExternally(url) }
            }
        }
    }

    func folder(named name: String, accountID: String) -> MailboxState? {
        let wanted = name.lowercased()
        let boxes = mailboxes.filter { $0.accountID == accountID }
        return boxes.first { $0.path.lowercased() == wanted } ?? boxes.first { $0.displayName.lowercased() == wanted }
    }

    /// Auto-replies never go to robots, lists, or the same person twice a day.
    private func shouldAutoReply(to message: StoredMessage) -> Bool {
        guard message.category == .primary, !SignatureInfo.looksAutomated(message.fromAddress) else { return false }
        var log = UserDefaults.standard.dictionary(forKey: "rules.autoReplied") as? [String: Date] ?? [:]
        let sender = message.fromAddress.lowercased()
        if let last = log[sender], Date().timeIntervalSince(last) < 86_400 { return false }
        log[sender] = Date()
        UserDefaults.standard.set(log, forKey: "rules.autoReplied")
        return true
    }

    /// A forward or reply made by a rule: queued to send (structured rules), or left in Drafts
    /// for you to send (rules with "about" conditions, SPEC §6).
    private func ruleMail(_ kind: ComposeKind, about message: StoredMessage, to: [MailAddress]?, text: String?, send: Bool) async {
        guard let account = accounts.first(where: { $0.id == message.accountID }),
              let raw = try? await rawMessage(message) else { return }
        let parsed = MIMEParser.parse(raw)
        var draft = Self.draft(kind, replyingTo: parsed, raw: raw, account: account)
        if let to { draft.message.to = to }
        let body = NSMutableAttributedString(string: text ?? "", attributes: RichTextEditor.baseAttributes)
        body.append(draft.body)
        guard let id = saveDraft(draft.message, body: body, accountID: account.id, kind: kind, originalLocalID: message.id) else { return }
        if send, let item = try? store.outboxItem(id: id), let outgoing = item.message {
            _ = try? await syncs[account.id]?.queue(outgoing, kind: kind, originalLocalID: message.id, replacingDraft: id)
        }
        reloadOutbox()
    }

    // MARK: Preview

    /// What the rule would have matched in recent mail. Topic conditions are checked by the model
    /// on at most `judgeLimit` candidates.
    func preview(_ rule: MailRule, judgeLimit: Int = 30) async -> RulePreview {
        var probe = rule
        probe.isEnabled = true
        let recent = (try? store.recentMailForRules(ownAddresses: ownAddresses, limit: 2_000)) ?? []
        var matched: [StoredMessage] = []
        var judged = 0
        var checked = 0
        for message in recent {
            let input = RuleInput(message: message)
            switch RuleEvaluator.evaluate(probe, input) {
            case .match: matched.append(message); checked += 1
            case .noMatch: checked += 1
            case .needsJudge:
                guard judged < judgeLimit else { continue }
                judged += 1
                checked += 1
                if await matches(probe, input: input, message: message) { matched.append(message) }
            }
        }
        return RulePreview(matched: matched, checked: checked, judged: judged > 0)
    }
}
