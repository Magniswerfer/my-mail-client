import Foundation

/// What a rule pass did, for the app (status line, notifications).
public struct RuleReport: Sendable {
    public var checked = 0
    public var matched = 0
    /// Runs whose rules asked for a notification.
    public var notify: [RuleRun] = []
    public init() {}
}

extension AccountSync {
    /// Runs your rules on Inbox mail that arrived since the last pass (SPEC §6: after spam and
    /// AI sorting, so rules can read and override the category). Actions go through the same
    /// optimistic, queued triage path as your own key presses, and each run is recorded so it
    /// can be undone.
    @discardableResult
    public func runRules(engine: RuleEngine) async throws -> RuleReport {
        let rules = try store.rules().filter { $0.isEnabled && $0.isComplete }
        let (candidates, upTo) = try store.ruleCandidates(accountID: account.id)
        var report = RuleReport()
        if !rules.isEmpty {
            for message in candidates {
                report.checked += 1
                let matched = await engine.matchingRules(rules, for: message)
                guard !matched.isEmpty, let run = try apply(matched, to: message) else { continue }
                report.matched += 1
                if run.actions.contains(.notify) { report.notify.append(run) }
            }
        }
        if upTo > 0 { try store.markRulesChecked(accountID: account.id, upTo: upTo) }
        return report
    }

    /// "Run on the Inbox now": one rule over the mail already in this account's Inbox.
    @discardableResult
    public func runRuleOnInbox(_ rule: Rule, engine: RuleEngine) async throws -> RuleReport {
        var probe = rule
        probe.isEnabled = true
        probe.stopProcessing = false
        var report = RuleReport()
        guard probe.isComplete else { return report }
        for message in try store.inboxMessages(accountID: account.id) {
            report.checked += 1
            guard await engine.matches(probe, message), let run = try apply([probe], to: message) else { continue }
            report.matched += 1
            if run.actions.contains(.notify) { report.notify.append(run) }
        }
        return report
    }

    /// Applies the merged actions of `rules` to the message's conversation and records the run.
    func apply(_ rules: [Rule], to message: StoredMessage) throws -> RuleRun? {
        guard let id = message.id, let threadID = message.threadID else { return nil }
        // The message may have moved since it was read (you were quicker than the rule).
        guard let current = try store.message(id: id), current.mailbox == "INBOX" else { return nil }
        let actions = RuleAction.merged(rules)
        let threads = [threadID]
        var applied: [RuleAction] = []
        for action in actions {
            switch action {
            case .setCategory(let category):
                guard category != current.category else { continue }
                try store.setCategory(category, reason: .rule(name: rules.last { $0.actions.contains(action) }?.name ?? ""), ids: [id])
            case .pin: try perform(.pin, threadIDs: threads)
            case .markRead: try perform(.markRead, threadIDs: threads)
            case .replyLater: try perform(.replyLater, threadIDs: threads)
            case .done: try perform(.done, threadIDs: threads)
            case .snooze(let hours):
                try perform(.snooze(until: hours.map { Date().addingTimeInterval(TimeInterval($0) * 3600) }), threadIDs: threads)
            case .moveToFolder(let path):
                guard path != "INBOX" else { continue }
                try perform(.move(toMailbox: path), threadIDs: threads)
            case .notify: break
            }
            applied.append(action)
        }
        guard !applied.isEmpty else { return nil }
        let runID = try store.recordRuleRun(accountID: account.id, message: current, rules: rules, actions: applied)
        SyncLog.info("rules: \(rules.map(\.name)) on message \(id): \(applied)")
        return try store.ruleRuns(limit: 1).first { $0.id == runID }
    }

    /// Reverses what a rule did to a conversation (newest action first).
    public func undo(_ run: RuleRun) throws {
        guard run.undoneAt == nil, run.accountID == account.id else { return }
        let threads = [run.threadID]
        for action in run.actions.reversed() {
            switch action {
            case .setCategory:
                try store.restoreCategories([.init(id: run.messageID, category: run.previousCategory, reason: run.previousReason)])
            case .pin: try perform(.unpin, threadIDs: threads)
            case .markRead: try perform(.markUnread, threadIDs: threads)
            case .replyLater: try perform(.clearReplyLater, threadIDs: threads)
            case .done:
                try perform(.moveToInbox, threadIDs: threads, from: try path(for: .archive) ?? "Archive")
            case .snooze: try perform(.unsnooze, threadIDs: threads)
            case .moveToFolder(let path): try perform(.moveToInbox, threadIDs: threads, from: path)
            case .notify: break
            }
        }
        try store.markRuleRunUndone(id: run.id)
    }
}
