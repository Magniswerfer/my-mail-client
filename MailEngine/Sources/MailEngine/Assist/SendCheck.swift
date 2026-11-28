import Foundation

/// Last look before sending (Gmail/Outlook-style): did you mention an attachment and forget it,
/// or name someone from the conversation who isn't on the message any more?
public enum SendCheck {
    public enum Problem: Sendable, Hashable {
        case missingAttachment(phrase: String)
        case missingPerson(MailAddress)
    }

    /// Words that promise an attachment (English, Danish, Norwegian, Swedish, German).
    static let attachmentPhrases = [
        "attached", "attachment", "attaching", "enclosed", "see the file", "find the file",
        "vedhæft", "vedlagt", "vedlagte", "bilag", "i bilaget",
        "vedlegg", "bifogad", "bifogar", "bilaga",
        "anhang", "angehängt", "anbei", "im anhang",
    ]

    /// - Parameters:
    ///   - text: the plain text you wrote. Quotes ("> ") and the signature ("-- ") are ignored.
    ///   - conversationPeople: everyone on the message you're replying to.
    public static func problems(text: String, attachmentCount: Int, recipients: [MailAddress],
                                conversationPeople: [MailAddress], ownAddresses: Set<String>) -> [Problem] {
        let own = ownText(text)
        let lower = own.lowercased()
        var problems: [Problem] = []
        if attachmentCount == 0,
           let phrase = attachmentPhrases.first(where: { phrase in
               lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))", options: .regularExpression) != nil
           }) {
            problems.append(.missingAttachment(phrase: phrase))
        }
        let mine = Set(ownAddresses.map { $0.lowercased() })
        let included = Set(recipients.map { $0.address.lowercased() })
        var seen = Set<String>()
        // Greeting lines name the people you're writing *to*, so names there count too.
        // Capitalised, so "Bo" counts but "bo" (to live) doesn't.
        let words = Set(own.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init))
        for person in conversationPeople {
            let address = person.address.lowercased()
            guard !mine.contains(address), !included.contains(address), seen.insert(address).inserted,
                  person.name?.isEmpty == false else { continue }
            let first = IntroReply.firstName(person)
            if first.count >= 2, first.first?.isUppercase == true, words.contains(first) { problems.append(.missingPerson(person)) }
        }
        return problems
    }

    /// The part above the signature, without quoted lines.
    static func ownText(_ text: String) -> String {
        let beforeSignature = text.components(separatedBy: "\n-- \n").first ?? text
        return MailStore.ownText(beforeSignature)
    }
}
