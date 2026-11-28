import Foundation

/// Reader mode: the message's own words, laid out for reading.
public enum ReadingText {
    /// Paragraphs without quoted history, signature separators or runs of blank lines.
    public static func paragraphs(_ text: String) -> [String] {
        let own = MailStore.ownText(text)
        var paragraphs: [String] = []
        var current: [String] = []
        for line in own.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == signatureSeparator {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs
    }

    /// Minutes at a typical adult reading speed, at least one.
    public static func minutes(_ text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return max(1, Int((Double(words) / wordsPerMinute).rounded()))
    }

    static let wordsPerMinute = 230.0

    /// RFC 3676's "-- " line, trailing space trimmed.
    static let signatureSeparator = "--"
}
