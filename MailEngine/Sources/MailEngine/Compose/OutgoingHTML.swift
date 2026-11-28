import Foundation

/// The pieces the composer's HTML is made from, so every mail we send is a complete, valid
/// document that reads the same in Apple Mail, Gmail, Outlook and on the web.
public enum OutgoingHTML {
    /// The font stack: San Francisco on Apple devices, the closest system sans elsewhere
    /// (Helvetica Neue / Helvetica, then Arial on Windows and Android).
    public static let fontFamily = "-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif"

    /// A whole HTML document around `body`: doctype, UTF-8 declared in the document as well as
    /// the MIME header (for when it is saved or forwarded as a file), a viewport so phones
    /// don't shrink it, and the body text set in `fontFamily` at `fontSize` px.
    ///
    /// No colours are set: the recipient's client picks text and background, so dark mode
    /// works everywhere.
    public static func document(_ body: String, fontSize: Int = 14) -> String {
        "<!DOCTYPE html>"
            + "<html><head>"
            + "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "</head>"
            + "<body style=\"word-wrap:break-word;overflow-wrap:break-word\">"
            + "<div style=\"font-family:\(fontFamily);font-size:\(fontSize)px\">"
            + body
            + "</div></body></html>"
    }

    /// Text escaped for HTML, keeping what HTML would otherwise collapse: runs of spaces,
    /// a leading or trailing space, and tabs (as four columns). Pass `false` for an edge that
    /// isn't the end of the line (text between two differently formatted runs), so a single
    /// space there stays an ordinary, breakable one.
    public static func text(_ s: String, leadingEdge: Bool = true, trailingEdge: Bool = true) -> String {
        let escaped = escape(s.replacingOccurrences(of: "\t", with: "    "))
        guard escaped.contains(" ") else { return escaped }
        var out = ""
        var run = 0
        func flush(atEnd: Bool) {
            guard run > 0 else { return }
            // n spaces → n-1 non-breaking and one ordinary, so the line can still wrap there.
            // At the very start or end a lone space would collapse: make it non-breaking too.
            if run == 1, (out.isEmpty && leadingEdge) || (atEnd && trailingEdge) { out += "&nbsp;" } else {
                out += String(repeating: "&nbsp;", count: run - 1) + " "
            }
            run = 0
        }
        for ch in escaped {
            if ch == " " { run += 1; continue }
            flush(atEnd: false)
            out.append(ch)
        }
        flush(atEnd: true)
        return out
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A link as plain text: the text, then the address in angle brackets unless the text
    /// already says where it goes ("Read more <https://…>", but just "creativeoak.io").
    public static func plainTextLink(text: String, href: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !href.isEmpty else { return text }
        return SignatureHTML.linkMentioned(text: trimmed, href: href) ? text : "\(text) <\(href)>"
    }
}
