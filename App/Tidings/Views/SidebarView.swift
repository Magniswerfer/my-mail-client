import MailEngine
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Called on every pick, even of the current place (iPhone uses it to go to the list).
    var didPick: (() -> Void)? = nil

    var body: some View {
        @Bindable var model = model
        // One Inbox row stands for All and every category tab: it stays selected while any of
        // them shows, and picking it opens Primary.
        let selection = Binding<SidebarItem?>(
            get: { model.isInInbox ? .inbox : model.selection },
            set: { picked in
                guard let picked else { return }
                if picked == .inbox { if !model.isInInbox { model.goToInbox() } } else { model.selection = picked }
                didPick?()
            })
        List(selection: selection) {
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
                Label("Set Aside", systemImage: "arrowshape.turn.up.left.circle")
                    .badge(model.replyLaterCount)
                    .dropDestination(for: ThreadDrag.self) { items, _ in
                        let threads = model.threads(for: items).filter { !$0.isReplyLater }
                        guard !threads.isEmpty else { return false }
                        model.perform(.replyLater, on: threads)
                        return true
                    }
                    .help("Conversations you set aside to reply to later (L)")
                    .tag(SidebarItem.replyLater)
                if !model.outboxItems.isEmpty || !model.draftItems.isEmpty {
                    Label("Outbox", systemImage: "paperplane")
                        .badge(model.outboxItems.count)
                        .tag(SidebarItem.outbox)
                }
            }

            // Categories (built-in and yours) are the tabs above the Inbox list, not sidebar rows.
            SmartFolderSection()

            ForEach(model.accounts) { account in
                Section(model.accounts.count > 1 ? account.displayName : String(localized: "Folders")) {
                    ForEach(folders(for: account.id), id: \.path) { box in
                        folderRow(box, accountID: account.id)
                    }
                }
            }

            if !Platform.isMac {
                // iPhone and iPad: Rules here as well as in the More menu (the Mac has it in the
                // menu bar and ⌘K).
                Section {
                    Button { model.isRulesShown = true } label: {
                        // Looks like the rows above: tinted icon, plain title.
                        Label {
                            Text("Rules").foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }

            // Sync status: a small centred line under the last section that scrolls with the
            // list (as a pinned bar it floated over the rows).
            SidebarStatus()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
        .listStyle(.sidebar)
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
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension AppModel {
    /// Resolves dragged conversations to the ones currently loaded.
    func threads(for drags: [ThreadDrag]) -> [ThreadSummary] {
        let ids = Set(drags.map(\.threadID))
        return threads.filter { ids.contains($0.threadID) }
    }
}
