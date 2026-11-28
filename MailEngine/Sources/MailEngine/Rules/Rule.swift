import Foundation

/// An Outlook-style rule (SPEC §6): ordered, conditions + actions, optionally the last one to run.
/// Rules run on new Inbox mail after spam and AI sorting, so they can read and override the category.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    /// All conditions must hold (true) or any one of them (false).
    public var matchAll: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    /// Later rules don't run on a message this rule matched.
    public var stopProcessing: Bool

    public init(id: String = UUID().uuidString, name: String, isEnabled: Bool = true, matchAll: Bool = true,
                conditions: [RuleCondition], actions: [RuleAction], stopProcessing: Bool = false) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.matchAll = matchAll
        self.conditions = conditions
        self.actions = actions
        self.stopProcessing = stopProcessing
    }

    /// A rule needs at least one condition and one action to do anything.
    public var isComplete: Bool { !conditions.isEmpty && !actions.isEmpty && actions.allSatisfy(\.isComplete) }

    /// Whether any condition needs the on-device model (slower; runs after the cheap ones).
    public var usesLanguageModel: Bool { !aboutConditions.isEmpty }

    /// The natural-language conditions, which need the on-device model.
    var aboutConditions: [AboutCondition] { conditions.compactMap(\.aboutCondition) }

    /// Every condition that can be decided from the message alone.
    var cheapConditions: [RuleCondition] { conditions.filter { $0.aboutCondition == nil } }
}

/// Text comparison, case- and accent-insensitive.
public struct TextMatch: Codable, Sendable, Hashable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        case contains, doesNotContain, equals, beginsWith, endsWith
    }
    public var operation: Operation
    public var value: String

    public init(_ operation: Operation, _ value: String) {
        self.operation = operation
        self.value = value
    }

    public func matches(_ text: String) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch operation {
        case .contains: return text.range(of: needle, options: options) != nil
        case .doesNotContain: return text.range(of: needle, options: options) == nil
        case .equals: return text.compare(needle, options: options) == .orderedSame
        case .beginsWith: return text.range(of: needle, options: options.union(.anchored)) != nil
        case .endsWith: return text.range(of: needle, options: options.union([.anchored, .backwards])) != nil
        }
    }
}

public enum RuleCondition: Codable, Sendable, Hashable {
    /// The sender's name or address ("@shop.dk" with endsWith matches a whole domain).
    case sender(TextMatch)
    /// Any To/Cc name or address.
    case recipient(TextMatch)
    case subject(TextMatch)
    /// The subject or the message text.
    case text(TextMatch)
    case category(MailCategory)
    case hasAttachment(Bool)
    /// Natural language ("about shoes"): embedding pre-filter, then an on-device yes/no.
    case about(AboutCondition)

    var aboutCondition: AboutCondition? {
        if case .about(let about) = self { about } else { nil }
    }
}

/// A natural-language condition (SPEC §6).
public struct AboutCondition: Codable, Sendable, Hashable {
    public var description: String
    /// Minimum embedding similarity before the model is asked; lower asks about more mail.
    public var threshold: Float
    /// Your ✓/✗ from the preview, given to the model as examples.
    public var examples: [Example]

    public struct Example: Codable, Sendable, Hashable {
        public var text: String
        public var matches: Bool
        public init(text: String, matches: Bool) {
            self.text = text
            self.matches = matches
        }
    }

    public init(_ description: String, threshold: Float = 0.3, examples: [Example] = []) {
        self.description = description
        self.threshold = threshold
        self.examples = examples
    }
}

extension RuleAction {
    /// The action's kind, without its address, text or folder (for logs).
    public var logName: String {
        switch self {
        case .setCategory: "category"
        case .pin: "pin"
        case .markRead: "markRead"
        case .replyLater: "replyLater"
        case .done: "done"
        case .snooze: "snooze"
        case .moveToFolder: "move"
        case .notify: "notify"
        case .forward: "forward"
        case .autoReply: "autoReply"
        case .runShortcut: "shortcut"
        }
    }
}

public enum RuleAction: Codable, Sendable, Hashable {
    case setCategory(MailCategory)
    case pin
    case markRead
    case replyLater
    /// Archive (Done).
    case done
    /// For this many hours; nil is "someday".
    case snooze(hours: Int?)
    case moveToFolder(String)
    /// Show a notification (delivered by the app).
    case notify
    /// Forward the message (the app sends it; rules with "about" conditions leave a draft, SPEC §6).
    case forward(to: String)
    /// Answer with this text (never to automated senders, at most once a day per person).
    case autoReply(text: String)
    /// Run a Shortcut with a link to the message.
    case runShortcut(name: String)

    /// Carried out by the app after the engine pass (they need the composer, Shortcuts or the UI).
    public var isAppDelivered: Bool {
        switch self {
        case .notify, .forward, .autoReply, .runShortcut: true
        default: false
        }
    }

    /// Whether the action has what it needs (an address, a text, a name, a folder).
    public var isComplete: Bool {
        switch self {
        case .forward(let to): to.contains("@")
        case .autoReply(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .runShortcut(let name): !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .moveToFolder(let path): !path.isEmpty
        default: true
        }
    }

    /// Whether the action takes the conversation out of the Inbox. A rule applies at most one.
    var leavesInbox: Bool {
        switch self {
        case .done, .snooze, .moveToFolder: true
        default: false
        }
    }
}
