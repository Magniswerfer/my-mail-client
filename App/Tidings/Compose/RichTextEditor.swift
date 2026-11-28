import MailEngine
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks quoted text (reply quotes, "> " paragraphs). Rendered as <blockquote>.
    static let tidingsQuote = NSAttributedString.Key("TidingsQuote")
    /// Marks the signature so switching identity can replace it: on the one character that
    /// shows an HTML signature, its id (a String); on drafts from before, a plain-text block (true).
    static let tidingsSignature = NSAttributedString.Key("TidingsSignature")
    /// "ul"/"ol" on list paragraphs typed on iPhone, where the markers are plain text (the Mac
    /// uses NSTextList, which NSTextView manages itself).
    static let tidingsList = NSAttributedString.Key("TidingsList")
    /// A reply's "On … wrote:" and the quote under it: folded away behind "•••" while you write
    /// (as in Gmail), and sent either way.
    static let tidingsQuotedReply = NSAttributedString.Key("TidingsQuotedReply")
}

/// How the editor's text is saved in a draft. A keyed archive keeps Tidings' own attributes
/// (quote, signature, lists, the folded reply); RTFD, used before, dropped them.
enum EditorArchive {
    static func data(_ text: NSAttributedString) -> Data? {
        // A signature is kept as its id; its picture is drawn again when the draft opens.
        let stripped = NSMutableAttributedString(attributedString: text)
        stripped.enumerateAttribute(.tidingsSignature, in: NSRange(location: 0, length: stripped.length)) { value, range, _ in
            if value is String { stripped.removeAttribute(.attachment, range: range) }
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: stripped, requiringSecureCoding: true)
    }

    static func restore(_ data: Data) -> NSAttributedString? {
        var classes: [AnyClass] = [NSAttributedString.self, NSMutableAttributedString.self, NSString.self, NSNumber.self,
                                   NSURL.self, NSDictionary.self, NSArray.self, NSParagraphStyle.self,
                                   NSMutableParagraphStyle.self, NSTextTab.self, PlatformFont.self, PlatformColor.self]
        classes.append(NSTextList.self)
        if let text = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString { return text }
        // Drafts saved before: RTFD.
        return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }
}

/// Text to put at the caret (e.g. Share Availability). The id makes each insertion happen once.
struct TextInsertion: Equatable {
    let id = UUID()
    let text: String
}

// MARK: - Quote bars

/// Draws the 2pt grey bar beside quoted paragraphs, as the sent mail's <blockquote> shows it.
enum QuoteBars {
    static let width: CGFloat = 2

    /// The bars' rects in the text view's coordinates (`origin`: where the text container starts).
    static func rects(storage: NSAttributedString, layout: NSTextLayoutManager, origin: CGPoint) -> [CGRect] {
        guard let content = layout.textContentManager, storage.length > 0 else { return [] }
        // Only the laid-out part on screen: asking for frames anywhere else would lay out the
        // whole quote (a long forward, say) on every draw, i.e. on every keystroke.
        let viewport = layout.textViewportLayoutController.viewportRange
        var rects: [CGRect] = []
        storage.enumerateAttribute(.tidingsQuote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let quoteRange = NSTextRange(location: start, end: end) else { return }
            let textRange: NSTextRange
            if let viewport {
                guard let visible = quoteRange.intersection(viewport) else { return }
                textRange = visible
            } else {
                textRange = quoteRange
            }
            var block = CGRect.null
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                block = block.union(frame)
                return true
            }
            guard !block.isNull else { return }
            rects.append(CGRect(x: origin.x, y: origin.y + block.minY, width: width, height: block.height))
        }
        return rects
    }

    /// Whether the text has any quoted paragraph (cheap: no layout).
    static func hasQuote(in storage: NSAttributedString) -> Bool {
        var found = false
        storage.enumerateAttribute(.tidingsQuote, in: NSRange(location: 0, length: storage.length),
                                   options: .longestEffectiveRangeNotRequired) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

#if os(macOS)
final class QuoteBarTextView: NSTextView {
    /// The last draw put bars up: they need redrawing (or clearing) as the text changes.
    private var drewBars = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bars = quoteBars()
        drewBars = !bars.isEmpty
        guard drewBars else { return }
        NSColor.tertiaryLabelColor.setFill()
        for bar in bars where bar.intersects(dirtyRect) {
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // The bars move with the text. Without any quote, typing needn't redraw the whole view.
        if drewBars { needsDisplay = true; return }
        if let storage = textStorage, QuoteBars.hasQuote(in: storage) { needsDisplay = true }
    }

    private func quoteBars() -> [CGRect] {
        guard let storage = textStorage else { return [] }
        if let layout = textLayoutManager {
            return QuoteBars.rects(storage: storage, layout: layout, origin: textContainerOrigin)
        }
        // Fell back to TextKit 1 (lists can do that); asking for `layoutManager` before that
        // would itself force the fallback.
        guard let layout = layoutManager, let container = textContainer else { return [] }
        var bars: [CGRect] = []
        storage.enumerateAttribute(.tidingsQuote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let block = layout.boundingRect(forGlyphRange: glyphs, in: container)
            bars.append(CGRect(x: textContainerOrigin.x, y: textContainerOrigin.y + block.minY, width: QuoteBars.width, height: block.height))
        }
        return bars
    }
}
#else
final class QuoteBarTextView: UITextView {
    /// The last draw put bars up: they need redrawing (or clearing) as it scrolls.
    private var drewBars = false

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let layout = textLayoutManager else { drewBars = false; return }
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        let bars = QuoteBars.rects(storage: textStorage, layout: layout, origin: origin)
        drewBars = !bars.isEmpty
        guard drewBars else { return }
        UIColor.tertiaryLabel.setFill()
        for bar in bars where bar.intersects(rect) {
            UIBezierPath(roundedRect: bar, cornerRadius: 1).fill()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Runs on every scroll step: redraw only when there are bars to move or clear.
        if drewBars || QuoteBars.hasQuote(in: textStorage) { setNeedsDisplay() }
    }
}
#endif

// MARK: - Shared styling

extension RichTextEditor {
    /// 14pt on both, the size the sent mail is set in (`MailBodyConverter.html`) and shown at in
    /// Tidings: what you write looks like what they get.
    static let baseFont = PlatformFont.systemFont(ofSize: 14)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: PlatformColor.tidingsLabel]
    }

    static var quoteAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.headIndent = 14
        style.firstLineHeadIndent = 14
        return [.font: baseFont, .foregroundColor: PlatformColor.tidingsSecondaryLabel, .paragraphStyle: style, .tidingsQuote: true]
    }
}

/// The Markdown-style input shortcuts both editors share (SPEC §9).
@MainActor enum MarkdownShortcuts {
    static let inlineRules: [(regex: NSRegularExpression, bold: Bool, markerLength: Int)] = [
        (try! NSRegularExpression(pattern: #"\*\*([^*\n]+?)\*\*"#), true, 2),
        (try! NSRegularExpression(pattern: #"(?<![*\w])\*([^*\n]+?)\*(?![*\w])"#), false, 1),
        (try! NSRegularExpression(pattern: #"(?<![_\w])_([^_\n]+?)_(?![_\w])"#), false, 1),
    ]

    /// Turns completed `**bold**`, `*italic*` and `_italic_` in the paragraph at `caret` into
    /// formatting. Returns the new caret, or nil when nothing changed.
    static func applyInline(in storage: NSTextStorage, caret: Int) -> Int? {
        guard storage.length > 0 else { return nil }
        var paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(caret, storage.length - 1), length: 0))
        var newCaret = caret
        var changed = false
        for rule in inlineRules {
            while let match = rule.regex.firstMatch(in: storage.string, range: paragraph) {
                let inner = match.range(at: 1)
                let innerText = (storage.string as NSString).substring(with: inner)
                var attrs = storage.attributes(at: inner.location, effectiveRange: nil)
                let font = (attrs[.font] as? PlatformFont) ?? RichTextEditor.baseFont
                attrs[.font] = FontTraits.adding(bold: rule.bold, italic: !rule.bold, to: font)
                if !changed { storage.beginEditing(); changed = true }
                storage.replaceCharacters(in: match.range, with: NSAttributedString(string: innerText, attributes: attrs))
                let removed = rule.markerLength * 2
                paragraph.length -= removed
                if newCaret > match.range.location { newCaret = max(match.range.location, newCaret - removed) }
            }
        }
        guard changed else { return nil }
        storage.endEditing()
        return min(newCaret, storage.length)
    }

    enum Block { case list(NSTextList.MarkerFormat), quote }

    /// `- `, `* `, `1. ` or `> ` typed at the start of a paragraph.
    static func block(forPrefix prefix: String) -> Block? {
        switch prefix {
        case "-", "*": .list(.disc)
        case "1.": .list(.decimal)
        case ">": .quote
        default: nil
        }
    }

    static func attributes(for block: Block) -> [NSAttributedString.Key: Any] {
        var attrs = RichTextEditor.baseAttributes
        switch block {
        case .list(let marker):
            let style = NSMutableParagraphStyle()
            #if os(macOS)
            style.textLists = [NSTextList(markerFormat: marker, options: 0)]
            #else
            attrs[.tidingsList] = marker == .decimal ? "ol" : "ul"
            style.tabStops = [NSTextTab(textAlignment: .left, location: 8), NSTextTab(textAlignment: .left, location: 28)]
            #endif
            style.headIndent = 24
            style.firstLineHeadIndent = 4
            attrs[.paragraphStyle] = style
        case .quote:
            attrs.merge(RichTextEditor.quoteAttributes) { _, new in new }
        }
        return attrs
    }

    /// The keys that finish a `;keyword` snippet.
    static let snippetTriggers: Set<String> = [" ", "\t", "\n"]
    /// How far back from the caret a snippet's `;keyword` may start.
    private static let snippetLookBehind = 40

    /// What replaces `;keyword`: the expansion, then the key that finished it (Tab only expands).
    static func insertion(expanding expansion: String, typed trigger: String) -> String {
        expansion + (trigger == "\t" ? "" : trigger)
    }

    /// `;keyword` right before the caret that names a snippet → its range and expanded text.
    static func snippet(in storage: NSTextStorage, caret: Int) -> (NSRange, String)? {
        let string = storage.string as NSString
        guard caret > 1, caret <= string.length else { return nil }
        let start = max(0, caret - snippetLookBehind)
        let before = string.substring(with: NSRange(location: start, length: caret - start))
        guard let semicolon = before.lastIndex(of: ";") else { return nil }
        let keyword = String(before[before.index(after: semicolon)...])
        guard !keyword.isEmpty, keyword.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        // The ; must start a word ("hi;x" isn't a snippet).
        if semicolon > before.startIndex, !before[before.index(before: semicolon)].isWhitespace { return nil }
        guard let snippet = SnippetStore.all.first(where: { $0.keyword == keyword.lowercased() }) else { return nil }
        let length = keyword.utf16.count + 1
        return (NSRange(location: caret - length, length: length), SnippetStore.expand(snippet, context: SnippetContext.current))
    }

    static func visibleMarker(_ marker: NSTextList.MarkerFormat, number: Int = 1) -> String {
        marker == .disc ? "\t•\t" : "\t\(number).\t"
    }

    /// A `visibleMarker` at the start of a paragraph's text.
    nonisolated static let visibleMarkerPattern = #"^\t[^\t]*\t"#

    /// Return on an empty list item or quote line ends the list/quote (Mac). True when handled.
    static func endsBlock(in storage: NSTextStorage, at location: Int) -> Bool {
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        let content = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
        guard storage.length > 0 else { return false }
        let at = min(paragraph.location, storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        let inList = !(style?.textLists.isEmpty ?? true)
        let inQuote = storage.attribute(.tidingsQuote, at: at, effectiveRange: nil) != nil
        guard content.isEmpty, inList || inQuote else { return false }
        storage.setAttributes(RichTextEditor.baseAttributes, range: paragraph)
        return true
    }
}

// MARK: - Mac editor

#if os(macOS)
/// The composer's body (SPEC §9: rich text with Markdown-style input shortcuts).
///
/// An NSTextView, so Writing Tools, spell check, dictation and ⌘B/⌘I come from the system.
/// Typing `- `, `* `, `1. ` or `> ` at the start of a line makes a list or a quote;
/// completed `**bold**`, `*italic*` and `_italic_` turn into formatting (typed or pasted).
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var focusOnAppear = true
    var insertion: TextInsertion? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = Self.makeTextView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = view
        scroll.drawsBackground = false
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        context.coordinator.textView = view
        context.coordinator.lastText = text
        if focusOnAppear {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    /// As NSTextView.scrollableTextView() sets it up, with our subclass (quote bars).
    private static func makeTextView() -> QuoteBarTextView {
        let view = QuoteBarTextView(usingTextLayoutManager: true)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
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
        return view
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, !context.coordinator.isEditing else { return }
        // Every keystroke comes back here as the very text the editor reported: only a text set
        // from elsewhere (signature, unfolded quote) is compared and put in.
        if text !== context.coordinator.lastText {
            context.coordinator.lastText = text
            if view.attributedString() != text {
                // Keep the caret where it was (a signature's picture can arrive while you type).
                let selection = view.selectedRange()
                view.textStorage?.setAttributedString(text)
                let location = min(selection.location, text.length)
                view.setSelectedRange(NSRange(location: location, length: min(selection.length, text.length - location)))
            }
        }
        if let insertion, insertion.id != context.coordinator.lastInsertion {
            context.coordinator.lastInsertion = insertion.id
            // After this update: undoable, and reported through textDidChange like typing.
            DispatchQueue.main.async {
                view.typingAttributes = Self.baseAttributes
                view.insertText(insertion.text, replacementRange: view.selectedRange())
                view.window?.makeFirstResponder(view)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, FormattableEditor {
        var parent: RichTextEditor
        weak var textView: NSTextView? { didSet { if textView != nil { TextFormatting.active = self } } }
        var isEditing = false
        var lastInsertion: UUID?
        /// The text last reported to (or taken from) the binding.
        var lastText: NSAttributedString?

        init(_ parent: RichTextEditor) { self.parent = parent }

        /// The composer you're in gets the Format menu, the toolbar's Format button and ⌘K.
        func textViewDidChangeSelection(_ notification: Notification) {
            TextFormatting.active = self
        }

        func apply(_ format: TextFormat) {
            guard let view = textView, let storage = view.textStorage else { return }
            let edit = TextFormatting.edit(format, in: storage, selection: view.selectedRange(), typing: view.typingAttributes)
            if let replacement = edit.replacement {
                // One undoable change, like typing.
                guard view.shouldChangeText(in: edit.range, replacementString: replacement.string) else { return }
                storage.replaceCharacters(in: edit.range, with: replacement)
                view.didChangeText()
            }
            view.setSelectedRange(edit.selection)
            view.typingAttributes = edit.typing
            view.window?.makeFirstResponder(view)
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView, let storage = view.textStorage, !isEditing else { return }
            isEditing = true
            if let caret = MarkdownShortcuts.applyInline(in: storage, caret: view.selectedRange().location) {
                view.setSelectedRange(NSRange(location: caret, length: 0))
                view.typingAttributes = RichTextEditor.baseAttributes
            }
            let snapshot = view.attributedString().copy() as! NSAttributedString
            lastText = snapshot
            parent.text = snapshot
            isEditing = false
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, let storage = view.textStorage else { return true }
            if MarkdownShortcuts.snippetTriggers.contains(text), range.length == 0,
               expandSnippet(in: view, storage: storage, caret: range.location, typed: text) {
                return false
            }
            switch text {
            case "\n": return !endBlock(in: view, storage: storage, at: range.location)
            case " ": return !startBlock(in: view, storage: storage, caret: range.location)
            default: return true
            }
        }

        private func expandSnippet(in view: NSTextView, storage: NSTextStorage, caret: Int, typed trigger: String) -> Bool {
            guard let found = MarkdownShortcuts.snippet(in: storage, caret: caret) else { return false }
            let (snippetRange, expansion) = found
            view.insertText(MarkdownShortcuts.insertion(expanding: expansion, typed: trigger), replacementRange: snippetRange)
            return true
        }

        private func endBlock(in view: NSTextView, storage: NSTextStorage, at location: Int) -> Bool {
            guard MarkdownShortcuts.endsBlock(in: storage, at: location) else { return false }
            view.typingAttributes = RichTextEditor.baseAttributes
            return true
        }

        /// `- `, `* `, `1. ` or `> ` at the start of a paragraph: it becomes a list or a quote.
        private func startBlock(in view: NSTextView, storage: NSTextStorage, caret: Int) -> Bool {
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: caret, length: 0))
            let prefix = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
            guard let block = MarkdownShortcuts.block(forPrefix: prefix) else { return false }
            replace(prefix: prefix, in: view, at: paragraph.location, attributes: MarkdownShortcuts.attributes(for: block))
            if case .list(let marker) = block {
                // Show the marker right away; NSTextView inserts it on the next newline otherwise.
                view.insertText(MarkdownShortcuts.visibleMarker(marker), replacementRange: NSRange(location: paragraph.location, length: 0))
            }
            return true
        }

        private func replace(prefix: String, in view: NSTextView, at location: Int, attributes attrs: [NSAttributedString.Key: Any]) {
            guard let storage = view.textStorage else { return }
            let prefixRange = NSRange(location: location, length: (prefix as NSString).length)
            view.shouldChangeText(in: prefixRange, replacementString: "")
            storage.replaceCharacters(in: prefixRange, with: "")
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            storage.addAttributes(attrs, range: paragraph)
            view.typingAttributes = attrs
            view.didChangeText()
        }
    }
}
#endif

// MARK: - iPhone editor

#if os(iOS)
/// The composer's body on iPhone: a UITextView with the same shortcuts as the Mac. Bold, italic
/// and underline are in the edit menu; Writing Tools and dictation come from the system.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    var focusOnAppear = true
    var insertion: TextInsertion? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = QuoteBarTextView()
        view.contentMode = .redraw
        view.delegate = context.coordinator
        view.allowsEditingTextAttributes = true
        view.font = Self.baseFont
        view.typingAttributes = Self.baseAttributes
        view.attributedText = text
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.keyboardDismissMode = .interactive
        view.writingToolsBehavior = .complete
        view.dataDetectorTypes = []
        context.coordinator.textView = view
        context.coordinator.lastText = text
        view.inputAccessoryView = context.coordinator.formattingBar()
        if focusOnAppear {
            DispatchQueue.main.async {
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: 0, length: 0)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.isEditing else { return }
        // As on the Mac: the text the editor itself reported isn't copied out and compared again.
        if text !== context.coordinator.lastText {
            context.coordinator.lastText = text
            if view.attributedText != text {
                let selection = view.selectedRange
                view.attributedText = text
                let location = min(selection.location, text.length)
                view.selectedRange = NSRange(location: location, length: min(selection.length, text.length - location))
            }
        }
        if let insertion, insertion.id != context.coordinator.lastInsertion {
            context.coordinator.lastInsertion = insertion.id
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                view.typingAttributes = Self.baseAttributes
                view.insertText(insertion.text)
                coordinator.textViewDidChange(view)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate, FormattableEditor {
        var parent: RichTextEditor
        weak var textView: UITextView?
        var isEditing = false
        var lastInsertion: UUID?
        /// The text last reported to (or taken from) the binding.
        var lastText: NSAttributedString?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textViewDidBeginEditing(_ view: UITextView) {
            TextFormatting.active = self
        }

        func apply(_ format: TextFormat) {
            guard let view = textView else { return }
            let edit = TextFormatting.edit(format, in: view.textStorage, selection: view.selectedRange, typing: view.typingAttributes)
            if let replacement = edit.replacement {
                view.textStorage.beginEditing()
                view.textStorage.replaceCharacters(in: edit.range, with: replacement)
                view.textStorage.endEditing()
            }
            view.selectedRange = edit.selection
            view.typingAttributes = edit.typing
            textViewDidChange(view)
        }

        /// Above the keyboard: Bold, Italic, Underline, the two lists, and hiding the keyboard,
        /// with clear space between the pills and the keyboard.
        func formattingBar() -> UIView {
            // The width is a placeholder: the input accessory is stretched to the keyboard's.
            let width: CGFloat = 320
            let barHeight: CGFloat = 44
            let gapAboveKeyboard: CGFloat = 10
            let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: barHeight + gapAboveKeyboard))
            container.backgroundColor = .clear
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: width, height: barHeight))
            bar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
            container.addSubview(bar)
            func item(_ format: TextFormat) -> UIBarButtonItem {
                let item = UIBarButtonItem(image: UIImage(systemName: format.symbol),
                                           primaryAction: UIAction { [weak self] _ in self?.apply(format) })
                item.accessibilityLabel = format.title
                return item
            }
            let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"),
                                       primaryAction: UIAction { [weak self] _ in self?.textView?.resignFirstResponder() })
            hide.accessibilityLabel = String(localized: "Hide Keyboard")
            bar.items = [item(.bold), item(.italic), item(.underline), .fixedSpace(12), item(.bulletList), item(.numberedList),
                         .flexibleSpace(), hide]
            return container
        }

        func textViewDidChange(_ view: UITextView) {
            guard !isEditing else { return }
            isEditing = true
            if let caret = MarkdownShortcuts.applyInline(in: view.textStorage, caret: view.selectedRange.location) {
                view.selectedRange = NSRange(location: caret, length: 0)
                view.typingAttributes = RichTextEditor.baseAttributes
            }
            let snapshot = view.attributedText.copy() as! NSAttributedString
            lastText = snapshot
            parent.text = snapshot
            isEditing = false
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if MarkdownShortcuts.snippetTriggers.contains(text), range.length == 0,
               expandSnippet(in: view, caret: range.location, typed: text) {
                return false
            }
            switch text {
            case "\n": return !handleReturn(in: view, at: range)
            case " ": return !startBlock(in: view, caret: range.location)
            default: return true
            }
        }

        private func expandSnippet(in view: UITextView, caret: Int, typed trigger: String) -> Bool {
            guard let found = MarkdownShortcuts.snippet(in: view.textStorage, caret: caret) else { return false }
            let (snippetRange, expansion) = found
            let inserted = MarkdownShortcuts.insertion(expanding: expansion, typed: trigger)
            view.textStorage.replaceCharacters(in: snippetRange, with: NSAttributedString(string: inserted, attributes: RichTextEditor.baseAttributes))
            view.selectedRange = NSRange(location: snippetRange.location + (inserted as NSString).length, length: 0)
            textViewDidChange(view)
            return true
        }

        /// Return in a list continues it (or ends it on an empty item); on an empty quote line
        /// it ends the quote. True when handled.
        private func handleReturn(in view: UITextView, at range: NSRange) -> Bool {
            let storage = view.textStorage
            guard storage.length > 0 else { return false }
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let at = min(paragraph.location, storage.length - 1)
            let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            if let list = storage.attribute(.tidingsList, at: at, effectiveRange: nil) as? String {
                let marker = line.range(of: MarkdownShortcuts.visibleMarkerPattern, options: .regularExpression).map { String(line[$0]) } ?? ""
                if line == marker {
                    endList(in: view, paragraph: paragraph, marker: marker)
                } else {
                    continueList(list, in: view, at: range, after: marker)
                }
                textViewDidChange(view)
                return true
            }
            if storage.attribute(.tidingsQuote, at: at, effectiveRange: nil) != nil, line.isEmpty {
                storage.setAttributes(RichTextEditor.baseAttributes, range: paragraph)
                view.typingAttributes = RichTextEditor.baseAttributes
                textViewDidChange(view)
                return true
            }
            return false
        }

        /// Return on an empty item: the item's marker goes, and the list ends there.
        private func endList(in view: UITextView, paragraph: NSRange, marker: String) {
            view.textStorage.replaceCharacters(in: paragraph, with: NSAttributedString(
                string: paragraph.length > (marker as NSString).length ? "\n" : "", attributes: RichTextEditor.baseAttributes))
            view.selectedRange = NSRange(location: paragraph.location, length: 0)
            view.typingAttributes = RichTextEditor.baseAttributes
        }

        /// A new item with the next marker (`list`: "ul" or "ol").
        private func continueList(_ list: String, in view: UITextView, at range: NSRange, after marker: String) {
            let number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: "\t."))) ?? 0
            let format: NSTextList.MarkerFormat = list == "ol" ? .decimal : .disc
            let attrs = MarkdownShortcuts.attributes(for: .list(format))
            let next = "\n" + MarkdownShortcuts.visibleMarker(format, number: number + 1)
            view.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: next, attributes: attrs))
            view.selectedRange = NSRange(location: range.location + (next as NSString).length, length: 0)
            view.typingAttributes = attrs
        }

        /// `- `, `* `, `1. ` or `> ` at the start of a paragraph: it becomes a list (with its
        /// marker as text) or a quote.
        private func startBlock(in view: UITextView, caret: Int) -> Bool {
            let storage = view.textStorage
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: caret, length: 0))
            let prefix = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
            guard let block = MarkdownShortcuts.block(forPrefix: prefix) else { return false }
            let attrs = MarkdownShortcuts.attributes(for: block)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: paragraph.location, length: (prefix as NSString).length), with: "")
            var newCaret = paragraph.location
            if case .list(let marker) = block {
                let visible = MarkdownShortcuts.visibleMarker(marker)
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: 0),
                                          with: NSAttributedString(string: visible, attributes: attrs))
                newCaret += (visible as NSString).length
            }
            let updated = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
            storage.addAttributes(attrs, range: updated)
            storage.endEditing()
            view.selectedRange = NSRange(location: newCaret, length: 0)
            view.typingAttributes = attrs
            textViewDidChange(view)
            return true
        }
    }
}
#endif

// MARK: - Export

/// Turns the editor's attributed text into the two bodies a mail needs.
enum MailBodyConverter {
    /// U+FFFC, the character that stands for an attachment: a picture (the signature's) that
    /// isn't text.
    private static let attachmentCharacter = "\u{FFFC}"

    /// The signature (its id) a paragraph holds, if any.
    static func signatureID(in text: NSAttributedString, paragraph range: NSRange) -> String? {
        var id: String?
        text.enumerateAttribute(.tidingsSignature, in: range) { value, _, stop in
            if let value = value as? String { id = value; stop.pointee = true }
        }
        return id
    }

    /// `signatures`: by id, for the signature in the text (its text version goes there).
    static func plainText(_ text: NSAttributedString, signatures: [String: Signature] = [:]) -> String {
        var lines: [String] = []
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let id = signatureID(in: text, paragraph: range) {
                // The signature's own line; anything typed beside it stays.
                let rest = string.substring(with: range).replacingOccurrences(of: attachmentCharacter, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { lines.append(rest) }
                if let signature = signatures[id] { lines.append(signature.textBlock) }
                location = NSMaxRange(range)
                continue
            }
            var line = plainLine(text.attributedSubstring(from: range))
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            // The visible list marker ("\t•\t", "\t1.\t") as "• " / "1. ", flush left.
            if let marker = line.range(of: #"^\t[^\t]*\t"#, options: .regularExpression) {
                line.replaceSubrange(marker, with: line[marker].trimmingCharacters(in: .whitespaces) + " ")
            }
            line = line.replacingOccurrences(of: "\t", with: " ")
            if attrs[.tidingsQuote] != nil { line = "> " + line }
            lines.append(line)
            location = NSMaxRange(range)
        }
        return lines.joined(separator: "\n")
    }

    /// A paragraph's text with each link's address written out where its text doesn't say it
    /// ("the agenda <https://…>"): the plain-text part has no other way to carry it.
    static func plainLine(_ paragraph: NSAttributedString) -> String {
        var line = ""
        paragraph.enumerateAttribute(.link, in: NSRange(location: 0, length: paragraph.length)) { link, range, _ in
            let piece = (paragraph.string as NSString).substring(with: range)
            let href = (link as? URL)?.absoluteString ?? (link as? String)
            line += href.map { OutgoingHTML.plainTextLink(text: piece, href: $0) } ?? piece
        }
        return line.trimmingCharacters(in: .newlines).replacingOccurrences(of: attachmentCharacter, with: "")
    }

    /// Clean, inline-styled HTML: <p>, <ul>/<ol>, <blockquote>, <b>/<i>/<u>/<s>, links.
    /// `signatures`: by id, for the signature in the text (its HTML goes there, as a block).
    static func html(_ text: NSAttributedString, signatures: [String: Signature] = [:]) -> String {
        var html = ""
        var openList: String?
        var inQuote = false
        let string = text.string as NSString
        var location = 0

        func closeBlocks(list: String?, quote: Bool) {
            if let open = openList, open != list { html += "</\(open)>"; openList = nil }
            if inQuote, !quote { html += "</blockquote>"; inQuote = false }
        }

        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let id = signatureID(in: text, paragraph: range) {
                closeBlocks(list: nil, quote: false)
                let rest = inlineHTML(text.attributedSubstring(from: range))
                if !rest.isEmpty { html += "<p style=\"margin:0\">\(rest)</p>" }
                if let signature = signatures[id] { html += signature.htmlBlock }
                location = NSMaxRange(range)
                continue
            }
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let list = style?.textLists.first.map { $0.markerFormat == .decimal ? "ol" : "ul" } ?? (attrs[.tidingsList] as? String)
            let quote = attrs[.tidingsQuote] != nil
            closeBlocks(list: list, quote: quote)
            // As the editor shows them: a 2pt bar and grey text 14pt in; lists 24pt in; no gaps
            // between paragraphs but the blank lines you typed.
            if quote, !inQuote { html += "<blockquote type=\"cite\" style=\"margin:0;border-left:2px solid #c7c7cc;padding-left:12px;color:#6e6e73\">"; inQuote = true }
            if let list, openList == nil { html += "<\(list) style=\"margin:0;padding-left:24px\">"; openList = list }

            var content = text.attributedSubstring(from: range)
            // Drop the visible list marker we inserted ("\t•\t", "\t1.\t").
            if list != nil, let markerEnd = content.string.range(of: MarkdownShortcuts.visibleMarkerPattern, options: .regularExpression) {
                let length = content.string.distance(from: content.string.startIndex, to: markerEnd.upperBound)
                content = content.attributedSubstring(from: NSRange(location: length, length: content.length - length))
            }
            let inner = inlineHTML(content)
            if list != nil {
                html += "<li>\(inner)</li>"
            } else {
                html += "<p style=\"margin:0\">\(inner.isEmpty ? "<br>" : inner)</p>"
            }
            location = NSMaxRange(range)
        }
        closeBlocks(list: nil, quote: false)
        // 14px, the size the editor sets it in (`RichTextEditor.baseFont`).
        return OutgoingHTML.document(html, fontSize: 14)
    }

    static func inlineHTML(_ text: NSAttributedString) -> String {
        var out = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let raw = (text.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
                .replacingOccurrences(of: attachmentCharacter, with: "")
            guard !raw.isEmpty else { return }
            // Spaces HTML would collapse (several in a row, indents) stay as typed.
            var piece = OutgoingHTML.text(raw, leadingEdge: range.location == 0,
                                          trailingEdge: NSMaxRange(range) >= text.length - 1)
            if let font = attrs[.font] as? PlatformFont {
                if FontTraits.isBold(font) { piece = "<b>\(piece)</b>" }
                if FontTraits.isItalic(font) { piece = "<i>\(piece)</i>" }
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
