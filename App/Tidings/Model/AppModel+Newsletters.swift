import Foundation
import MailEngine
import SwiftUI

/// "Unsubscribe from …?" — always confirmed (SPEC §11).
struct UnsubscribeRequest: Identifiable {
    let id = UUID()
    var sender: String
    var name: String
    var options: UnsubscribeOptions
    var accountID: String
}

/// Snippets (`;keyword` expands as you type, SPEC §9).
struct Snippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var keyword: String
    var text: String
}

enum SnippetStore {
    static let key = "compose.snippets"

    static var all: [Snippet] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// Variables filled in at expansion.
    static func expand(_ snippet: Snippet, context: SnippetContext) -> String {
        snippet.text
            .replacingOccurrences(of: "{first}", with: context.firstName)
            .replacingOccurrences(of: "{name}", with: context.fullName)
            .replacingOccurrences(of: "{me}", with: context.myName)
            .replacingOccurrences(of: "{date}", with: Date().formatted(date: .long, time: .omitted))
    }
}

/// Who the open draft is to and from (set by the composer, read by the editor).
struct SnippetContext {
    var firstName = ""
    var fullName = ""
    var myName = ""
    @MainActor static var current = SnippetContext()
}

extension AppModel {
    // MARK: Mute & Read Later

    /// Mute (⇧M): the conversation leaves the Inbox, and later messages in it skip the Inbox too.
    func mute(_ thread: ThreadSummary? = nil) { keywordThenDone(.mute, thread: thread) }

    /// Read Later (⇧R): out of the Inbox, into the Read Later smart folder, for reader mode.
    func readLater(_ thread: ThreadSummary? = nil) { keywordThenDone(.readLater, thread: thread) }

    private func keywordThenDone(_ kind: TriageKind, thread: ThreadSummary?) {
        guard let thread = thread ?? targetThreads.first else { return }
        let account = thread.latest.accountID
        let flag = performQuietly(kind, threadID: thread.threadID, accountID: account)
        let done = sourceMailbox == "INBOX" ? performQuietly(.done, threadID: thread.threadID, accountID: account) : nil
        let undo: @MainActor () -> Void = { [weak self] in
            self?.undo(box: flag)
            if let done { self?.undo(box: done) }
        }
        undoManager?.registerUndo(withTarget: self) { _ in MainActor.assumeIsolated { undo() } }
        undoManager?.setActionName(kind.toastText(count: 1))
        show(Toast(message: kind.toastText(count: 1), symbol: kind.symbol, undoAction: undo))
    }

    func toggleMute(_ thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first else { return }
        if isMuted(thread.threadID) { unmute(thread) } else { mute(thread) }
    }

    func unmute(_ thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first else { return }
        perform(.unmute, on: [thread])
    }

    // MARK: Unsubscribe

    /// Asks first; then one-click (RFC 8058), an email to the list, or the list's web page.
    func requestUnsubscribe(from address: String) {
        guard let found = (try? store.unsubscribeOptions(for: address)) ?? nil else {
            show(Toast(message: String(localized: "This sender doesn't offer a way to unsubscribe. Try a rule that marks their mail done."),
                       symbol: "envelope.badge.shield.half.filled"))
            return
        }
        let (options, message) = found
        unsubscribeRequest = UnsubscribeRequest(sender: address.lowercased(), name: message.senderDisplay, options: options,
                                                accountID: message.accountID)
    }

    func requestUnsubscribe(thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first else { return }
        requestUnsubscribe(from: thread.latest.fromAddress)
    }

    func confirmUnsubscribe(_ request: UnsubscribeRequest, markDone: Bool) {
        unsubscribeRequest = nil
        Task {
            var ok = false
            if let url = request.options.oneClick {
                var post = URLRequest(url: url)
                post.httpMethod = "POST"
                post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                post.httpBody = Data("List-Unsubscribe=One-Click".utf8)
                post.timeoutInterval = 20
                if let (_, response) = try? await URLSession.shared.data(for: post),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    ok = true
                }
            }
            if !ok, let address = request.options.mailto,
               let account = accounts.first(where: { $0.id == request.accountID }), let identity = account.sendingIdentities.first {
                let message = OutgoingMessage(from: identity.mailAddress, to: [MailAddress(name: nil, address: address)],
                                              subject: request.options.mailtoSubject ?? "unsubscribe", text: "unsubscribe")
                ok = (try? await syncs[account.id]?.queue(message, sendAt: Date())) != nil
                reloadOutbox()
            }
            if !ok, let page = request.options.web {
                Platform.openExternally(page)
                ok = true
            }
            var done = UserDefaults.standard.stringArray(forKey: "newsletters.unsubscribed") ?? []
            if ok, !done.contains(request.sender) { done.append(request.sender); UserDefaults.standard.set(done, forKey: "newsletters.unsubscribed") }
            if ok, markDone { markAllDone(from: request.sender) }
            show(Toast(message: ok ? String(localized: "Unsubscribed from \(request.name)")
                                   : String(localized: "Couldn't unsubscribe from \(request.name)"),
                       symbol: ok ? "envelope.badge.shield.half.filled" : "exclamationmark.triangle"))
        }
    }

    func isUnsubscribed(_ address: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "newsletters.unsubscribed") ?? []).contains(address.lowercased())
    }

    /// Senders screen: everything from them in the Inbox → Done.
    func markAllDone(from address: String) {
        let ids = (try? store.threadIDs(from: address)) ?? []
        guard !ids.isEmpty else { return }
        let loaded = threads.filter { ids.contains($0.threadID) }
        if !loaded.isEmpty, sourceMailbox == "INBOX" {
            perform(.done, on: loaded)
        } else if let account = messages(inThread: ids[0]).first?.accountID ?? accounts.first?.id {
            for id in ids { performQuietly(.done, threadID: id, accountID: account) }
        }
    }

    // MARK: Attachments

    /// Writes an attachment to a temporary file for Quick Look / sharing.
    func file(for entry: AttachmentEntry) async -> URL? {
        guard let message = (try? store.message(id: entry.messageID)) ?? nil,
              let raw = try? await rawMessage(message) else { return nil }
        let files = MIMEParser.attachments(in: raw).filter { $0.contentID == nil }
        let match = files.first { $0.filename == entry.info.filename } ?? (files.indices.contains(entry.index) ? files[entry.index] : nil)
        guard let match else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Tidings-Attachments", isDirectory: true)
            .appendingPathComponent("\(entry.messageID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (match.filename.isEmpty ? "attachment" : match.filename).replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent(name)
        do { try match.data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    // MARK: Snippets

    /// The composer calls this with who the message is to and from.
    func setSnippetContext(to: [MailAddress], from identity: Identity) {
        let first = to.first
        SnippetContext.current = SnippetContext(firstName: first.map(IntroReply.firstName) ?? "",
                                                fullName: first?.name ?? first?.address ?? "",
                                                myName: identity.name)
    }
}
