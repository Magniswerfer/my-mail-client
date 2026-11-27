import MailEngine
import SwiftUI
import WebKit

/// The reading pane: a conversation stacked oldest→newest; older messages collapsed.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let threadID: String?

    var body: some View {
        if let threadID {
            let _ = model.revision   // redraw after moves, flag changes and syncs
            let messages = model.readerMessages(inThread: threadID)
            let reactions = model.reactions(on: messages)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let first = messages.last {
                        Text(first.subject)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                        CategoryLine(message: first)
                        if model.isMuted(threadID) {
                            HStack(spacing: 6) {
                                Label("Muted: new replies skip the Inbox", systemImage: "bell.slash")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Unmute") { model.unmute(threadID: threadID) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if let latest = messages.last, let highlights = latest.highlights, !highlights.isEmpty {
                            HighlightCards(highlights: highlights, message: latest)
                        }
                        SummaryLine(threadID: threadID, messageCount: messages.count)
                        if let risky = messages.last(where: { $0.riskLevel > .none }) {
                            RiskBanner(message: risky)
                        }
                        JunkBanner(threadID: threadID, messages: messages)
                        if let found = model.invite(inThread: threadID) {
                            InviteCard(message: found.message, invite: found.invite)
                        }
                        DateSuggestionSlot(threadID: threadID)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        // iPhone: no card round each message, just a line between them.
                        if Platform.isPhone, index > 0 { Divider().padding(.vertical, 4) }
                        MessageCard(message: message, startsExpanded: index == messages.count - 1 || message.isUnread,
                                    reactions: message.id.flatMap { reactions[$0] } ?? [])
                    }
                }
                // iPhone: Mail's own reading margins.
                .padding(.horizontal, Platform.isPhone ? 24 : 20)
                .padding(.vertical, Platform.isPhone ? 16 : 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(threadID)
            .dateSuggestions(threadID: threadID, model: model)
        } else {
            ContentUnavailableView("No conversation selected", systemImage: "envelope.open",
                                   description: Text("Use j and k to move through your mail."))
        }
    }
}

/// Mac: the small capsule of actions on a hovered message, as in Mail. Each acts on this message.
struct MessageRibbon: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage

    var body: some View {
        HStack(spacing: 2) {
            button("Reply", "arrowshape.turn.up.left") { model.compose(.reply, replyingTo: message) }
            button("Reply All", "arrowshape.turn.up.left.2") { model.compose(.replyAll, replyingTo: message) }
            button("Forward", "arrowshape.turn.up.right") { model.compose(.forward, replyingTo: message) }
            if model.canReact(to: message) {
                Divider().frame(height: 14).padding(.horizontal, 2)
                let liked = model.myReaction(to: message) == "👍"
                button(liked ? "Remove Like" : "Like", liked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    model.toggleReaction("👍", to: message)
                }
                ReactionMenu(message: message) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

/// The likes on a message, grouped by emoji ("👍 2"); yours stands out. Clicking one gives
/// that reaction too, or takes yours back.
struct ReactionRow: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    let reactions: [MailReaction]

    var body: some View {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .sorted { ($0.value.map(\.date).min() ?? .distantPast) < ($1.value.map(\.date).min() ?? .distantPast) }
        HStack(spacing: 6) {
            ForEach(groups, id: \.key) { emoji, people in
                let mine = people.contains(where: \.isMine)
                Button { model.toggleReaction(emoji, to: message) } label: {
                    HStack(spacing: 4) {
                        Text(emoji)
                        if people.count > 1 { Text("\(people.count)").monospacedDigit() }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(mine ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary), in: .capsule)
                    .overlay { if mine { Capsule().strokeBorder(.tint.opacity(0.5)) } }
                }
                .buttonStyle(.plain)
                // On your own mail the chips only show who reacted.
                .allowsHitTesting(model.canReact(to: message))
                .help(Text(people.map(\.fromName).joined(separator: ", ")))
                .accessibilityLabel(Text("\(emoji) from \(people.map(\.fromName).joined(separator: ", "))"))
            }
            if Platform.isPhone, model.canReact(to: message) {
                ReactionMenu(message: message) {
                    Image(systemName: "face.smiling")
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: .capsule)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Outlook's six reactions, to pick one.
struct ReactionMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(AppModel.reactionChoices, id: \.self) { emoji in
                Button { model.toggleReaction(emoji, to: message) } label: {
                    Text(model.myReaction(to: message) == emoji ? "\(emoji) ✓" : emoji)
                }
            }
        } label: { label() }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("React")
    }
}

struct MessageCard: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    @State var expanded: Bool
    @State private var body_: LoadedBody?
    @State private var loadError: String?
    @State private var showImages = false
    /// Dark mode: show this message's own colours instead of recolouring it.
    @State private var originalColors = false
    @State private var readerMode = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    /// Reactions on this message (likes from Outlook, Gmail and Tidings).
    var reactions: [MailReaction] = []

    init(message: StoredMessage, startsExpanded: Bool, reactions: [MailReaction] = []) {
        self.message = message
        self.reactions = reactions
        _expanded = State(initialValue: startsExpanded)
    }

    struct LoadedBody {
        var html: PreparedHTML?
        var text: String
        var attachments: [AttachmentInfo]
        var to: String
        var inline: [String: (data: Data, mimeType: String)]
        /// Parsed from the raw message, for mail synced before invites were stored.
        var invite: CalendarInvite?
        /// How to leave their list: the List-Unsubscribe header, else the body's "Unsubscribe" link.
        var unsubscribe: UnsubscribeMethod?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            if expanded {
                // Mac, as in Mail: a line under the header, and on hover a ribbon on it to
                // answer this message (not just the conversation's newest).
                if !Platform.isPhone {
                    Divider()
                        .overlay {
                            if isHovered { MessageRibbon(message: message).transition(.opacity) }
                        }
                        .zIndex(1)
                }
                content
            }
            // Likes under the message; on the iPhone also the button to add one (the Mac has
            // it in the hover ribbon).
            if !reactions.isEmpty || (Platform.isPhone && expanded && model.canReact(to: message)) {
                ReactionRow(message: message, reactions: reactions)
            }
        }
        // On the Mac each message is a card; the iPhone has no room to spare for one.
        .padding(Platform.isPhone ? 0 : 14)
        .background {
            if !Platform.isPhone { RoundedRectangle(cornerRadius: 14).fill(.background.secondary) }
        }
        .overlay(alignment: .bottom) {
            // A folded message has no line: the ribbon sits on its bottom edge.
            if !Platform.isPhone, !expanded, isHovered {
                MessageRibbon(message: message).offset(y: 14).transition(.opacity)
            }
        }
        .zIndex(isHovered ? 1 : 0)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { isHovered = inside } }
        .task(id: expanded) {
            guard expanded, body_ == nil else { return }
            await load()
        }
    }

    @ViewBuilder private var header: some View {
        if Platform.isPhone { phoneHeader } else { macHeader }
    }

    /// "Unsubscribe" beside the sender when their mail says how (Gmail-style); "Unsubscribed"
    /// once you have. It still asks first.
    @ViewBuilder private var unsubscribeButton: some View {
        if let method = body_?.unsubscribe {
            if let when = try? model.store.unsubscribedAt(address: message.fromAddress) {
                Text("Unsubscribed")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(Text("You unsubscribed on \(MailDate.long(when))"))
            } else {
                Button("Unsubscribe") { model.requestUnsubscribe(message: message, method: method) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Stop getting mail from \(message.senderDisplay). Asks first.")
            }
        }
    }

    private func avatar(size: CGFloat) -> some View {
        Button { model.showContact(message.fromAddress) } label: {
            Avatar(name: message.senderDisplay, size: size)
        }
        .buttonStyle(.plain)
        .help("About \(message.senderDisplay)")
    }

    /// iPhone: name and date on one line, then the address and who it went to, each on a line of
    /// its own and never wrapping, so nothing ends up squeezed into a column.
    private var phoneHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.senderDisplay).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(expanded ? MailDate.long(message.date) : MailDate.short(message.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if expanded {
                    if message.senderDisplay != message.fromAddress {
                        Text(message.fromAddress)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let to = body_?.to, !to.isEmpty {
                        Text("To: \(to)").lineLimit(1)
                    }
                    unsubscribeButton
                } else {
                    Text(message.preview).font(.subheadline).lineLimit(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var macHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                // One line when the reader is wide enough; else name and date, then the address
                // under them (never squeezed into a column).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message.senderDisplay).font(.headline)
                        if expanded {
                            Text(message.fromAddress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            unsubscribeButton
                        }
                        Spacer(minLength: 12)
                        Text(MailDate.long(message.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.senderDisplay).font(.headline).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(expanded ? MailDate.long(message.date) : MailDate.short(message.date))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                        }
                        if expanded {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(message.fromAddress).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                unsubscribeButton
                            }
                        }
                    }
                }
                if expanded, let to = body_?.to, !to.isEmpty {
                    Text("To: \(to)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !expanded {
                    Text(message.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let reply = message.invite ?? body_?.invite, reply.method == .reply {
            InviteReplyLine(invite: reply)
        } else if message.invite == nil, let invite = body_?.invite {
            InviteCard(message: message, invite: invite)
        }
        if let loaded = body_ {
            if loaded.html != nil, readerMode || model.readerMode {
                Button("Original Layout", systemImage: "doc.richtext") { readerMode = false }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                ReaderModeText(text: loaded.text)
            } else if let html = loaded.html {
                Button("Reader Mode", systemImage: "book") { readerMode = true }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .help("Clean text for reading")
                PrivacyBar(prepared: html, imagesShown: showImages, sender: message.fromAddress,
                           loadImages: { showImages = true },
                           alwaysLoad: { scope in
                               model.trustImages(from: scope)
                               showImages = true
                           })
                let darken = colorScheme == .dark && !originalColors && HTMLDarkMode.canDarken(html.html)
                MessageWebView(html: html.html, allowRemoteImages: showImages, inlineParts: loaded.inline, dark: darken)
                    .id("\(showImages)-\(darken)")   // rebuild with the new policy
                    // iPhone: the page keeps a 12pt margin (for mail with its own background);
                    // pulled out by as much, its text lines up with the screen's margin.
                    .padding(.horizontal, Platform.isPhone ? -12 : 0)
                if colorScheme == .dark, HTMLDarkMode.canDarken(html.html) {
                    Button(originalColors ? "Match Dark Mode" : "Original Colours",
                           systemImage: "circle.lefthalf.filled") { originalColors.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(loaded.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let files = loaded.attachments.filter { !$0.isInline }
            if !files.isEmpty {
                HStack {
                    ForEach(files, id: \.self) { a in
                        Button { model.preview(a, in: message) } label: {
                            HStack(spacing: 6) {
                                FileIcon(info: a).frame(width: 16, height: 16)
                                Text(a.filename ?? a.mimeType).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .help("Quick Look")
                        .contextMenu {
                            Button("Quick Look", systemImage: "eye") { model.preview(a, in: message) }
                            Button("Open", systemImage: "arrow.up.forward.app") { model.openAttachment(a, in: message) }
                            #if os(macOS)
                            Button("Save…", systemImage: "square.and.arrow.down") { model.saveAttachment(a, in: message) }
                            #endif
                        }
                    }
                }
            }
        } else if let loadError {
            Label(loadError, systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Text(message.plainText ?? message.preview).textSelection(.enabled)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func load() async {
        // Read Later opens in reader mode.
        if message.flags.contains(readLaterKeyword) { readerMode = true }
        do {
            let raw = try await model.rawMessage(message)
            let parsed = MIMEParser.parse(raw)
            if message.attachmentList == nil, let id = message.id {
                try? model.store.setAttachmentList(parsed.attachments, messageID: id)
            }
            showImages = model.allowsRemoteImages(from: message.fromAddress)
            body_ = LoadedBody(
                html: parsed.html.map(RemoteContent.prepare), text: parsed.plainText, attachments: parsed.attachments,
                to: (parsed.to + parsed.cc).map(\.description).joined(separator: ", "),
                inline: MIMEParser.inlineParts(in: raw),
                invite: parsed.invite,
                unsubscribe: Unsubscribe.methods(in: parsed).first
            )
        } catch {
            loadError = String(localized: "Couldn't load the full message. Showing the stored text.")
        }
    }
}

/// "🛡 3 trackers removed · 2 images hidden · Load images · Always from …" (SPEC §8).
struct PrivacyBar: View {
    let prepared: PreparedHTML
    let imagesShown: Bool
    let sender: String
    let loadImages: () -> Void
    let alwaysLoad: (String) -> Void

    var body: some View {
        let hidden = imagesShown ? 0 : prepared.remoteImages
        if prepared.trackersRemoved > 0 || hidden > 0 || prepared.linksCleaned > 0 {
            if Platform.isPhone {
                phone(hidden: hidden)
            } else {
                // The one-line capsule when it fits; in a narrow reader, the iPhone's compact form.
                ViewThatFits(in: .horizontal) {
                    regular(hidden: hidden)
                    phone(hidden: hidden)
                }
            }
        }
    }

    /// iPhone: one quiet line of what was done, and one menu for loading images.
    private func phone(hidden: Int) -> some View {
        var parts: [String] = []
        if prepared.trackersRemoved > 0 { parts.append(String(localized: "\(prepared.trackersRemoved) trackers removed")) }
        if prepared.linksCleaned > 0 { parts.append(String(localized: "\(prepared.linksCleaned) links cleaned")) }
        if hidden > 0 { parts.append(String(localized: "\(hidden) images hidden")) }
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.teal)
            Text(parts.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hidden > 0 {
                Menu {
                    Button("Load images", systemImage: "photo", action: loadImages)
                    Button("Always from \(sender)") { alwaysLoad(sender) }
                    if let domain = sender.split(separator: "@").last {
                        Button("Always from @\(domain)") { alwaysLoad("@\(domain)") }
                    }
                } label: {
                    Text("Load images").fontWeight(.medium).lineLimit(1)
                }
                .fixedSize()
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func regular(hidden: Int) -> some View {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.teal)
                if prepared.trackersRemoved > 0 {
                    Text("\(prepared.trackersRemoved) trackers removed")
                }
                if prepared.linksCleaned > 0 {
                    Text("\(prepared.linksCleaned) links cleaned").foregroundStyle(.secondary)
                }
                if hidden > 0 {
                    Text("\(hidden) images hidden").foregroundStyle(.secondary)
                    Spacer()
                    Button("Load images", action: loadImages).buttonStyle(.borderless)
                    Menu("Always") {
                        Button("Always from \(sender)") { alwaysLoad(sender) }
                        if let domain = sender.split(separator: "@").last {
                            Button("Always from @\(domain)") { alwaysLoad("@\(domain)") }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                } else {
                    Spacer()
                }
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .help("Tracking pixels are always removed. Images from people you haven't written to stay hidden until you allow them.")
    }
}

#if os(macOS)
/// The message is laid out at its full height inside the reader's scroll view and never scrolls
/// itself, but a web view still swallows scroll-wheel events: hand them to the reader, or the
/// conversation won't scroll while the pointer is over a message body.
final class PassthroughScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
#endif

/// HTML mail in a locked-down web view: no JavaScript, links open in the browser, height follows
/// content. Remote loads are blocked except images when allowed (SPEC §8); `cid:` parts are
/// served from the message itself.
@MainActor struct MessageWebView {
    let html: String
    var allowRemoteImages = false
    var inlineParts: [String: (data: Data, mimeType: String)] = [:]
    /// Recolour for dark mode (only for mail without its own background colours).
    var dark = false
    @State private var height: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(CIDSchemeHandler(parts: inlineParts), forURLScheme: "cid")
        #if os(iOS)
        config.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        #endif
        #if os(macOS)
        let view = PassthroughScrollWebView(frame: .zero, configuration: config)
        #else
        let view = WKWebView(frame: .zero, configuration: config)
        #endif
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        // The reader scrolls; the message grows to its full height inside it.
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        #endif
        let page = Self.wrap(html, allowRemoteImages: allowRemoteImages, dark: dark)
        Coordinator.withRuleList(allowImages: allowRemoteImages) { list in
            if let list { view.configuration.userContentController.add(list) }
            view.loadHTMLString(page, baseURL: nil)
        }
        return view
    }

    static func wrap(_ html: String, allowRemoteImages: Bool, dark: Bool = false) -> String {
        let images = allowRemoteImages ? "data: cid: https: http:" : "data: cid:"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src data:">
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; padding: 12px; background: white; color: #1d1d1f;
                       font: 14px -apple-system, system-ui, sans-serif; overflow-wrap: anywhere; border-radius: 10px; }
          \(Platform.isPhone ? "html { padding: 0; }" : "")
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
        </style></head><body>\(html)\(dark ? "<style>\(HTMLDarkMode.darkCSS)</style>" : "")</body></html>
        """
    }

    /// Serves `cid:` URLs from the message's own parts.
    final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
        let parts: [String: (data: Data, mimeType: String)]
        init(parts: [String: (data: Data, mimeType: String)]) { self.parts = parts }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let id = task.request.url.map { String($0.absoluteString.dropFirst("cid:".count)) }?.removingPercentEncoding ?? ""
            guard let url = task.request.url, let part = parts[id] else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: part.mimeType, expectedContentLength: part.data.count, textEncodingName: nil))
            task.didReceive(part.data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        static var cached: [Bool: WKContentRuleList] = [:]

        /// Blocks every http(s) subresource, except images when they're allowed. The CSP does the
        /// same; this is belt and braces.
        static func withRuleList(allowImages: Bool, _ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
            if let list = cached[allowImages] { body(list); return }
            var types = ["style-sheet", "font", "media", "raw", "svg-document", "script", "fetch", "websocket", "other"]
            if !allowImages { types.append("image") }
            let rules = #"[{"trigger":{"url-filter":"^https?://","resource-type":["# + types.map { "\"\($0)\"" }.joined(separator: ",") + #"]},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: allowImages ? "tidings-block-remote-allow-images" : "tidings-block-remote",
                encodedContentRuleList: rules
            ) { list, _ in
                MainActor.assumeIsolated {
                    cached[allowImages] = list
                    body(list)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                Platform.openExternally(url)
                return .cancel
            }
            return action.request.url?.scheme == "about" || action.navigationType == .other ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let result = try? await webView.callAsyncJavaScript(Self.fitToWidth, contentWorld: .defaultClient)
                if let h = result as? Double { height.wrappedValue = max(60, CGFloat(h)) }
            }
        }

        /// Mail built for a fixed width (often 600px tables) is scaled down to fit the reader, as
        /// Mail does on iPhone, instead of being cut off at the right. Returns the height to show.
        /// Runs in our own world: the message's scripts stay off.
        static let fitToWidth = """
            const root = document.documentElement, body = document.body;
            body.style.transform = ''; body.style.width = '';
            const style = getComputedStyle(root);
            const inset = (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0);
            const available = root.clientWidth - inset, needed = root.scrollWidth - inset;
            if (needed > available + 2) {
                // The body as wide as what's in it, so its background covers all of it, then shrunk.
                body.style.boxSizing = 'border-box';
                body.style.width = needed + 'px';
                body.style.transformOrigin = '0 0';
                body.style.transform = 'scale(' + (available / needed) + ')';
                root.style.overflowX = 'hidden';
            }
            const below = parseFloat(getComputedStyle(root).paddingBottom) || 0;
            return Math.ceil(body.getBoundingClientRect().bottom + below);
            """
    }
}

#if os(macOS)
extension MessageWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }
}
#else
extension MessageWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 375, height: height)
    }
}
#endif

/// "Primær · From a person ▾": why the conversation is here, and the place to correct it.
struct CategoryLine: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage

    var body: some View {
        Menu {
            if let thread = model.threads.first(where: { $0.threadID == message.threadID }) ?? model.targetThreads.first {
                MoveMenuContent(thread: thread)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: message.category.symbol).accessibilityHidden(true)
                Text(message.category.title).fontWeight(.medium).layoutPriority(1)
                // The reason truncates: unwrapped, it made the whole reader wider than an iPhone.
                Text("· \(message.reasonText ?? "")").foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Move to another category")
            .font(.caption)
            .foregroundStyle(message.category.tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Why it's here. Click to move it (M).")
    }
}

/// Somewhere a conversation can be moved: a built-in category or one of yours.
enum CategoryTarget: Hashable, Identifiable {
    case builtIn(MailCategory)
    case custom(AICategory)

    var id: String {
        switch self {
        case .builtIn(let c): "c.\(c.rawValue)"
        case .custom(let c): "ai.\(c.id)"
        }
    }

    var title: String {
        switch self {
        case .builtIn(let c): c.title
        case .custom(let c): c.name
        }
    }

    var symbol: String {
        switch self {
        case .builtIn(let c): c.symbol
        case .custom(let c): c.symbol
        }
    }

    var tint: Color {
        switch self {
        case .builtIn(let c): c.tint
        case .custom: .indigo
        }
    }
}

extension AppModel {
    /// The built-in categories, then yours, in tab order.
    var categoryTargets: [CategoryTarget] {
        MailCategory.allCases.map(CategoryTarget.builtIn) + aiCategories.map(CategoryTarget.custom)
    }

    /// Whether these conversations are all there already.
    func isCurrent(_ target: CategoryTarget, for threads: [ThreadSummary]) -> Bool {
        switch target {
        case .builtIn(let c): !threads.isEmpty && threads.allSatisfy { $0.latest.category == c }
        case .custom(let c): allIn(aiCategory: c.id, threads)
        }
    }

    func move(_ threads: [ThreadSummary], to target: CategoryTarget) {
        switch target {
        case .builtIn(let c): moveConversations(threads, to: c)
        case .custom(let c): moveConversations(threads, toAICategory: c.id)
        }
    }

    func moveSender(of thread: ThreadSummary? = nil, to target: CategoryTarget) {
        switch target {
        case .builtIn(let c): moveSender(to: c, thread: thread)
        case .custom(let c): moveSender(toAICategory: c.id, thread: thread)
        }
    }
}

/// M: move the selected conversation to a category. Type to filter, ↑↓ to choose, Return to
/// move it, ⌘Return to move it and the sender's mail from now on. 1–9 pick directly.
struct CategoryPicker: View {
    @Environment(AppModel.self) private var model
    @State private var alwaysForSender = false
    @State private var query = ""
    @State private var highlighted: CategoryTarget?
    @FocusState private var focused: Bool

    var body: some View {
        let threads = model.targetThreads
        let thread = threads.first
        let all = model.categoryTargets
        let matches = filtered(all)
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Move to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { moveHighlighted(matches, always: alwaysForSender) }
                    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                        guard let n = Int(press.characters), n >= 1, n <= all.count else { return .ignored }
                        move(to: all[n - 1], always: alwaysForSender)
                        return .handled
                    }
            }
            #else
            Text("Move to…").font(.headline)
            #endif
            if matches.isEmpty {
                Text("No category matches “\(query)”").foregroundStyle(.secondary).padding(.vertical, 5)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(matches) { target in
                            row(target, number: all.firstIndex(of: target).map { $0 + 1 },
                                isCurrent: model.isCurrent(target, for: threads),
                                isHighlighted: target == current(matches))
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $alwaysForSender) {
                HStack {
                    Text("Always for \(thread?.latest.senderDisplay ?? "this sender")")
                    #if os(macOS)
                    Spacer()
                    Text("⌘↩").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    #endif
                }
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            Text(alwaysForSender
                 ? "Their existing and future mail moves too."
                 : "Tidings learns from this. Move the same sender twice and it becomes a rule.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.isCategoryPickerShown = false }.keyboardShortcut(.cancelAction)
                // ⌘Return: always for the sender, whatever the box says.
                Button("Always") { moveHighlighted(matches, always: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .hidden().frame(width: 0)
            }
        }
        .padding(20)
        .macFrame(width: 360)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = nil }
        .onKeyPress(.downArrow) { step(1, in: matches); return .handled }
        .onKeyPress(.upArrow) { step(-1, in: matches); return .handled }
    }

    private func row(_ target: CategoryTarget, number: Int?, isCurrent: Bool, isHighlighted: Bool) -> some View {
        let disabled = isCurrent && !alwaysForSender
        return Button { move(to: target, always: alwaysForSender) } label: {
            HStack {
                Image(systemName: target.symbol).foregroundStyle(target.tint).frame(width: 22)
                Text(target.title)
                if isCurrent {
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let number, number <= 9 {
                    Text("\(number)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(isHighlighted ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// The other categories, or the ones whose name has every typed word.
    private func filtered(_ all: [CategoryTarget]) -> [CategoryTarget] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { target in words.allSatisfy { target.title.localizedStandardContains($0) } }
    }

    /// What Return moves to: the one you arrowed to, else the first that isn't where it is now.
    private func current(_ matches: [CategoryTarget]) -> CategoryTarget? {
        if let highlighted, matches.contains(highlighted) { return highlighted }
        return matches.first { !model.isCurrent($0, for: model.targetThreads) } ?? matches.first
    }

    private func step(_ delta: Int, in matches: [CategoryTarget]) {
        guard !matches.isEmpty else { return }
        let index = current(matches).flatMap(matches.firstIndex) ?? 0
        highlighted = matches[min(max(index + delta, 0), matches.count - 1)]
    }

    private func moveHighlighted(_ matches: [CategoryTarget], always: Bool) {
        guard let target = current(matches) else { return }
        move(to: target, always: always)
    }

    private func move(to target: CategoryTarget, always: Bool) {
        if always {
            model.moveSender(to: target)
        } else {
            guard !model.isCurrent(target, for: model.targetThreads) else { return }
            model.move(model.targetThreads, to: target)
        }
    }
}

/// A phishing/spoofing warning with its reasons (SPEC §8). Nothing is moved automatically.
struct RiskBanner: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage

    var body: some View {
        let danger = message.riskLevel == .danger
        VStack(alignment: .leading, spacing: 8) {
            Label(danger ? "This looks like a phishing attempt" : "Be careful with this message",
                  systemImage: danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(danger ? .red : .orange)
            ForEach(RiskAssessment.decode(message.riskReasons), id: \.self) { reason in
                Label(reason.localized, systemImage: "circle.fill")
                    .labelStyle(BulletLabelStyle())
                    .font(Platform.isPhone ? .subheadline : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Platform.isPhone {
                // iPhone: the advice on its own line, then the buttons, each kept to one line.
                advice
                HStack(spacing: 10) {
                    junkButton(danger: danger)
                    safeButton
                }
                .controlSize(.regular)
                .padding(.top, 4)
            } else {
                HStack {
                    junkButton(danger: danger)
                    safeButton
                    Spacer()
                    advice
                }
            }
        }
        .padding(Platform.isPhone ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((danger ? Color.red : Color.orange).opacity(0.08), in: .rect(cornerRadius: Platform.isPhone ? 20 : 14))
        .overlay(RoundedRectangle(cornerRadius: Platform.isPhone ? 20 : 14)
            .strokeBorder((danger ? Color.red : Color.orange).opacity(Platform.isPhone ? 0.25 : 0.4)))
    }

    private var advice: some View {
        Text("Don't click links or open attachments unless you're sure.")
            .font(Platform.isPhone ? .footnote : .caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func junkButton(danger: Bool) -> some View {
        Button("Move to Junk", systemImage: "xmark.bin") {
            if let thread = model.threads.first(where: { $0.threadID == message.threadID }) {
                model.perform(.junk, on: [thread])
            }
        }
        .buttonStyle(.glassProminent)
        .tint(danger ? .red : .orange)
        .lineLimit(1)
        .fixedSize()
    }

    private var safeButton: some View {
        Button("It's safe") { model.markSafe(message) }
            .buttonStyle(.glass)
            .lineLimit(1)
            .fixedSize()
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            configuration.title
        }
    }
}
