import Foundation

extension AccountSync {
    /// The push server's pass over new Inbox mail (ADR 0007): which messages deserve a
    /// notification under `policy`. Unlike `runRules`, it **changes nothing**: no rule actions,
    /// no junk moves, no learning. A rule that would set a category counts for the
    /// notification decision only. Muted conversations and mail you sent stay quiet.
    public func notificationPass(policy: NotificationPolicy, engine: RuleEngine = RuleEngine(),
                                 now: Date = Date()) async throws -> [MailNotification] {
        let (candidates, upTo) = try store.ruleCandidates(accountID: account.id)
        guard upTo > 0 else { return [] }
        defer { try? store.markRulesChecked(accountID: account.id, upTo: upTo) }
        let rules = try store.rules().filter { $0.isEnabled && $0.isComplete }
        var arrived: [StoredMessage] = []
        var runs: [RuleRun] = []
        for var message in candidates {
            let matched = rules.isEmpty ? [] : await engine.matchingRules(rules, for: message)
            let actions = matched.flatMap(\.actions)
            // Last category wins, as in `runRules`.
            for case .setCategory(let category) in actions { message.category = category }
            // Mail a rule files away (Done, Snooze, a folder) never notifies, unless it also says so.
            let leaves = actions.contains(where: \.leavesInbox)
            if actions.contains(.notify), let id = message.id, let thread = message.threadID {
                runs.append(RuleRun(id: 0, at: now, accountID: account.id, messageID: id, threadID: thread,
                                    subject: message.subject, sender: message.fromAddress,
                                    ruleIDs: matched.map(\.id), ruleNames: matched.filter { $0.actions.contains(.notify) }.map(\.name),
                                    actions: actions, previousCategory: message.category, previousReason: nil, undoneAt: nil))
            } else if leaves {
                continue
            }
            arrived.append(message)
        }
        return policy.notifications(for: arrived, ruleRuns: runs, ownAddresses: Set(account.addresses), store: store, now: now)
    }
}
