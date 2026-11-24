import MailEngine
import SwiftUI
import WebKit

/// The reading pane: a conversation stacked oldest→newest; older messages collapsed.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let threadID: String?

    var body: some View {
        if let threadID {
            let messages = model.messages(inThread: threadID)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let first = messages.last {
                        Text(first.subject)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                        if let reason = first.classificationReason {
                            Label("\(first.category.title) · \(reason)", systemImage: first.category.symbol)
                                .font(.caption)
                                .foregroundStyle(first.category.tint)
                                .help("Why this conversation is in \(first.category.title)")
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

    init(message: StoredMessage, startsExpanded: Bool) {
        self.message = message
        _expanded = State(initialValue: startsExpanded)
    }

    struct LoadedBody {
        var html: String?
        var text: String
        var attachments: [AttachmentInfo]
        var to: String
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
            Avatar(name: message.senderDisplay, tint: message.category.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.senderDisplay).font(.headline)
                    Text(message.fromAddress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(MailDate.long(message.date)).font(.caption).foregroundStyle(.secondary)
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
        if let loaded = body_ {
            if let html = loaded.html {
                MessageWebView(html: html)
            } else {
                Text(loaded.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !loaded.attachments.isEmpty {
                HStack {
                    ForEach(loaded.attachments.filter { !$0.isInline }, id: \.self) { a in
                        Label(a.filename ?? a.mimeType, systemImage: "doc")
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
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
        do {
            let raw = try await model.rawMessage(message)
            let parsed = MIMEParser.parse(raw)
            body_ = LoadedBody(
                html: parsed.html, text: parsed.plainText, attachments: parsed.attachments,
                to: (parsed.to + parsed.cc).map(\.description).joined(separator: ", ")
            )
        } catch {
            loadError = String(localized: "Couldn't load the full message. Showing the stored text.")
        }
    }
}

/// HTML mail in a locked-down web view: no JavaScript, no remote loads (tracking pixels, remote
/// images and fonts are blocked; SPEC §8), links open in the browser. Height follows content.
struct MessageWebView: NSViewRepresentable {
    let html: String
    @State private var height: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        Coordinator.withBlockList { list in
            if let list { view.configuration.userContentController.add(list) }
            view.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    static func wrap(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:">
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; padding: 12px; background: white; color: #1d1d1f;
                       font: 14px -apple-system, system-ui, sans-serif; overflow-wrap: anywhere; border-radius: 10px; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        static var cachedList: WKContentRuleList?

        /// Blocks every http(s) subresource. The CSP above already does; this is belt and braces.
        static func withBlockList(_ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
            if let cachedList { body(cachedList); return }
            let rules = #"[{"trigger":{"url-filter":"^https?://","resource-type":["image","style-sheet","font","media","raw","svg-document","script","fetch","websocket","other"]},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "tidings-block-remote", encodedContentRuleList: rules) { list, _ in
                MainActor.assumeIsolated {
                    cachedList = list
                    body(list)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
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
