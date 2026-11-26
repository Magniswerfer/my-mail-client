import MailEngine
import SwiftUI

/// The Inbox-style stream: conversations, with non-primary categories as inline bundles.
struct StreamView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
        list
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            // iPhone has the swipe bar at the bottom instead (PhoneBottomBar).
            if model.currentCategoryTab != nil, !model.isSearching, !Platform.isPhone { CategoryTabs() }
        }
        .overlay {
            if model.threads.isEmpty { EmptyStream() }
        }
        // Keep the selection in view as j/k move it: instantly (an animation per key press falls
        // behind fast typing), only as far as needed, with one row of lookahead in the direction
        // of travel so you see what's coming.
        .onChange(of: model.selectedThreadID) { _, id in
            guard let id else { return }
            let ids = model.visibleThreadIDs
            var target = id
            if model.lastMoveDirection != 0, let i = ids.firstIndex(of: id), ids.indices.contains(i + model.lastMoveDirection) {
                target = ids[i + model.lastMoveDirection]
            }
            model.lastMoveDirection = 0
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target) }
        }
        }
    }

    /// On the Mac the list takes several rows (⌘A, ⇧-click, ⌘-click) and shows them all
    /// highlighted; the focus stays `selectedThreadID`. iOS keeps single selection (taps open).
    @ViewBuilder private var list: some View {
        #if os(macOS)
        List(selection: Binding(get: { model.listSelection }, set: { model.setListSelection($0) })) { rows }
        #else
        @Bindable var model = model
        if model.isSelecting {
            // Select mode: taps tick rows; the bottom bar acts on all of them.
            List(selection: $model.multiSelection) { rows }
                .environment(\.editMode, .constant(.active))
        } else {
            List(selection: $model.selectedThreadID) { rows }
        }
        #endif
    }

    @ViewBuilder private var rows: some View {
        let firstID = model.streamItems.first?.id
        ForEach(model.streamItems) { item in
            Group {
                switch item {
            case .thread(let thread):
                row(thread)
            case .replyLater(let pile):
                ReplyLaterRow(threads: pile)
                    .selectionDisabled()
            case .bundle(let category, let members, let deliveredAt):
                BundleRow(category: category, threads: members, expanded: model.expandedBundles.contains(category),
                          deliveredAt: deliveredAt, waiting: model.waiting(category))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { model.toggleBundle(category) } }
                    .selectionDisabled()
                    .contextMenu {
                        Button("Mark All \(category.title) Done", systemImage: "checkmark.circle") {
                            model.requestSweep(bundle: category)
                        }
                    }
                if model.expandedBundles.contains(category) {
                    ForEach(members) { thread in row(thread, inBundle: true) }
                }
            }
            }
            // No line above the first row, only between rows.
            .listRowSeparator(item.id == firstID ? .hidden : .automatic, edges: .top)
            // Room for the unread dot before the avatars, as in Mail (every row, so they line up).
            .padding(.leading, ThreadRow.dotGutter)
        }
    }

    private func row(_ thread: ThreadSummary, inBundle: Bool = false) -> some View {
        ThreadRow(thread: thread, inBundle: inBundle)
            .id(thread.threadID)
            .tag(thread.threadID)
            .contextMenu { ThreadActions(thread: thread) }
            #if os(iOS)
            // Inbox-style swipes: right to pin, left for Done (full swipe) or Snooze.
            .swipeActions(edge: .leading) {
                Button { model.perform(thread.isPinned ? .unpin : .pin, on: [thread]) } label: {
                    Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
                Button { model.perform(thread.isReplyLater ? .clearReplyLater : .replyLater, on: [thread]) } label: {
                    Label("Reply Later", systemImage: "arrowshape.turn.up.left.circle")
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { model.perform(.done, on: [thread]) } label: { Label("Done", systemImage: "checkmark") }
                    .tint(.green)
                Button {
                    model.snoozeTarget = thread.threadID
                    model.isSnoozePickerShown = true
                } label: { Label("Snooze", systemImage: "clock") }
                    .tint(.blue)
            }
            #endif
            .modifier(SidebarDrag(thread: thread))
    }
}

/// Drag a conversation onto a category (or Archive) in the sidebar to move it. Not on iPhone:
/// the sidebar is never beside the list there, and the drag's hold-to-lift caught slower swipes,
/// so a swipe to Done sprang back instead.
private struct SidebarDrag: ViewModifier {
    let thread: ThreadSummary

    func body(content: Content) -> some View {
        if Platform.isPhone {
            content
        } else {
            content.draggable(ThreadDrag(threadID: thread.threadID)) {
                Label(thread.latest.subject, systemImage: "envelope")
                    .padding(8)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }
}

/// What a dragged conversation carries.
struct ThreadDrag: Codable, Transferable {
    var threadID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// Sweep is only in the list's … menu (and ⌘⇧E, ⌘K), not a button at the end of the list.

struct EmptyStream: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .inbox where !model.syncStatus.isEmpty:
            ContentUnavailableView {
                Label("Inbox zero", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing left to deal with. New mail will show up here.")
            }
        case .smartFolder:
            ContentUnavailableView {
                Label("Nothing matches", systemImage: "folder.badge.gearshape")
            } description: {
                Text("This smart folder's search finds nothing right now.")
            }
        case .replyLater:
            ContentUnavailableView {
                Label("Nothing set aside", systemImage: "arrowshape.turn.up.left.circle")
            } description: {
                Text("Press L on a conversation to reply to it later.")
            }
        case .snoozed:
            ContentUnavailableView {
                Label("Nothing snoozed", systemImage: "clock")
            } description: {
                Text(Platform.isPhone ? "Swipe left on a conversation to bring it back later."
                                      : "Press B on a conversation to bring it back later.")
            }
        default:
            ContentUnavailableView {
                Label("Nothing here", systemImage: "tray")
            } description: {
                Text(model.syncStatus.isEmpty ? "Add an account to start." : "Mail will appear as it syncs.")
            }
        }
    }
}

struct ThreadRow: View {
    /// Space before every row's avatar, where the unread dot sits.
    static let dotGutter: CGFloat = Platform.isPhone ? 18 : 8

    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    var inBundle = false

    var body: some View {
        let m = thread.latest
        let unread = thread.unreadCount > 0
        let avatarSize: CGFloat = inBundle ? 26 : 32
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: senderLine, size: avatarSize)
                .padding(.leading, inBundle ? 18 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(senderLine)
                        .font(.headline.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    statusIcons(m)
                    if let wake = thread.snoozedUntil {
                        Label(MailDate.short(wake), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Snoozed until \(MailDate.long(wake))")
                    } else {
                        Text(MailDate.short(thread.arrivedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(unread ? .primary : .secondary)
                    }
                }
                Text(m.subject)
                    .font(.subheadline.weight(unread ? .medium : .regular))
                    .lineLimit(1)
                if let highlight = m.highlights?.first {
                    HighlightChip(highlight: highlight, message: m)
                }
                Text(m.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // A reply or follow-up Tidings wrote waits under the mail it answers (there's
                // no separate list for them); click to open it.
                if let draft = model.autoDraft(forThread: thread.threadID) {
                    Button { model.reviewFollowUp(threadID: thread.threadID) } label: {
                        // Icon and text side by side (a Label in an iPhone list row gets an
                        // icon column and a wide gap).
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text(draft.kind == .reply ? "Reply drafted for you" : "Follow-up drafted for you")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                    }
                    .buttonStyle(.borderless)
                    .help("Open the draft. Nothing is sent without you.")
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .topLeading) {
            if unread {
                // Level with the avatar's middle (as in Mail), not the middle of a tall row, in the
                // gutter before it with a clear gap.
                let dot: CGFloat = Platform.isPhone ? 9 : 7
                let gap: CGFloat = Platform.isPhone ? 9 : 5
                Circle().fill(Color.accentColor).frame(width: dot, height: dot)
                    .offset(x: (inBundle ? 18 : 0) - gap - dot, y: 4 + avatarSize / 2 - dot / 2)
                    .accessibilityLabel("Unread")
            }
        }
    }

    @ViewBuilder private func statusIcons(_ m: StoredMessage) -> some View {
        if m.riskLevel > .none {
            Image(systemName: m.riskLevel == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(m.riskLevel == .danger ? .red : .orange)
                .accessibilityLabel(m.riskLevel == .danger ? "Looks like phishing" : "Be careful")
        }
        // You already answered the newest message (from here or another device: the IMAP flags).
        if m.flags.contains("\\Answered") {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.caption).foregroundStyle(.secondary)
                .help("You replied")
                .accessibilityLabel("Replied")
        } else if m.flags.contains("$Forwarded") {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.caption).foregroundStyle(.secondary)
                .help("You forwarded it")
                .accessibilityLabel("Forwarded")
        }
        if m.hasAttachments {
            Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Has attachment")
        }
        if thread.isPinned {
            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                .accessibilityLabel("Pinned")
        }
    }

    /// The other people in the conversation (never you); first names when there are several.
    private var senderLine: String {
        let others = thread.participants
        if others.count > 1 {
            return others.prefix(3).map { $0.split(separator: " ").first.map(String.init) ?? $0 }.joined(separator: ", ")
        }
        return others.first ?? thread.latest.senderDisplay
    }
}

/// A bundle in the stream. Its colour lives only in the symbol, so colour keeps meaning
/// "category" and the mail itself stays the loudest thing on screen.
struct BundleRow: View {
    let category: MailCategory
    let threads: [ThreadSummary]
    let expanded: Bool
    var deliveredAt: Date? = nil
    var waiting: (count: Int, next: Date)? = nil

    var body: some View {
        let unread = threads.reduce(0) { $0 + $1.unreadCount }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: category.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(category.tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(category.title)
                        .font(.headline.weight(unread > 0 ? .semibold : .regular))
                    if unread > 0 {
                        Text("\(unread) new")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(category.tint)
                    }
                    Spacer(minLength: 6)
                    Text(MailDate.short(deliveredAt ?? threads.first?.arrivedAt ?? .now))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Text(senders)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let waiting {
                    Label("\(waiting.count) more at \(waiting.next.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Collapse bundle" : "Expand bundle")
    }

    private var senders: String {
        var seen: [String] = []
        for t in threads where !seen.contains(t.latest.senderDisplay) {
            seen.append(t.latest.senderDisplay)
            if seen.count == 4 { break }
        }
        return seen.joined(separator: ", ")
    }
}

/// Right-click actions for a conversation; the same actions as the toolbar, keys and ⌘K.
struct ThreadActions: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary

    var body: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { model.compose(.reply, thread: thread) }
        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { model.compose(.replyAll, thread: thread) }
        Button("Forward", systemImage: "arrowshape.turn.up.right") { model.compose(.forward, thread: thread) }
        Button("Reply to Introduction", systemImage: "person.2.wave.2") { model.replyToIntroduction(thread: thread) }
        Button(model.isMuted(thread.threadID) ? "Unmute" : "Mute", systemImage: "bell.slash") { model.toggleMute([thread]) }
        Button("Read Later", systemImage: "book") { model.readLater(thread) }
        AICategoryMenu(thread: thread)
        Button(thread.isReplyLater ? "Remove from Reply Later" : "Reply Later", systemImage: "arrowshape.turn.up.left.circle") {
            model.perform(thread.isReplyLater ? .clearReplyLater : .replyLater, on: [thread])
        }
        Divider()
        Menu("Add to Reminders", systemImage: "checklist") {
            ForEach(AppModel.ReminderDue.allCases, id: \.self) { due in
                Button(due.title) { model.addToReminders(thread: thread, due: due) }
            }
        }
        if model.canAddToThings {
            Button("Add to Things", systemImage: "checkmark.square") { model.addToThings(thread: thread) }
        }
        Button("Copy Link to Message", systemImage: "link") { model.copyLink(thread: thread) }
        Button("Create Rule…", systemImage: "line.3.horizontal.decrease.circle") { model.newRule(from: thread) }
        if thread.latest.isList {
            Button("Unsubscribe…", systemImage: "hand.raised") { model.requestUnsubscribe(address: thread.latest.fromAddress) }
        }
        Divider()
        Button("Mark Done", systemImage: "checkmark.circle") { model.perform(.done, on: [thread]) }
        Button("Snooze…", systemImage: "clock") {
            model.selectedThreadID = thread.threadID
            model.isSnoozePickerShown = true
        }
        Button(thread.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.perform(thread.isPinned ? .unpin : .pin, on: [thread]) }
        Button(thread.unreadCount > 0 ? "Mark as Read" : "Mark as Unread", systemImage: "envelope.open") {
            model.perform(thread.unreadCount > 0 ? .markRead : .markUnread, on: [thread])
        }
        Menu("Move to", systemImage: "tray.and.arrow.down") { MoveMenuContent(thread: thread) }
        Menu("Move to Folder", systemImage: "folder") { FolderMenuContent(thread: thread) }
        Divider()
        if model.isInJunk(thread.latest) {
            Button("Not Junk", systemImage: "tray.and.arrow.down") { model.notJunk([thread]) }
        } else {
            Button("Move to Junk", systemImage: "xmark.bin") { model.perform(.junk, on: [thread]) }
        }
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.perform(.trash, on: [thread]) }
    }
}

/// "Move to": this conversation (the default, and it teaches the classifier) or always for the sender.
/// With several selected (⌘A), they all move, and there's no single sender to choose for.
struct MoveMenuContent: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    var threads: [ThreadSummary]? = nil

    var body: some View {
        let all = threads ?? [thread]
        Section(all.count > 1 ? String(localized: "\(all.count) conversations") : String(localized: "This conversation")) {
            ForEach(model.categoryTargets) { target in
                Button(target.title, systemImage: target.symbol) {
                    model.move(all, to: target)
                }
                .disabled(model.isCurrent(target, for: all))
            }
        }
        if all.count == 1 {
            senderSection
        }
    }

    @ViewBuilder private var senderSection: some View {
        Section("Always for \(thread.latest.senderDisplay)") {
            ForEach(model.categoryTargets) { target in
                Button(target.title, systemImage: target.symbol) {
                    model.moveSender(of: thread, to: target)
                }
            }
        }
    }
}

/// Folders as menu items (the mouse route to what V does).
struct FolderMenuContent: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    var threads: [ThreadSummary]? = nil

    var body: some View {
        ForEach(model.folderTargets(for: thread), id: \.path) { box in
            Button(box.displayName, systemImage: box.role?.symbol ?? "folder") {
                model.move(threads ?? [thread], toFolder: box)
            }
        }
    }
}
