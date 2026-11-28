import Foundation

/// Cheap signals that a message asks the reader something: a question, or a request phrase,
/// in the sender's own words (quotes and signature ignored). Danish and English.
public enum NeedsReply {
    static let requests = [
        "could you", "can you", "would you", "will you", "please", "let me know", "what do you think",
        "are you available", "do you have time", "any thoughts", "when can", "please confirm",
        "kan du", "vil du", "kunne du", "har du mulighed", "venligst", "lad mig vide", "giv lyd",
        "hvad synes du", "hvad siger du", "passer det", "har du tid", "bekræft",
    ]

    /// Shorter than this ("Thanks!", "OK") is never a request.
    static let minimumLength = 15

    public static func likely(subject: String, text: String) -> Bool {
        let own = SendCheck.ownText(text)
        guard own.count >= minimumLength else { return false }
        if own.contains("?") { return true }
        let lower = own.lowercased()
        return requests.contains { lower.contains($0) } || subject.trimmingCharacters(in: .whitespaces).hasSuffix("?")
    }
}
