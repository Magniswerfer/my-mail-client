import MailEngine
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Signatures drawn as pictures for the composer, which shows the signature where it goes in
/// the text (a text view can't lay out HTML tables). WebKit draws them, so they look as the
/// recipient's mail program shows the HTML.
@MainActor final class SignatureRenderer {
    static let shared = SignatureRenderer()

    private var cache: [String: PlatformImage] = [:]
    private var waiting: [String: [CheckedContinuation<PlatformImage?, Never>]] = [:]
    private var queue: [(key: String, html: String, dark: Bool)] = []
    private var isRendering = false
    /// Where the web view lives while it draws (iOS only draws web views that are in a window).
    private var host: SignatureRenderHost?

    /// The widest a signature is drawn; wider ones wrap as in a mail window.
    static let maxWidth: CGFloat = 600

    static func key(_ signature: Signature, dark: Bool) -> String {
        SignatureHTML.stableHash(signature.displayHTML) + (dark ? "-dark" : "-light")
    }

    func cachedImage(_ signature: Signature, dark: Bool) -> PlatformImage? { cache[Self.key(signature, dark: dark)] }

    func image(_ signature: Signature, dark: Bool) async -> PlatformImage? {
        let key = Self.key(signature, dark: dark)
        if let image = cache[key] { return image }
        return await withCheckedContinuation { continuation in
            if waiting[key] != nil {
                waiting[key]?.append(continuation)
                return
            }
            waiting[key] = [continuation]
            queue.append((key, signature.displayHTML, dark))
            drain()
        }
    }

    /// Draws these ahead of time (both appearances), so a composer has them at once.
    func prerender(_ signatures: [Signature]) {
        for signature in signatures {
            for dark in [false, true] { Task { _ = await image(signature, dark: dark) } }
        }
    }

    private func drain() {
        guard !isRendering, !queue.isEmpty else { return }
        isRendering = true
        let job = queue.removeFirst()
        Task {
            let image = await render(html: job.html, dark: job.dark)
            if let image { cache[job.key] = image }
            for continuation in waiting.removeValue(forKey: job.key) ?? [] { continuation.resume(returning: image) }
            isRendering = false
            drain()
        }
    }

    /// The page: the signature on white (as most mail is read). In dark mode a white card
    /// with a margin, so it reads as the signature it is rather than a hole in the text.
    static func page(_ html: String, dark: Bool, maxWidth: CGFloat = SignatureRenderer.maxWidth) -> String {
        let card = dark ? "background:#fff;border-radius:8px;padding:8px 12px;" : "background:#fff;"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            html,body{margin:0;padding:0;background:transparent}
            #tidings-sig{display:inline-block;max-width:\(Int(maxWidth))px;\(card)color:#000;
              font-family:-apple-system,Helvetica,sans-serif;font-size:14px;line-height:1.3;-webkit-text-size-adjust:none}
            #tidings-sig img{max-width:100%}
            </style></head><body><div id="tidings-sig">\(html)</div></body></html>
            """
    }

    private func render(html: String, dark: Bool) async -> PlatformImage? {
        let host = self.host ?? SignatureRenderHost()
        self.host = host
        return await host.render(page: Self.page(html, dark: dark))
    }
}

/// One offscreen web view that draws a page and takes its picture.
@MainActor private final class SignatureRenderHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?
    #if os(iOS)
    private var window: UIWindow?
    #endif

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: SignatureRenderer.maxWidth, height: 200), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
    }

    func render(page: String) async -> PlatformImage? {
        #if os(iOS)
        attachToWindow()
        #endif
        webView.frame.size = CGSize(width: SignatureRenderer.maxWidth, height: 200)
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(page, baseURL: nil)
        }
        // Images (hosted ones arrive over the network) and fonts first, then measure.
        let measured = try? await webView.callAsyncJavaScript("""
            await Promise.all(Array.from(document.images).map(i => i.complete ? null :
                new Promise(r => { i.onload = i.onerror = r; setTimeout(r, 4000) })));
            if (document.fonts) { await document.fonts.ready }
            const r = document.getElementById('tidings-sig').getBoundingClientRect();
            return [Math.ceil(r.width), Math.ceil(r.height)];
            """, contentWorld: .page)
        guard let size = measured as? [Double], size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        let rect = CGRect(x: 0, y: 0, width: min(size[0], SignatureRenderer.maxWidth), height: min(size[1], 2000))
        webView.frame.size = rect.size
        // Layout catches up with the new size before the picture.
        try? await Task.sleep(for: .milliseconds(30))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width))
        configuration.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    #if os(iOS)
    /// Off screen, but in a window: iOS draws only web views that are.
    private func attachToWindow() {
        guard webView.window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: -10_000, y: -10_000, width: SignatureRenderer.maxWidth, height: 2000)
        window.isUserInteractionEnabled = false
        window.alpha = 0.01
        window.isHidden = false
        window.addSubview(webView)
        self.window = window
    }
    #endif

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume()
        loaded = nil
    }

    /// Links in a signature never open from the picture's page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .other ? .allow : .cancel
    }
}

// MARK: - In the editor

extension ComposeModel {
    /// The signature as one character in the text: a picture of it, marked with its id so
    /// sending puts its HTML there (`MailBodyConverter`).
    static func signatureBlock(_ signature: Signature, dark: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        setImage(SignatureRenderer.shared.cachedImage(signature, dark: dark), on: attachment)
        let text = NSMutableAttributedString(attachment: attachment)
        var attrs = RichTextEditor.baseAttributes
        attrs[.tidingsSignature] = signature.id
        text.addAttributes(attrs, range: NSRange(location: 0, length: text.length))
        return text
    }

    static func setImage(_ image: PlatformImage?, on attachment: NSTextAttachment) {
        // Until it's drawn: an empty picture of about the right height, so the text doesn't jump.
        let picture = image ?? emptyImage
        attachment.image = picture
        attachment.bounds = CGRect(origin: .zero, size: picture.size)
    }

    private static let emptyImage: PlatformImage = {
        let size = CGSize(width: 1, height: 60)
        #if os(macOS)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }()
}

// MARK: - A live preview

/// A signature as it looks in mail, sized to its content (Settings and the Signatures list).
struct SignaturePreview: View {
    let signature: Signature
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height, alignment: .leading)
                #else
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height, alignment: .leading)
                #endif
            } else {
                ProgressView().controlSize(.small).frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: SignatureRenderer.key(signature, dark: colorScheme == .dark)) {
            image = SignatureRenderer.shared.cachedImage(signature, dark: colorScheme == .dark)
            if image == nil { image = await SignatureRenderer.shared.image(signature, dark: colorScheme == .dark) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(signature.plainText))
    }
}
