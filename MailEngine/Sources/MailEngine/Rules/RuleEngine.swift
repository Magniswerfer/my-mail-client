import Foundation

/// Decides "is this message about …?" for natural-language conditions (SPEC §6). The real one
/// pre-filters by embedding similarity and asks Foundation Models; tests use fakes.
public protocol RuleJudge: Sendable {
    /// nil when it can't tell (no model, or an error): the condition then doesn't match.
    func isAbout(_ condition: AboutCondition, message: StoredMessage) async -> Bool?
}

/// Evaluates rules against messages. Cheap conditions run first and short-circuit, so the
/// on-device model is only asked when the rest of a rule already agrees.
public struct RuleEngine: Sendable {
    public let judge: (any RuleJudge)?

    public init(judge: (any RuleJudge)? = nil) {
        self.judge = judge
    }

    /// The rules that apply to `message`, in order, stopping after a rule marked "stop processing".
    public func matchingRules(_ rules: [Rule], for message: StoredMessage) async -> [Rule] {
        var matched: [Rule] = []
        for rule in rules where rule.isEnabled && rule.isComplete {
            guard await matches(rule, message) else { continue }
            matched.append(rule)
            if rule.stopProcessing { break }
        }
        return matched
    }

    public func matches(_ rule: Rule, _ message: StoredMessage) async -> Bool {
        let cheap = rule.conditions.filter { if case .about = $0 { false } else { true } }
        let slow = rule.conditions.compactMap { if case .about(let about) = $0 { about } else { nil } }
        let body = LazyBody(message: message)
        let cheapResults = cheap.map { evaluate($0, message, body) }
        if rule.matchAll {
            guard cheapResults.allSatisfy({ $0 }) else { return false }
            for about in slow { guard await isAbout(about, message) else { return false } }
            return true
        } else {
            if cheapResults.contains(true) { return true }
            for about in slow where await isAbout(about, message) { return true }
            return false
        }
    }

    private func isAbout(_ about: AboutCondition, _ message: StoredMessage) async -> Bool {
        guard let judge else { return false }
        return await judge.isAbout(about, message: message) ?? false
    }

    func evaluate(_ condition: RuleCondition, _ message: StoredMessage, _ body: LazyBody) -> Bool {
        switch condition {
        case .sender(let match):
            let name = message.fromName ?? ""
            // "Does not contain" must hold for both; the others for either.
            return match.operation == .doesNotContain
                ? match.matches(name) && match.matches(message.fromAddress)
                : match.matches(name) || match.matches(message.fromAddress)
        case .recipient(let match):
            return match.matches(message.recipients)
        case .subject(let match):
            return match.matches(message.subject)
        case .text(let match):
            let text = "\(message.subject)\n\(body.text)"
            return match.matches(text)
        case .category(let category):
            return message.category == category
        case .hasAttachment(let wanted):
            return message.hasAttachments == wanted
        case .about:
            return false
        }
    }

    /// The decompressed body, only if a condition needs it.
    final class LazyBody: @unchecked Sendable {
        let message: StoredMessage
        lazy var text: String = message.plainText ?? message.preview
        init(message: StoredMessage) { self.message = message }
    }

    // MARK: Preview

    /// Inbox mail the rule would match, newest first ("would have matched 143").
    public func preview(_ rule: Rule, store: MailStore, limit: Int = 2000) async throws -> [StoredMessage] {
        var probe = rule
        probe.isEnabled = true
        guard probe.isComplete || !probe.conditions.isEmpty else { return [] }
        if probe.actions.isEmpty { probe.actions = [.notify] }   // matching doesn't depend on actions
        var hits: [StoredMessage] = []
        for message in try store.inboxMessages(limit: limit) {
            try Task.checkCancellation()
            if await matches(probe, message) { hits.append(message) }
        }
        return hits
    }
}

extension RuleAction {
    /// Merges the actions of every matched rule: the last category wins, flags are kept once,
    /// and only the first action that takes mail out of the Inbox runs.
    static func merged(_ rules: [Rule]) -> [RuleAction] {
        var result: [RuleAction] = []
        var category: MailCategory?
        var leaving: RuleAction?
        for action in rules.flatMap(\.actions) {
            switch action {
            case .setCategory(let c): category = c
            case _ where action.leavesInbox: if leaving == nil { leaving = action }
            default: if !result.contains(action) { result.append(action) }
            }
        }
        if let category { result.insert(.setCategory(category), at: 0) }
        if let leaving { result.append(leaving) }
        return result
    }
}
