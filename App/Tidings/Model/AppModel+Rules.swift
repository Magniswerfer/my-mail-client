import Foundation
import MailEngine

/// Rules (SPEC §6): your ordered list, the pass after each sync, "run now", history and undo.
extension AppModel {
    // MARK: The list

    func loadRules() {
        rules = (try? store.rules()) ?? []
        ruleCounts = (try? store.ruleRunCounts(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
    }

    func saveRules() {
        do {
            try store.saveRules(rules)
        } catch {
            lastError = String(localized: "Couldn't save your rules: \(String(describing: error))")
        }
    }

    /// Adds or replaces a rule (matched by id); new rules go to the end.
    func save(_ rule: Rule) {
        let rule = calibrated(rule)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        saveRules()
    }

    func delete(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        saveRules()
    }

    func setEnabled(_ enabled: Bool, for rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled = enabled
        saveRules()
    }

    // MARK: Editing

    /// A new rule, prefilled from a conversation when there is one ("Create Rule from Message").
    func newRule(from thread: ThreadSummary? = nil) {
        var rule = Rule(name: "", conditions: [], actions: [])
        if let message = thread?.latest {
            rule.name = String(localized: "Mail from \(message.senderDisplay)")
            rule.conditions = [.sender(TextMatch(.contains, message.fromAddress))]
            rule.actions = [.setCategory(message.category)]
        }
        isRulesShown = true
        editingRule = rule
    }

    // MARK: Running

    /// With the on-device judge for "about …" conditions; without it they never match.
    var ruleEngine: RuleEngine { RuleEngine(judge: ruleJudge) }

    /// Sets each "about …" condition's pre-filter cut from your Inbox (see `OnDeviceRuleJudge`).
    func calibrated(_ rule: Rule) -> Rule {
        guard let ruleJudge else { return rule }
        var rule = rule
        rule.conditions = rule.conditions.map { condition in
            if case .about(let about) = condition { return .about(ruleJudge.calibrated(about)) }
            return condition
        }
        return rule
    }

    /// "Describe the rule": a sentence → an editable rule, keeping the one being edited's id.
    func draftRule(_ sentence: String, replacing rule: Rule) async -> Rule? {
        guard let ruleDrafter else { return nil }
        let folders = Array(Set(mailboxes.filter { $0.role != .inbox && $0.role != .sent && $0.role != .drafts }.map(\.path))).sorted()
        guard var drafted = await ruleDrafter.draft(sentence, folders: folders) else { return nil }
        drafted.id = rule.id
        drafted.isEnabled = rule.isEnabled
        return drafted
    }

    /// After a sync (and the AI sorting pass that follows it): rules on whatever arrived.
    func scheduleRules() {
        guard ruleTask == nil else { return }
        let syncs = Array(self.syncs.values)
        let engine = ruleEngine
        let filterJunk = self.filterJunk
        ruleTask = Task { [weak self] in
            var junked: [TriageChange] = []
            var matched = 0
            var notify: [RuleRun] = []
            var arrived: [StoredMessage] = []
            var deliveries: [RuleDelivery] = []
            for sync in syncs {
                guard let report = try? await sync.runRules(engine: engine, filterJunk: filterJunk) else { continue }
                if let change = report.junk.change { junked.append(change) }
                matched += report.matched
                notify += report.notify
                arrived += report.arrived
                deliveries += report.deliveries
            }
            guard let self else { return }
            await self.deliver(deliveries)
            self.ruleTask = nil
            self.reportJunk(junked)
            if matched > 0 || !arrived.isEmpty || !junked.isEmpty {
                self.ruleCounts = (try? self.store.ruleRunCounts(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
                self.reload()
            }
            await self.deliverNotifications(arrived: arrived, ruleRuns: notify)
            self.indexAttachmentsInBackground()
            self.scheduleAICategories()
        }
    }

    /// New mail that deserves it becomes a system notification (SPEC §10).
    func deliverNotifications(arrived: [StoredMessage], ruleRuns: [RuleRun]) async {
        // The push server already told this iPhone (ADR 0007).
        guard !serverNotifiesNewMail else { return }
        var policy = notificationPolicy
        // A Focus with Tidings' filter on: only VIPs (and nothing at all if you have none).
        if FocusFilterState.onlyVIPs { policy.onlyVIPs = true; policy.pinned = false; policy.replies = false; policy.rules = false }
        let notifications = policy.notifications(for: arrived.sorted { $0.date < $1.date }, ruleRuns: ruleRuns,
                                                             ownAddresses: ownAddresses, store: store)
        await notifier.post(notifications) { n in n.messageID.flatMap(MessageLink.url) }
    }

    /// "Run on Inbox now", for every account.
    func runOnInbox(_ rule: Rule) {
        let syncs = Array(self.syncs.values)
        let engine = ruleEngine
        Task {
            var matched = 0
            for sync in syncs {
                guard let report = try? await sync.runRuleOnInbox(rule, engine: engine) else { continue }
                matched += report.matched
                await deliver(report.deliveries)
            }
            ruleCounts = (try? store.ruleRunCounts(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
            reload()
            show(Toast(message: matched == 0 ? String(localized: "“\(rule.name)” matched nothing in the Inbox")
                                             : String(localized: "“\(rule.name)” acted on \(matched) conversations"),
                       symbol: "line.3.horizontal.decrease.circle"))
        }
    }

    func undo(_ run: RuleRun) {
        guard let sync = syncs[run.accountID] else { return }
        Task {
            do {
                try await sync.undo(run)
            } catch {
                lastError = String(localized: "Couldn't undo: \(String(describing: error))")
            }
            ruleCounts = (try? store.ruleRunCounts(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
            reload()
        }
    }
}

// MARK: - Describing rules (list rows, history)

extension RuleCondition {
    var summary: String {
        switch self {
        case .sender(let m): String(localized: "Sender \(m.operation.title) “\(m.value)”")
        case .recipient(let m): String(localized: "Recipient \(m.operation.title) “\(m.value)”")
        case .subject(let m): String(localized: "Subject \(m.operation.title) “\(m.value)”")
        case .text(let m): String(localized: "Text \(m.operation.title) “\(m.value)”")
        case .category(let c): String(localized: "Category is \(c.title)")
        case .hasAttachment(let has): has ? String(localized: "Has attachments") : String(localized: "Has no attachments")
        case .about(let about): String(localized: "About “\(about.description)”")
        }
    }
}

extension TextMatch.Operation {
    var title: String {
        switch self {
        case .contains: String(localized: "contains")
        case .doesNotContain: String(localized: "doesn't contain")
        case .equals: String(localized: "is")
        case .beginsWith: String(localized: "begins with")
        case .endsWith: String(localized: "ends with")
        }
    }
}

extension RuleAction {
    var summary: String {
        switch self {
        case .setCategory(let c): String(localized: "Move to \(c.title)")
        case .pin: String(localized: "Pin")
        case .markRead: String(localized: "Mark as read")
        case .replyLater: String(localized: "Set aside to reply later")
        case .done: String(localized: "Mark done")
        case .snooze(let hours):
            hours.map { String(localized: "Snooze for \($0) hours") } ?? String(localized: "Snooze for someday")
        case .moveToFolder(let path): String(localized: "Move to folder \(MailboxState.displayName(path))")
        case .notify: String(localized: "Notify me")
        case .forward(let to): String(localized: "Forward to \(to)")
        case .autoReply: String(localized: "Reply automatically")
        case .runShortcut(let name): String(localized: "Run shortcut “\(name)”")
        }
    }

    var symbol: String {
        switch self {
        case .setCategory(let c): c.symbol
        case .pin: "pin"
        case .markRead: "envelope.open"
        case .replyLater: "arrowshape.turn.up.left.circle"
        case .done: "checkmark.circle"
        case .snooze: "clock"
        case .moveToFolder: "folder"
        case .notify: "bell"
        case .forward: "arrowshape.turn.up.right"
        case .autoReply: "arrowshape.turn.up.left"
        case .runShortcut: "square.2.layers.3d"
        }
    }
}

extension Rule {
    /// "Sender ends with “@shop.dk” → Mark done".
    var summary: String {
        let joiner = matchAll ? String(localized: " and ") : String(localized: " or ")
        let when = conditions.map(\.summary).joined(separator: joiner)
        let then = actions.map(\.summary).joined(separator: ", ")
        return "\(when) → \(then)"
    }
}

// MARK: - Forward, auto-reply, Shortcuts

extension AppModel {
    /// The actions the engine leaves to the app. Forwards and replies go through the outbox (so
    /// the undo window applies), or stay in Drafts when the rule used an "about" condition.
    func deliver(_ deliveries: [RuleDelivery]) async {
        for delivery in deliveries {
            guard let message = (try? store.message(id: delivery.run.messageID)) ?? nil else { continue }
            for action in delivery.run.actions {
                switch action {
                case .forward(let address):
                    await ruleMail(.forward, about: message, to: [MailAddress(name: nil, address: address)], text: nil,
                                   send: !delivery.draftOnly)
                case .autoReply(let text):
                    guard shouldAutoReply(to: message) else { continue }
                    await ruleMail(.reply, about: message, to: nil, text: text, send: !delivery.draftOnly)
                case .runShortcut(let name):
                    var c = URLComponents(string: "shortcuts://run-shortcut")
                    c?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
                                     URLQueryItem(name: "text", value: message.messageID.flatMap(MessageLink.url)?.absoluteString ?? message.subject)]
                    if let url = c?.url { Platform.openExternally(url) }
                default:
                    continue
                }
            }
        }
        if !deliveries.isEmpty { reloadOutbox() }
    }

    /// Auto-replies never go to robots or lists, and at most once a day per person.
    private func shouldAutoReply(to message: StoredMessage) -> Bool {
        guard message.category == .primary, !SignatureInfo.looksAutomated(message.fromAddress) else { return false }
        var log = UserDefaults.standard.dictionary(forKey: "rules.autoReplied") as? [String: Date] ?? [:]
        let sender = message.fromAddress.lowercased()
        if let last = log[sender], Date().timeIntervalSince(last) < 86_400 { return false }
        log[sender] = Date()
        UserDefaults.standard.set(log, forKey: "rules.autoReplied")
        return true
    }

    private func ruleMail(_ kind: ComposeKind, about message: StoredMessage, to: [MailAddress]?, text: String?, send: Bool) async {
        guard let account = accounts.first(where: { $0.id == message.accountID }),
              let raw = try? await rawMessage(message) else { return }
        let parsed = MIMEParser.parse(raw)
        var draft = Self.draft(kind, replyingTo: parsed, raw: raw, account: account)
        if let to { draft.message.to = to }
        let body = NSMutableAttributedString(string: text.map { $0 + "\n" } ?? "", attributes: RichTextEditor.baseAttributes)
        body.append(draft.body)
        guard let id = saveDraft(draft.message, body: body, accountID: account.id, kind: kind, originalLocalID: message.id) else { return }
        if send, let item = try? store.outboxItem(id: id), let outgoing = item.message {
            _ = try? await syncs[account.id]?.queue(outgoing, kind: kind, originalLocalID: message.id, replacingDraft: id)
        }
    }
}
