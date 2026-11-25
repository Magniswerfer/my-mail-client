import MailEngine
import SwiftUI

/// The conversations set aside with Reply Later (L), answered one after another.
struct ReplySession: Identifiable {
    let id = UUID()
    var threads: [ThreadSummary]
}

extension AppModel {
    /// Everything set aside, whichever list is on screen.
    var replyLaterThreads: [ThreadSummary] {
        switch selection {
        case .inbox where !pinnedOnly, .replyLater: threads.filter(\.isReplyLater)
        default: ((try? store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)) ?? []).filter(\.isReplyLater)
        }
    }

    /// "Answer them now": opens the session with the pile as it is.
    func startReplySession() {
        let pile = replyLaterThreads
        guard !pile.isEmpty else {
            show(Toast(message: String(localized: "Nothing set aside. Press L on a conversation to reply to it later."),
                       symbol: "arrowshape.turn.up.left.circle"))
            return
        }
        replySession = ReplySession(threads: pile)
    }
}

/// At the top of the Inbox: "Reply Later · 3 · Anna, Bo, Carl  [Answer Now]".
struct ReplyLaterRow: View {
    @Environment(AppModel.self) private var model
    let threads: [ThreadSummary]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Reply Later").font(.headline)
                    Text("\(threads.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(threads.prefix(4).map { $0.participants.first ?? $0.latest.senderDisplay }.joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Answer Now") { model.startReplySession() }
                .buttonStyle(.glassProminent)
                .help("Answer them one after another (⌘⇧L)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Focus & Reply (after HEY): the conversation on top, your reply below, then the next one.
/// Sending (or "Done Without Replying") takes it off the pile; Skip leaves it there.
struct ReplySessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: ReplySession
    @State private var index = 0
    @State private var compose: ComposeModel?
    @State private var answered: Set<String> = []
    @State private var loading = false

    private var current: ThreadSummary? { session.threads.indices.contains(index) ? session.threads[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    #if os(macOS)
                    HStack(spacing: 0) {
                        queue.frame(width: 220)
                        Divider()
                        workspace(current)
                    }
                    #else
                    workspace(current)
                    #endif
                } else {
                    ContentUnavailableView {
                        Label("All answered", systemImage: "checkmark.circle")
                    } description: {
                        Text("\(answered.count) of \(session.threads.count) answered. The rest stay in Reply Later.")
                    } actions: {
                        Button("Close") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .navigationTitle(current.map { _ in String(localized: "Reply \(index + 1) of \(session.threads.count)") } ?? "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { leaveDraftIfUntouched(); dismiss() }
                }
            }
        }
        .macFrame(minWidth: 1000, minHeight: 720)
        .task(id: index) { await prepare() }
    }

    private var queue: some View {
        List {
            ForEach(Array(session.threads.enumerated()), id: \.element.threadID) { i, thread in
                HStack(spacing: 8) {
                    Image(systemName: answered.contains(thread.threadID) ? "checkmark.circle.fill" : (i == index ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(answered.contains(thread.threadID) ? Color.green : (i == index ? Color.accentColor : Color.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.participants.first ?? thread.latest.senderDisplay).font(.callout.weight(i == index ? .semibold : .regular))
                        Text(thread.latest.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { jump(to: i) }
            }
        }
        .listStyle(.sidebar)
    }

    private func workspace(_ thread: ThreadSummary) -> some View {
        VStack(spacing: 0) {
            ReaderView(threadID: thread.threadID)
                .frame(maxHeight: .infinity)
            Divider()
            Group {
                if let compose {
                    ComposeView(model: compose, close: { finished() }, embeddedActions: AnyView(sessionActions))
                        .id(compose.draftID)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Couldn't start a reply", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The message may not be downloaded yet. Skip it or try again later.")
                    } actions: {
                        sessionActions.buttonStyle(.glass)
                    }
                }
            }
            .frame(height: Platform.isPhone ? 340 : 380)
        }
    }

    /// Next to Send in the composer's bar: leave this one for later, or finish it without a reply.
    private var sessionActions: some View {
        HStack(spacing: 10) {
            Button { skip() } label: { Label("Skip", systemImage: "forward") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .help("Leave it in Reply Later (⌥⌘→)")
            Button { doneWithoutReply() } label: { Label("Done Without Replying", systemImage: "checkmark.circle") }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .help("Take it off the pile and mark it done (⌥⌘E)")
        }
    }

    // MARK: Flow

    private func prepare() async {
        compose = nil
        guard let current else { return }
        loading = true
        defer { loading = false }
        if let id = await model.prepareDraft(.reply, thread: current) {
            compose = ComposeModel(draftID: id, app: model)
        }
    }

    /// The composer closed: sent (it left the drafts), or discarded.
    private func finished() {
        if let current, let id = compose?.draftID,
           let item = try? model.store.outboxItem(id: id), item.state != .draft {
            answered.insert(current.threadID)   // sending already cleared Reply Later
        }
        advance()
    }

    private func skip() {
        leaveDraftIfUntouched()
        advance()
    }

    private func doneWithoutReply() {
        guard let current else { return }
        compose?.discard()
        model.performQuietly(.clearReplyLater, threadID: current.threadID, accountID: current.latest.accountID)
        model.performQuietly(.done, threadID: current.threadID, accountID: current.latest.accountID)
        answered.insert(current.threadID)
        advance()
    }

    private func jump(to i: Int) {
        guard i != index else { return }
        leaveDraftIfUntouched()
        index = i
    }

    private func advance() {
        compose = nil
        // Next one not yet answered, wrapping around once; past the end means finished.
        let order = Array(session.threads.indices.dropFirst(index + 1)) + Array(session.threads.indices.prefix(index))
        index = order.first { !answered.contains(session.threads[$0].threadID) } ?? session.threads.count
    }

    /// A reply you never typed into isn't worth keeping in Drafts.
    private func leaveDraftIfUntouched() {
        guard let compose else { return }
        if compose.isDirty { compose.saveNow() } else { compose.discard() }
    }
}

// MARK: - Keyboard shortcuts (?)

struct ShortcutsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Entry: Hashable { var keys: String; var title: String }

    var sections: [(String, [Entry])] {
        let byID = Dictionary(model.commands.compactMap { c in c.keys.map { (c.id, Entry(keys: $0, title: c.title)) } },
                              uniquingKeysWith: { a, _ in a })
        func pick(_ ids: [String]) -> [Entry] { ids.compactMap { byID[$0] } }
        return [
            (String(localized: "Move around"), pick(["next", "previous", "goInbox", "goSnoozed", "goReplyLater", "goOutbox", "pinnedOnly"]) + [
                Entry(keys: "/", title: String(localized: "Search")),
                Entry(keys: "⌘K", title: String(localized: "Command Palette")),
                Entry(keys: "?", title: String(localized: "Keyboard Shortcuts")),
            ]),
            (String(localized: "Triage"), pick(["done", "pin", "snooze", "replyLater", "moveFolder", "read", "inbox", "trash", "junk", "sweep", "undo"])
                + [Entry(keys: "M", title: String(localized: "Move to Category…"))]),
            (String(localized: "Write"), pick(["compose", "reply", "replyAll", "forward", "introReply", "replySession"]) + [
                Entry(keys: "⌘↩", title: AssistSettings.sendAndDone ? String(localized: "Send and Mark Done (replies)") : String(localized: "Send")),
                Entry(keys: "⌥⌘↩", title: AssistSettings.sendAndDone ? String(localized: "Send and Keep in Inbox") : String(localized: "Send and Mark Done")),
                Entry(keys: "⌥⌘A", title: String(localized: "Share Availability")),
                Entry(keys: "⌘⇧A", title: String(localized: "Attach Files")),
            ]),
            (String(localized: "Other"), pick(["inviteAccept", "inviteMaybe", "inviteDecline", "contact", "addReminder", "checkMail", "rules"])),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 20) {
                    ForEach(sections, id: \.0) { title, entries in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            ForEach(entries, id: \.self) { entry in
                                HStack {
                                    Text(entry.title)
                                    Spacer()
                                    Text(entry.keys)
                                        .font(.callout.monospaced())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: .rect(cornerRadius: 5))
                                }
                            }
                        }
                    }
                }
            }
            Text("Single keys work when you're not typing. Every command is also in ⌘K.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .macFrame(width: 720, height: 560)
    }
}
