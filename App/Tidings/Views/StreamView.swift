import MailEngine
import SwiftUI

/// The Inbox-style stream: conversations, with non-primary categories as inline bundles.
struct StreamView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedThreadID) {
            ForEach(model.streamItems) { item in
                switch item {
                case .thread(let thread):
                    ThreadRow(thread: thread)
                        .tag(thread.threadID)
                        .contextMenu { ThreadActions(thread: thread) }
                case .bundle(let category, let members):
                    BundleRow(category: category, threads: members, expanded: model.expandedBundles.contains(category))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { model.toggleBundle(category) } }
                        .selectionDisabled()
                        .contextMenu {
                            Button("Mark All \(category.title) Done", systemImage: "checkmark.circle") {
                                model.requestSweep(bundle: category)
                            }
                        }
                    if model.expandedBundles.contains(category) {
                        ForEach(members) { thread in
                            ThreadRow(thread: thread, inBundle: true)
                                .tag(thread.threadID)
                                .contextMenu { ThreadActions(thread: thread) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.threads.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "tray")
                } description: {
                    Text(model.syncStatus.isEmpty ? "Add an account to start." : "Mail will appear as it syncs.")
                }
            }
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    var inBundle = false

    var body: some View {
        let m = thread.latest
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: m.senderDisplay, tint: m.category.tint, size: inBundle ? 26 : 32)
                .padding(.leading, inBundle ? 18 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(senderLine)
                        .font(.headline.weight(thread.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if m.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Has attachment")
                    }
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                    if let wake = thread.snoozedUntil {
                        Label(MailDate.short(wake), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Snoozed until \(MailDate.long(wake))")
                    } else {
                        Text(MailDate.short(thread.arrivedAt))
                            .font(.caption)
                            .foregroundStyle(thread.unreadCount > 0 ? .primary : .secondary)
                    }
                }
                Text(m.subject)
                    .font(.subheadline.weight(thread.unreadCount > 0 ? .medium : .regular))
                    .lineLimit(1)
                Text(m.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if thread.unreadCount > 0 {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .offset(x: inBundle ? 6 : -10)
                    .accessibilityLabel("Unread")
            }
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

struct BundleRow: View {
    let category: MailCategory
    let threads: [ThreadSummary]
    let expanded: Bool

    var body: some View {
        let unread = threads.reduce(0) { $0 + $1.unreadCount }
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(category.tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.title)
                        .font(.headline.weight(unread > 0 ? .semibold : .regular))
                    if unread > 0 {
                        Text("\(unread) new").font(.caption).foregroundStyle(category.tint)
                    }
                    Spacer()
                    Text(MailDate.short(threads.first?.latest.date ?? .now))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(senders)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.vertical, 6)
        .background(category.tint.opacity(0.06), in: .rect(cornerRadius: 10))
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

/// Right-click actions for a conversation; same actions as the keys and the ⌘K palette.
struct ThreadActions: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary

    var body: some View {
        Button("Mark Done", systemImage: "checkmark.circle") { model.perform(.done, on: [thread]) }
        Button(thread.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.perform(thread.isPinned ? .unpin : .pin, on: [thread]) }
        Button("Snooze…", systemImage: "clock") {
            model.selectedThreadID = thread.threadID
            model.isSnoozePickerShown = true
        }
        Button(thread.unreadCount > 0 ? "Mark as Read" : "Mark as Unread", systemImage: "envelope.open") {
            model.perform(thread.unreadCount > 0 ? .markRead : .markUnread, on: [thread])
        }
        Divider()
        Button("Move to Trash", systemImage: "trash") { model.perform(.trash, on: [thread]) }
        Button("Move to Junk", systemImage: "xmark.bin") { model.perform(.junk, on: [thread]) }
    }
}
