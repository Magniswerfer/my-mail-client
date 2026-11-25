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
            let messages = model.messages(inThread: threadID)
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
                        if let found = model.invite(inThread: threadID) {
                            InviteCard(message: found.message, invite: found.invite)
                        }
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageCard(message: message, startsExpanded: index == messages.count - 1 || message.isUnread)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(threadID)
        } else {
            ContentUnavailableView("No conversation selected", systemImage: "envelope.open",
                                   description: Text("Use j and k to move through your mail."))
        }
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
    @Environment(\.colorScheme) private var colorScheme

    init(message: StoredMessage, startsExpanded: Bool) {
        self.message = message
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            if expanded {
                content
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .task(id: expanded) {
            guard expanded, body_ == nil else { return }
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.showContact(message.fromAddress) } label: {
                Avatar(name: message.senderDisplay, size: 34)
            }
            .buttonStyle(.plain)
            .help("About \(message.senderDisplay)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.senderDisplay).font(.headline)
                    if expanded {
                        Text(message.fromAddress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(MailDate.long(message.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            if loaded.html != nil, readerMode {
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
                invite: parsed.invite
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
                let result = try? await webView.callAsyncJavaScript(
                    "return document.documentElement.scrollHeight", contentWorld: .defaultClient)
                if let h = result as? Double { height.wrappedValue = max(60, CGFloat(h)) }
            }
        }
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

/// M: move the selected conversation to a category (1–6). "Always for this sender" is one tick away.
struct CategoryPicker: View {
    @Environment(AppModel.self) private var model
    @State private var alwaysForSender = false

    var body: some View {
        let thread = model.targetThreads.first
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to…").font(.headline)
            VStack(spacing: 2) {
                ForEach(Array(MailCategory.allCases.enumerated()), id: \.element) { index, category in
                    Button { move(to: category) } label: {
                        HStack {
                            Image(systemName: category.symbol).foregroundStyle(category.tint).frame(width: 22)
                            Text(category.title)
                            if category == thread?.latest.category {
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .disabled(category == thread?.latest.category && !alwaysForSender)
                }
            }
            Toggle("Always for \(thread?.latest.senderDisplay ?? "this sender")", isOn: $alwaysForSender)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            Text(alwaysForSender
                 ? "Their existing and future mail moves too."
                 : "Tidings learns from this. Move the same sender twice and it becomes a rule.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel") { model.isCategoryPickerShown = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .macFrame(width: 340)
    }

    private func move(to category: MailCategory) {
        if alwaysForSender { model.moveSender(to: category) } else { model.moveConversations(model.targetThreads, to: category) }
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
                .foregroundStyle(danger ? .red : .orange)
            ForEach(RiskAssessment.decode(message.riskReasons), id: \.self) { reason in
                Label(reason.localized, systemImage: "circle.fill")
                    .labelStyle(BulletLabelStyle())
                    .font(.callout)
            }
            HStack {
                Button("Move to Junk", systemImage: "xmark.bin") {
                    if let thread = model.threads.first(where: { $0.threadID == message.threadID }) {
                        model.perform(.junk, on: [thread])
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(danger ? .red : .orange)
                Button("It's safe") { model.markSafe(message) }
                    .buttonStyle(.glass)
                Spacer()
                Text("Don't click links or open attachments unless you're sure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((danger ? Color.red : Color.orange).opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((danger ? Color.red : Color.orange).opacity(0.4)))
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
