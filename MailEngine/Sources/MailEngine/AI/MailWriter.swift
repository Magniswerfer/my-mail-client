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
    /// An old message over budget still keeps this much of its start.
    static let minimumTrimmedLength = 200
    /// One message this long is worth a summary on its own.
    static let longMessageLength = 1_200

    public init(subject: String, messages: [StoredMessage], ownAddresses: Set<String>) {
        self.subject = subject
        let own = Set(ownAddresses.map { $0.lowercased() })
        let entries = messages.sorted { $0.date < $1.date }.map { m in
            Entry(sender: m.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? m.fromAddress, date: m.date,
                  text: MailStore.ownText(m.plainText ?? m.preview), isMine: own.contains(m.fromAddress.lowercased()))
        }
        self.entries = Self.fittingBudget(entries)
    }

    /// Over budget: keeps the newest messages whole and shortens the oldest first.
    static func fittingBudget(_ entries: [Entry]) -> [Entry] {
        var entries = entries
        var total = entries.reduce(0) { $0 + $1.text.count }
        var i = 0
        while total > characterBudget, i < entries.count {
            let excess = total - characterBudget
            let keep = max(minimumTrimmedLength, entries[i].text.count - excess)
            if keep < entries[i].text.count {
                total -= entries[i].text.count - keep
                entries[i].text = String(entries[i].text.prefix(keep)) + "…"
            }
            i += 1
        }
        return entries
    }

    /// Worth summarizing: a real back-and-forth, or one long message.
    public var isWorthSummarizing: Bool {
        entries.count >= 3 || entries.reduce(0) { $0 + $1.text.count } >= Self.longMessageLength
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
    static let maxLastMessageLength = 2_000

    public var subject: String
    /// What you wrote last (your own words only).
    public var lastMessage: String
    public var recipientName: String?
    public var daysWaiting: Int

    public init(subject: String, lastMessage: String, recipientName: String?, daysWaiting: Int) {
        self.subject = subject
        self.lastMessage = String(MailStore.ownText(lastMessage).prefix(Self.maxLastMessageLength))
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
        await write(instructions: Self.summaryInstructions, prompt: thread.prompt)
    }

    public func followUp(_ request: FollowUpRequest) async -> String? {
        let who = request.recipientName.map { "Recipient: \($0)\n" } ?? ""
        return await write(instructions: Self.followUpInstructions, prompt: """
            \(who)Subject: \(request.subject)
            Days without a reply: \(request.daysWaiting)

            My email:
            \(request.lastMessage)
            """)
    }

    public func reply(_ thread: ThreadDigest, to sender: String?) async -> String? {
        let who = sender.map { "Sender's first name: \($0)\n" } ?? ""
        return await write(instructions: Self.replyInstructions, prompt: who + thread.prompt)
    }

    /// One model session: the cleaned answer, or nil when the model fails or says nothing.
    private func write(instructions: String, prompt: String) async -> String? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: WrittenText.self)
            return Self.clean(response.content.text)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static let summaryInstructions = """
        You summarize an email conversation for the reader ("Me"). Write in the language the \
        emails are written in (often Danish or English). At most two short sentences: where \
        things stand, then anything the reader is asked to do or decide, with dates. No \
        greeting, no preamble like "This conversation", no bullet points, no invented facts.
        """

    static let followUpInstructions = """
        You write a brief, friendly follow-up to an email the user sent that has had no reply. \
        Use the same language and tone (formal or casual) as the user's email. Start with a short \
        greeting using the recipient's first name if given ("Hi Anna," / "Hej Anna,"), then a \
        blank line, then one to three sentences that refer to the specific question or request \
        and make it easy to answer. Never apologise for following up, never guilt-trip, no \
        sign-off, no subject line.
        """

    static let replyInstructions = """
        You draft the user's ("Me") reply to the newest message of an email conversation. Use \
        the same language and tone as that message. Start with a short greeting using the \
        sender's first name if given, then a blank line, then a brief answer (two to five \
        sentences). You don't know the user's calendar, preferences or facts that aren't in the \
        conversation: where an answer needs them, write a short placeholder in square \
        brackets, in the reply's language, like [time that suits me] or [tidspunkt der passer \
        mig]. Never invent facts, commitments or dates. No \
        sign-off, no subject line.
        """

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        let unsigned = stripSignOff(trimmed)
        return unsigned.isEmpty ? nil : unsigned
    }

    /// Closings the model adds despite "no sign-off" (Danish and English), lower-cased.
    static let closings: Set<String> = [
        "best", "best regards", "regards", "kind regards", "warm regards", "all the best", "cheers",
        "thanks", "thank you", "many thanks", "sincerely", "yours",
        "mvh", "med venlig hilsen", "venlig hilsen", "hilsen", "kh", "kærlig hilsen",
        "bedste hilsner", "de bedste hilsner", "tak", "mange tak",
    ]

    /// Drops a trailing "Best,\nMagnus" / "Mvh\nMagnus": the compose body adds the identity's
    /// signature, so the name ended up there twice. A closing counts when it ends in a comma or
    /// a short name line follows it; a final "Thanks!" on its own is kept as content.
    public static func stripSignOff(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        func closing(_ line: String) -> (isClosing: Bool, hasComma: Bool) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let hasComma = t.hasSuffix(",")
            let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: ",.!")).lowercased()
            return (closings.contains(bare), hasComma)
        }
        func isShortName(_ line: String) -> Bool {
            let words = line.split(separator: " ")
            return (1...3).contains(words.count) && words.allSatisfy { $0.first?.isUppercase == true }
                && !line.contains(where: { ".?!:".contains($0) })
        }
        guard let last = lines.last else { return text }
        var cut: Int?
        if closing(last).isClosing && closing(last).hasComma {
            cut = lines.count - 1
        } else if lines.count >= 2, isShortName(last), closing(lines[lines.count - 2]).isClosing {
            cut = lines.count - 2
        }
        guard let cut, cut > 0 else { return text }
        return lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(FoundationModels)
@Generable
struct WrittenText {
    @Guide(description: "The text, in the emails' language")
    var text: String
}
#endif
