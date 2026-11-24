import MailEngine
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Called on every pick, even of the current place (iPhone uses it to go to the list).
    var didPick: (() -> Void)? = nil

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.selection = s; didPick?() } })) {
            Section {
                // `.tag` must be the outermost modifier, or the row can't be selected.
                Label("Inbox", systemImage: "tray")
                    .badge(model.inboxUnreadCount)
                    .tag(SidebarItem.inbox)
                Label("Snoozed", systemImage: "clock")
                    .dropDestination(for: ThreadDrag.self) { items, _ in
                        guard !items.isEmpty else { return false }
                        model.selectedThreadID = items.first?.threadID
                        model.isSnoozePickerShown = true
                        return true
                    }
                    .tag(SidebarItem.snoozed)
                if !model.autoDrafts.isEmpty {
                    Button {
                        model.selection = .outbox
                        didPick?()
                    } label: {
                        Label("Follow-ups", systemImage: "arrowshape.turn.up.right.circle")
                            .badge(model.autoDrafts.count)
                    }
                    .buttonStyle(.plain)
                    .help("Drafted follow-ups for conversations still waiting on a reply")
                }
                if !model.outboxItems.isEmpty || !model.draftItems.isEmpty {
                    Label("Outbox", systemImage: "paperplane")
                        .badge(model.outboxItems.count)
                        .tag(SidebarItem.outbox)
                }
            }

            // Drop a conversation here to move it (and teach the classifier).
            Section("Categories") {
                ForEach(MailCategory.allCases, id: \.self) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.symbol).foregroundStyle(category.tint)
                    }
                    .dropDestination(for: ThreadDrag.self) { items, _ in
                        let threads = model.threads(for: items)
                        guard !threads.isEmpty else { return false }
                        model.moveConversations(threads, to: category)
                        return true
                    }
                    .tag(SidebarItem.category(category))
                }
            }

            ForEach(model.accounts) { account in
                Section(model.accounts.count > 1 ? account.displayName : String(localized: "Folders")) {
                    ForEach(folders(for: account.id), id: \.path) { box in
                        folderRow(box, accountID: account.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarStatus() }
    }

    @ViewBuilder
    private func folderRow(_ box: MailboxState, accountID: String) -> some View {
        let label = Label(box.role?.title ?? box.path, systemImage: box.role?.symbol ?? "folder")
        if box.role == .archive {
            // Dropping on Archive is "Done".
            label
                .dropDestination(for: ThreadDrag.self) { items, _ in
                    let threads = model.threads(for: items)
                    guard !threads.isEmpty else { return false }
                    model.perform(.done, on: threads)
                    return true
                }
                .tag(SidebarItem.mailbox(accountID: accountID, path: box.path))
        } else {
            label.tag(SidebarItem.mailbox(accountID: accountID, path: box.path))
        }
    }

    private func folders(for accountID: String) -> [MailboxState] {
        let order: [MailboxRole?] = [.archive, .sent, .drafts]
        return model.mailboxes
            .filter { $0.accountID == accountID && $0.role != .inbox && $0.path != AccountSync.snoozedMailbox }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.role) ?? order.count
                let ib = order.firstIndex(of: b.role) ?? order.count
                return ia == ib ? a.path.localizedStandardCompare(b.path) == .orderedAscending : ia < ib
            }
    }
}

/// Sync and sorting status, where Mail puts it: quietly at the foot of the sidebar.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let error = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.tail).help(error)
            } else if model.isRefining {
                Image(systemName: "sparkles").foregroundStyle(.purple).symbolEffect(.pulse)
                Text("Sorting with on-device AI…")
            } else if let status = model.syncStatus.values.sorted().first {
                Text(status)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AppModel {
    /// Resolves dragged conversations to the ones currently loaded.
    func threads(for drags: [ThreadDrag]) -> [ThreadSummary] {
        let ids = Set(drags.map(\.threadID))
        return threads.filter { ids.contains($0.threadID) }
    }
}
