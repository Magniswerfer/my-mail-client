import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writing help from the on-device model (SPEC §5): thread summaries and follow-up drafts.
/// Nothing leaves the device; when Apple Intelligence isn't available the features stay quiet
/// (summaries) or fall back to a plain template (follow-ups, in the app).
public protocol MailWriter: Sendable {
    /// One or two sentences: where the conversation stands and what's asked of the reader.
    func summarize(_ thread: ThreadDigest) async -> String?
    /// A short, polite nudge in the language of the original: greeting and text, no signature.
    func followUp(_ request: FollowUpRequest) async -> String?
    /// A reply to a message that asks you something: greeting and answer, no signature. The
    /// model doesn't know your plans, so it answers what it can and leaves [brackets] for the rest.
    func reply(_ thread: ThreadDigest, to sender: String?) async -> String?
}

/// A conversation prepared for the model: each message's own words (no quoted history),
/// newest last, trimmed to fit the on-device context window.
public struct ThreadDigest: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var sender: String
        public var date: Date
        public var text: String
        public var isMine: Bool
    }

    public var subject: String
    public var entries: [Entry]

    /// About 1 500 tokens of mail, leaving room for instructions and the answer.
    public static let characterBudget = 6_000

    public init(subject: String, messages: [StoredMessage], ownAddresses: Set<String>) {
        self.subject = subject
        let own = Set(ownAddresses.map { $0.lowercased() })
        var entries = messages.sorted { $0.date < $1.date }.map { m in
            Entry(sender: m.fromName?.isEmpty == false ? m.fromName! : m.fromAddress, date: m.date,
                  text: MailStore.ownText(m.plainText ?? m.preview), isMine: own.contains(m.fromAddress.lowercased()))
        }
        // Over budget: keep the newest messages whole and shorten the oldest first.
        var total = entries.reduce(0) { $0 + $1.text.count }
        var i = 0
        while total > Self.characterBudget, i < entries.count {
            let excess = total - Self.characterBudget
            let keep = max(200, entries[i].text.count - excess)
            if keep < entries[i].text.count {
                total -= entries[i].text.count - keep
                entries[i].text = String(entries[i].text.prefix(keep)) + "…"
            }
            i += 1
        }
        self.entries = entries
    }

    /// Worth summarizing: a real back-and-forth, or one long message.
    public var isWorthSummarizing: Bool {
        entries.count >= 3 || entries.reduce(0) { $0 + $1.text.count } >= 1_200
    }

    public var prompt: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "Subject: \(subject)\n"
        for e in entries {
            out += "\n--- \(e.isMine ? "Me" : e.sender), \(f.string(from: e.date)):\n\(e.text)\n"
        }
        return out
    }

    /// What the summary was made from; a new message makes it stale.
    public var basis: String {
        "\(entries.count)|\(entries.last.map { "\($0.date.timeIntervalSince1970)" } ?? "")"
    }
}

public struct FollowUpRequest: Sendable, Hashable {
    public var subject: String
    /// What you wrote last (your own words only).
    public var lastMessage: String
    public var recipientName: String?
    public var daysWaiting: Int

    public init(subject: String, lastMessage: String, recipientName: String?, daysWaiting: Int) {
        self.subject = subject
        self.lastMessage = String(MailStore.ownText(lastMessage).prefix(2_000))
        self.recipientName = recipientName
        self.daysWaiting = daysWaiting
    }
}

/// The real writer, on Apple Intelligence devices.
public struct FoundationModelsWriter: MailWriter {
    public init?() {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        #else
        return nil
        #endif
    }

    public func summarize(_ thread: ThreadDigest) async -> String? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You summarize an email conversation for the reader ("Me"). Write in the language the \
            emails are written in (often Danish or English). At most two short sentences: where \
            things stand, then anything the reader is asked to do or decide, with dates. No \
            greeting, no preamble like "This conversation", no bullet points, no invented facts.
            """)
        do {
            let response = try await session.respond(to: thread.prompt, generating: WrittenText.self)
            return Self.clean(response.content.text)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public func followUp(_ request: FollowUpRequest) async -> String? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You write a brief, friendly follow-up to an email the user sent that has had no reply. \
            Use the same language and tone (formal or casual) as the user's email. Start with a short \
            greeting using the recipient's first name if given ("Hi Anna," / "Hej Anna,"), then a \
            blank line, then one to three sentences that refer to the specific question or request \
            and make it easy to answer. Never apologise for following up, never guilt-trip, no \
            sign-off, no subject line.
            """)
        let who = request.recipientName.map { "Recipient: \($0)\n" } ?? ""
        do {
            let response = try await session.respond(to: """
                \(who)Subject: \(request.subject)
                Days without a reply: \(request.daysWaiting)

                My email:
                \(request.lastMessage)
                """, generating: WrittenText.self)
            return Self.clean(response.content.text)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public func reply(_ thread: ThreadDigest, to sender: String?) async -> String? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You draft the user's ("Me") reply to the newest message of an email conversation. Use \
            the same language and tone as that message. Start with a short greeting using the \
            sender's first name if given, then a blank line, then a brief answer (two to five \
            sentences). You don't know the user's calendar, preferences or facts that aren't in the \
            conversation: where an answer needs them, write a short placeholder in square \
            brackets, like [time that suits me]. Never invent facts, commitments or dates. No \
            sign-off, no subject line.
            """)
        let who = sender.map { "Sender's first name: \($0)\n" } ?? ""
        do {
            let response = try await session.respond(to: who + thread.prompt, generating: WrittenText.self)
            return Self.clean(response.content.text)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(FoundationModels)
@Generable
struct WrittenText {
    @Guide(description: "The text, in the emails' language")
    var text: String
}
#endif
