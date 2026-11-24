import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks quoted text (reply quotes, "> " paragraphs). Rendered as <blockquote>.
    static let tidingsQuote = NSAttributedString.Key("TidingsQuote")
    /// Marks the signature block so switching identity can replace it.
    static let tidingsSignature = NSAttributedString.Key("TidingsSignature")
}

/// The composer's body (SPEC §9: rich text with Markdown-style input shortcuts).
///
/// An NSTextView, so Writing Tools, spell check, dictation and ⌘B/⌘I come from the system.
/// Typing `- `, `* `, `1. ` or `> ` at the start of a line makes a list or a quote;
/// completed `**bold**`, `*italic*` and `_italic_` turn into formatting (typed or pasted).
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.usesFindBar = true
        view.writingToolsBehavior = .complete
        view.font = Self.baseFont
        view.typingAttributes = Self.baseAttributes
        view.textContainerInset = NSSize(width: 4, height: 10)
        view.drawsBackground = false
        scroll.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        context.coordinator.textView = view
        if focusOnAppear {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, !context.coordinator.isEditing else { return }
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
    }

    static let baseFont = NSFont.systemFont(ofSize: 14)
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    static var quoteAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.headIndent = 14
        style.firstLineHeadIndent = 14
        return [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style, .tidingsQuote: true]
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        var isEditing = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView, !isEditing else { return }
            isEditing = true
            applyInlineFormatting(in: view)
            parent.text = view.attributedString().copy() as! NSAttributedString
            isEditing = false
        }

        static let inlineRules: [(NSRegularExpression, NSFontTraitMask, Int)] = [
            (try! NSRegularExpression(pattern: #"\*\*([^*\n]+?)\*\*"#), .boldFontMask, 2),
            (try! NSRegularExpression(pattern: #"(?<![*\w])\*([^*\n]+?)\*(?![*\w])"#), .italicFontMask, 1),
            (try! NSRegularExpression(pattern: #"(?<![_\w])_([^_\n]+?)_(?![_\w])"#), .italicFontMask, 1),
        ]

        /// Turns completed `**bold**`, `*italic*` and `_italic_` in the edited paragraph into
        /// formatting. Runs after every change, so typing, pasting and dictation all work.
        private func applyInlineFormatting(in view: NSTextView) {
            guard let storage = view.textStorage, storage.length > 0 else { return }
            let caret = view.selectedRange().location
            var paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(caret, storage.length - 1), length: 0))
            var newCaret = caret
            var changed = false
            for (regex, trait, markerLength) in Self.inlineRules {
                while let match = regex.firstMatch(in: storage.string, range: paragraph) {
                    let inner = match.range(at: 1)
                    let innerText = (storage.string as NSString).substring(with: inner)
                    var attrs = storage.attributes(at: inner.location, effectiveRange: nil)
                    let font = (attrs[.font] as? NSFont) ?? RichTextEditor.baseFont
                    attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
                    if !changed { storage.beginEditing(); changed = true }
                    storage.replaceCharacters(in: match.range, with: NSAttributedString(string: innerText, attributes: attrs))
                    let removed = markerLength * 2
                    paragraph.length -= removed
                    if newCaret > match.range.location { newCaret = max(match.range.location, newCaret - removed) }
                }
            }
            guard changed else { return }
            storage.endEditing()
            view.setSelectedRange(NSRange(location: min(newCaret, storage.length), length: 0))
            view.typingAttributes = RichTextEditor.baseAttributes
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, let storage = view.textStorage else { return true }
            let string = storage.string as NSString

            // Return on an empty list item or quote line ends the list/quote.
            if text == "\n" {
                let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
                let content = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
                let style = storage.attribute(.paragraphStyle, at: min(paragraph.location, max(0, storage.length - 1)), effectiveRange: nil) as? NSParagraphStyle
                let inList = !(style?.textLists.isEmpty ?? true)
                let inQuote = storage.length > 0 && storage.attribute(.tidingsQuote, at: min(paragraph.location, storage.length - 1), effectiveRange: nil) != nil
                if content.isEmpty, inList || inQuote {
                    storage.setAttributes(RichTextEditor.baseAttributes, range: paragraph)
                    view.typingAttributes = RichTextEditor.baseAttributes
                    return false
                }
                return true
            }

            // Block shortcuts: "- ", "* ", "1. ", "> " at the start of a paragraph.
            if text == " " {
                let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
                let prefix = string.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
                let marker: NSTextList.MarkerFormat? = switch prefix {
                case "-", "*": .disc
                case "1.": .decimal
                default: nil
                }
                if let marker {
                    replace(prefix: prefix, in: view, at: paragraph.location) { attrs in
                        let style = NSMutableParagraphStyle()
                        style.textLists = [NSTextList(markerFormat: marker, options: 0)]
                        style.headIndent = 24
                        style.firstLineHeadIndent = 4
                        attrs[.paragraphStyle] = style
                    }
                    // Show the marker right away; NSTextView inserts it on the next newline otherwise.
                    let bullet = marker == .disc ? "\t•\t" : "\t1.\t"
                    view.insertText(bullet, replacementRange: NSRange(location: paragraph.location, length: 0))
                    return false
                }
                if prefix == ">" {
                    replace(prefix: prefix, in: view, at: paragraph.location) { attrs in
                        attrs.merge(RichTextEditor.quoteAttributes) { _, new in new }
                    }
                    return false
                }
            }

            return true
        }

        private func replace(prefix: String, in view: NSTextView, at location: Int, style: (inout [NSAttributedString.Key: Any]) -> Void) {
            guard let storage = view.textStorage else { return }
            let prefixRange = NSRange(location: location, length: (prefix as NSString).length)
            view.shouldChangeText(in: prefixRange, replacementString: "")
            storage.replaceCharacters(in: prefixRange, with: "")
            var attrs = RichTextEditor.baseAttributes
            style(&attrs)
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            storage.addAttributes(attrs, range: paragraph)
            view.typingAttributes = attrs
            view.didChangeText()
        }

    }
}

/// Turns the editor's attributed text into the two bodies a mail needs.
enum MailBodyConverter {
    static func plainText(_ text: NSAttributedString) -> String {
        var lines: [String] = []
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            var line = string.substring(with: range).trimmingCharacters(in: .newlines)
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            line = line.replacingOccurrences(of: "\t•\t", with: "• ").replacingOccurrences(of: "\t", with: " ")
            if attrs[.tidingsQuote] != nil { line = "> " + line }
            lines.append(line)
            location = NSMaxRange(range)
        }
        return lines.joined(separator: "\n")
    }

    /// Clean, inline-styled HTML: <p>, <ul>/<ol>, <blockquote>, <b>/<i>/<u>/<s>, links.
    static func html(_ text: NSAttributedString) -> String {
        var html = ""
        var openList: String?
        var inQuote = false
        let string = text.string as NSString
        var location = 0

        func closeBlocks(list: String?, quote: Bool) {
            if openList != nil, openList != list { html += "</\(openList!)>"; openList = nil }
            if inQuote, !quote { html += "</blockquote>"; inQuote = false }
        }

        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let list = style?.textLists.first.map { $0.markerFormat == .decimal ? "ol" : "ul" }
            let quote = attrs[.tidingsQuote] != nil
            closeBlocks(list: list, quote: quote)
            if quote, !inQuote { html += "<blockquote style=\"margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex;color:#555\">"; inQuote = true }
            if let list, openList == nil { html += "<\(list)>"; openList = list }

            var content = text.attributedSubstring(from: range)
            // Drop the visible list marker we inserted ("\t•\t", "\t1.\t").
            if list != nil, let markerEnd = content.string.range(of: #"^\t[^\t]*\t"#, options: .regularExpression) {
                let length = content.string.distance(from: content.string.startIndex, to: markerEnd.upperBound)
                content = content.attributedSubstring(from: NSRange(location: length, length: content.length - length))
            }
            let inner = inlineHTML(content)
            if list != nil {
                html += "<li>\(inner)</li>"
            } else {
                html += inner.isEmpty ? "<p><br></p>" : "<p style=\"margin:0\">\(inner)</p>"
            }
            location = NSMaxRange(range)
        }
        closeBlocks(list: nil, quote: false)
        return "<div style=\"font-family:-apple-system,Helvetica,sans-serif;font-size:14px\">\(html)</div>"
    }

    static func inlineHTML(_ text: NSAttributedString) -> String {
        var out = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var piece = escape((text.string as NSString).substring(with: range).trimmingCharacters(in: .newlines))
            guard !piece.isEmpty else { return }
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { piece = "<b>\(piece)</b>" }
                if traits.contains(.italicFontMask) { piece = "<i>\(piece)</i>" }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { piece = "<u>\(piece)</u>" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { piece = "<s>\(piece)</s>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                piece = "<a href=\"\(escape(href))\">\(piece)</a>"
            }
            out += piece
        }
        return out.replacingOccurrences(of: "\u{2028}", with: "<br>")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
