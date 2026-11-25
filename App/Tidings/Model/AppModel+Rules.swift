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

    /// The on-device stack for "about …" conditions (M5.3); nil means they never match.
    var ruleEngine: RuleEngine { RuleEngine(judge: ruleJudge) }

    /// After a sync (and the AI sorting pass that follows it): rules on whatever arrived.
    func scheduleRules() {
        guard ruleTask == nil else { return }
        let syncs = Array(self.syncs.values)
        let engine = ruleEngine
        ruleTask = Task { [weak self] in
            var matched = 0
            var notify: [RuleRun] = []
            for sync in syncs {
                guard let report = try? await sync.runRules(engine: engine) else { continue }
                matched += report.matched
                notify += report.notify
            }
            guard let self else { return }
            self.ruleTask = nil
            if matched > 0 {
                self.ruleCounts = (try? self.store.ruleRunCounts(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
                self.reload()
            }
            self.deliverRuleNotifications(notify)
        }
    }

    /// Rules asked to notify about these; M6 turns them into system notifications.
    func deliverRuleNotifications(_ runs: [RuleRun]) {}

    /// "Run on Inbox now", for every account.
    func runOnInbox(_ rule: Rule) {
        let syncs = Array(self.syncs.values)
        let engine = ruleEngine
        Task {
            var matched = 0
            for sync in syncs {
                matched += (try? await sync.runRuleOnInbox(rule, engine: engine))?.matched ?? 0
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
