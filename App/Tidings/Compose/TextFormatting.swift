import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bold, italic, underline and lists from buttons, menus and ⌘K. The keyboard shortcuts
/// (⌘B, ⌘I, ⌘U) and the Markdown-style ones (`**bold**`, `- `, `1. `) keep working too.
enum TextFormat: String, CaseIterable {
    case bold, italic, underline, bulletList, numberedList

    var title: String {
        switch self {
        case .bold: String(localized: "Bold")
        case .italic: String(localized: "Italic")
        case .underline: String(localized: "Underline")
        case .bulletList: String(localized: "Bulleted List")
        case .numberedList: String(localized: "Numbered List")
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        }
    }

    /// As shown in ⌘K.
    var keys: String {
        switch self {
        case .bold: "⌘B"
        case .italic: "⌘I"
        case .underline: "⌘U"
        case .bulletList: "⇧⌘7"
        case .numberedList: "⇧⌘9"
        }
    }
}

/// A composer body that can take formatting.
@MainActor protocol FormattableEditor: AnyObject {
    func apply(_ format: TextFormat)
}

@MainActor enum TextFormatting {
    /// The composer body you last typed in (menus, the toolbar and ⌘K act on it).
    static weak var active: (any FormattableEditor)?

    static func send(_ format: TextFormat) { active?.apply(format) }

    /// One formatting change: replace `range` with `replacement` (nil: only the typing style
    /// changes), then select `selection` and type with `typing`.
    struct Edit {
        var range: NSRange
        var replacement: NSAttributedString?
        var selection: NSRange
        var typing: [NSAttributedString.Key: Any]
    }

    static func edit(_ format: TextFormat, in text: NSAttributedString, selection: NSRange,
                     typing: [NSAttributedString.Key: Any]) -> Edit {
        switch format {
        case .bold, .italic, .underline: characterEdit(format, in: text, selection: selection, typing: typing)
        case .bulletList: listEdit(.disc, in: text, selection: selection, typing: typing)
        case .numberedList: listEdit(.decimal, in: text, selection: selection, typing: typing)
        }
    }

    // MARK: Bold, italic, underline

    private static func characterEdit(_ format: TextFormat, in text: NSAttributedString, selection: NSRange,
                                      typing: [NSAttributedString.Key: Any]) -> Edit {
        guard selection.length > 0 else {
            // Nothing selected: what you type next.
            var attrs = typing
            let on = !has(format, attributes: attrs)
            set(format, on, attributes: &attrs)
            return Edit(range: selection, replacement: nil, selection: selection, typing: attrs)
        }
        let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: selection))
        let whole = NSRange(location: 0, length: piece.length)
        var allOn = true
        piece.enumerateAttributes(in: whole) { attrs, _, stop in
            if !has(format, attributes: attrs) { allOn = false; stop.pointee = true }
        }
        piece.enumerateAttributes(in: whole) { attrs, range, _ in
            var changed = attrs
            set(format, !allOn, attributes: &changed)
            piece.setAttributes(changed, range: range)
        }
        var after = typing
        set(format, !allOn, attributes: &after)
        return Edit(range: selection, replacement: piece, selection: selection, typing: after)
    }

    private static func has(_ format: TextFormat, attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? PlatformFont ?? RichTextEditor.baseFont
        switch format {
        case .bold: return FontTraits.isBold(font)
        case .italic: return FontTraits.isItalic(font)
        case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .bulletList, .numberedList: return false
        }
    }

    private static func set(_ format: TextFormat, _ on: Bool, attributes: inout [NSAttributedString.Key: Any]) {
        let font = attributes[.font] as? PlatformFont ?? RichTextEditor.baseFont
        switch format {
        case .bold: attributes[.font] = FontTraits.setting(bold: on, on: font)
        case .italic: attributes[.font] = FontTraits.setting(italic: on, on: font)
        case .underline: attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .bulletList, .numberedList: break
        }
    }

    // MARK: Lists

    /// Makes the paragraphs in the selection a list, or takes them out of one when they all are
    /// one of this kind already.
    private static func listEdit(_ marker: NSTextList.MarkerFormat, in text: NSAttributedString, selection: NSRange,
                                 typing: [NSAttributedString.Key: Any]) -> Edit {
        let string = text.string as NSString
        let paragraphs = string.paragraphRange(for: selection)
        let listParagraph = paragraphAttributes(MarkdownShortcuts.attributes(for: .list(marker)))
        let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: paragraphs))

        // An empty last line: start a list there.
        guard piece.length > 0 else {
            let visible = MarkdownShortcuts.visibleMarker(marker)
            var attrs = typing
            attrs.merge(listParagraph) { _, new in new }
            let inserted = NSAttributedString(string: visible, attributes: attrs)
            return Edit(range: paragraphs, replacement: inserted,
                        selection: NSRange(location: paragraphs.location + inserted.length, length: 0), typing: attrs)
        }

        let ranges = paragraphRanges(in: piece.string as NSString)
        let removing = ranges.allSatisfy { listMarker(in: piece, at: $0) == marker }
        var deltas: [Int] = Array(repeating: 0, count: ranges.count)
        for (index, range) in ranges.enumerated().reversed() {
            var length = range.length
            // Take off the marker it has (to remove it, or to swap kinds).
            if listMarker(in: piece, at: range) != nil, let markerLength = visibleMarkerLength(in: piece, paragraph: range) {
                piece.deleteCharacters(in: NSRange(location: range.location, length: markerLength))
                length -= markerLength
                deltas[index] -= markerLength
            }
            let paragraph = NSRange(location: range.location, length: length)
            if removing {
                piece.removeAttribute(.tidingsList, range: paragraph)
                piece.addAttribute(.paragraphStyle, value: baseParagraphStyle, range: paragraph)
            } else {
                let visible = MarkdownShortcuts.visibleMarker(marker, number: index + 1)
                var attrs = RichTextEditor.baseAttributes
                attrs.merge(listParagraph) { _, new in new }
                piece.insert(NSAttributedString(string: visible, attributes: attrs), at: paragraph.location)
                let inserted = (visible as NSString).length
                deltas[index] += inserted
                piece.addAttributes(listParagraph,
                                    range: NSRange(location: paragraph.location, length: length + inserted))
            }
        }
        var after = typing
        if removing {
            after[.tidingsList] = nil
            after[.paragraphStyle] = baseParagraphStyle
        } else {
            after.merge(listParagraph) { _, new in new }
        }
        // The caret keeps its place in the text; markers before it move it along.
        let first = deltas.first ?? 0
        let total = deltas.reduce(0, +)
        let start = max(paragraphs.location, selection.location + first)
        let newSelection = NSRange(location: start, length: max(0, selection.length + total - first))
        return Edit(range: paragraphs, replacement: piece, selection: newSelection, typing: after)
    }

    private static func paragraphRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    /// The length (UTF-16) of the visible list marker that starts the paragraph, if it has one.
    private static func visibleMarkerLength(in text: NSAttributedString, paragraph range: NSRange) -> Int? {
        let paragraph = (text.string as NSString).substring(with: range)
        guard let found = paragraph.range(of: MarkdownShortcuts.visibleMarkerPattern, options: .regularExpression) else { return nil }
        return NSRange(found, in: paragraph).length
    }

    /// The list kind of the paragraph at `range`, if it's in one.
    private static func listMarker(in text: NSAttributedString, at range: NSRange) -> NSTextList.MarkerFormat? {
        guard range.length > 0 else { return nil }
        #if os(macOS)
        return (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first?.markerFormat
        #else
        return (text.attribute(.tidingsList, at: range.location, effectiveRange: nil) as? String).map { $0 == "ol" ? .decimal : .disc }
        #endif
    }

    /// Only the paragraph's own attributes (indent, list kind), so bold and italic survive.
    private static func paragraphAttributes(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        attrs.filter { $0.key == .paragraphStyle || $0.key == .tidingsList }
    }

    private static var baseParagraphStyle: NSParagraphStyle {
        RichTextEditor.baseAttributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
    }
}
