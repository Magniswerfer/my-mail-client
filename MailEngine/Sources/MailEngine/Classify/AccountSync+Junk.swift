import Foundation

/// What the junk filter did in one pass.
public struct JunkReport: Sendable {
    /// The move to Junk, for "Moved to Junk · Undo".
    public var change: TriageChange?
    public var moved = 0
    public var warned = 0
    public init() {}
}

extension AccountSync {
    /// Learns from what this account has in Junk (spam) and from mail you've kept (fine), a
    /// batch at a time so the first run on a big mailbox doesn't hold up syncing.
    @discardableResult
    public func learnJunk(spamLimit: Int = 300, hamLimit: Int = 600) throws -> JunkFilter.Counts {
        let spam = try store.unlearnedJunk(accountID: account.id, limit: spamLimit)
        let ham = try store.unlearnedHam(accountID: account.id, ownAddresses: Set(account.addresses), limit: hamLimit)
        try store.learnJunk(spam, as: .spam)
        try store.learnJunk(ham, as: .ham)
        if !spam.isEmpty || !ham.isEmpty { SyncLog.info("junk: learned \(spam.count) junk, \(ham.count) fine") }
        return .init(spam: spam.count, ham: ham.count)
    }

    /// Scores new Inbox mail. Near-certain junk goes to Junk (on the server, so other clients
    /// agree); likely junk gets a warning and stays. Returns what's left for rules.
    func screenJunk(_ messages: [StoredMessage]) throws -> (kept: [StoredMessage], report: JunkReport) {
        var report = JunkReport()
        guard try path(for: .junk) != nil else { return (messages, report) }
        let totals = try store.junkTotals()
        guard totals.spam >= JunkFilter.minSpam, totals.ham >= JunkFilter.minHam else { return (messages, report) }
        var kept: [StoredMessage] = []
        var junkThreads: [String] = []
        for message in messages {
            guard let id = message.id, let thread = message.threadID, try !isProtectedFromJunk(message),
                  let score = try store.junkScore(message), score >= JunkFilter.warningThreshold else {
                kept.append(message)
                continue
            }
            try store.setJunkScore(score, ids: [id])
            // Only a conversation that is just this message moves; anything more gets a warning.
            let inInbox = try store.messages(inThread: thread).filter { $0.accountID == account.id && $0.mailbox == "INBOX" }
            if score >= JunkFilter.junkThreshold, inInbox.count == 1 {
                junkThreads.append(thread)
                SyncLog.info("junk: moving message \(id) (score \(Int(score * 100)))")
            } else {
                report.warned += 1
                kept.append(message)
            }
        }
        if !junkThreads.isEmpty, var change = try perform(.junk, threadIDs: junkThreads, learn: false) {
            change.byFilter = true
            report.change = change
            report.moved = junkThreads.count
        }
        return (kept, report)
    }

    /// Mail the filter never moves: yours, from people you've written to or marked safe, from
    /// senders you've sorted, in conversations you're part of, pinned, or invitations.
    func isProtectedFromJunk(_ message: StoredMessage) throws -> Bool {
        let own = Set(account.addresses.map { $0.lowercased() })
        let sender = message.fromAddress.lowercased()
        if own.contains(sender) || message.flags.contains("\\Flagged") || message.invite != nil { return true }
        if try store.senderRule(for: sender) != nil || store.isTrustedSender(sender) { return true }
        if try store.hasWrittenTo(sender, ownAddresses: own) { return true }
        if let thread = message.threadID,
           try store.messages(inThread: thread).contains(where: { own.contains($0.fromAddress.lowercased()) }) { return true }
        return false
    }

    /// "It's fine": the warning goes and the filter learns the conversation as fine.
    public func markNotJunk(threadIDs: [String]) throws {
        let messages = try threadIDs.flatMap { try store.messages(inThread: $0) }.filter { $0.accountID == account.id }
        try store.learnJunk(messages.filter { !isOwn($0) }, as: .ham)
        try store.setJunkScore(0, ids: messages.compactMap(\.id))
    }

    func isOwn(_ message: StoredMessage) -> Bool {
        account.addresses.contains { $0.caseInsensitiveCompare(message.fromAddress) == .orderedSame }
    }

    /// What a move teaches: into Junk is junk, out of Junk (not to Trash) is fine.
    func learnFromMove(_ kind: TriageKind, localIDs: [Int64], from source: String, to target: String) throws {
        guard let junk = try path(for: .junk) else { return }
        let label: JunkLabel
        if target.caseInsensitiveCompare(junk) == .orderedSame {
            label = .spam
        } else if source.caseInsensitiveCompare(junk) == .orderedSame, kind != .trash {
            label = .ham
        } else {
            return
        }
        let messages = try localIDs.compactMap { try store.message(id: $0) }.filter { !isOwn($0) }
        try store.learnJunk(messages, as: label)
        if label == .ham { try store.setJunkScore(0, ids: messages.compactMap(\.id)) }
    }

    /// Undo: a move you made forgets what it taught; undoing the filter's own move teaches the
    /// opposite ("that wasn't junk").
    func unlearnUndone(_ change: TriageChange) throws {
        let messages = try change.snapshots.compactMap { try store.message(id: $0.localID) }
        if change.byFilter {
            try store.learnJunk(messages, as: .ham)
            try store.setJunkScore(0, ids: messages.compactMap(\.id))
        } else {
            for message in messages { try store.forgetJunk(message) }
        }
    }
}

extension MailStore {
    /// Learns several messages in one transaction.
    public func learnJunk(_ messages: [StoredMessage], as label: JunkLabel) throws {
        guard !messages.isEmpty else { return }
        let items = messages.map { (Self.junkKey($0), JunkFilter.tokens(of: $0)) }
        try db.write { db in
            for (key, tokens) in items { try Self.learn(key: key, tokens: tokens, label: label, in: db) }
        }
    }
}
