import MailEngine
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Called on every pick, even of the current place (iPhone uses it to go to the list).
    var didPick: (() -> Void)? = nil

    var body: some View {
        @Bindable var model = model
        // One Inbox row stands for All and every category tab: it stays selected while any of
        // them shows, and picking it opens Primary.
        // With more than one account, each has its own Inbox row under it (a filter on the same
        // Inbox, tabs and all); the unified Inbox stays the default.
        let selection = Binding<SidebarItem?>(
            get: {
                guard model.isInInbox else { return model.selection }
                return model.inboxAccountID.map(SidebarItem.accountInbox) ?? .inbox
            },
            set: { picked in
                guard let picked else { return }
                switch picked {
                case .inbox: if !model.isInInbox || model.inboxAccountID != nil { model.goToInbox() }
                case .accountInbox(let id): model.goToInbox(account: id)
                default: model.selection = picked
                }
                didPick?()
            })
        List(selection: selection) {
            Section {
                // `.tag` must be the outermost modifier, or the row can't be selected.
                Label(model.accounts.count > 1 ? "All Inboxes" : "Inbox", systemImage: "tray")
                    .badge(model.inboxUnreadCount)
                    .tag(SidebarItem.inbox)
                if model.accounts.count > 1 {
                    // Ids of their own: the folder sections below also go by account, and rows
                    // sharing an id in one List make SwiftUI drop one of them.
                    ForEach(model.accounts, id: \.inboxRowID) { account in
                        Label(account.displayName, systemImage: account.isICloud ? "icloud" : "tray")
                            .padding(.leading, Platform.isMac ? 14 : 0)
                            .badge(model.accountUnreadCounts[account.id] ?? 0)
                            .help(account.endpoint.username)
                            .tag(SidebarItem.accountInbox(account.id))
                    }
                }
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

            ForEach(model.accounts, id: \.foldersSectionID) { account in
                // A view of its own, so the folder tree (sorted, and read with the account's
                // folder layout from the store) is rebuilt when folders change, not on every
                // unread-count, selection or outbox change the rows above follow.
                AccountFoldersSection(accountID: account.id, title: model.accounts.count > 1 ? account.displayName : String(localized: "Folders"))
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
}

/// One account's folders in the sidebar, under a header with New Folder.
struct AccountFoldersSection: View {
    @Environment(AppModel.self) private var model
    let accountID: String
    let title: String

    var body: some View {
        Section {
            ForEach(model.folderRows(accountID: accountID)) { row in
                folderRow(row, accountID: accountID)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button("New Folder…", systemImage: "plus") { model.newFolder(accountID: accountID) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New Folder…")
            }
            .contextMenu {
                Button("New Folder…", systemImage: "folder.badge.plus") { model.newFolder(accountID: accountID) }
            }
            // Dropped on the header: to the top level.
            .dropDestination(for: FolderDrag.self) { items, _ in
                guard let item = items.first else { return false }
                return model.dropFolder(item, into: nil, accountID: accountID)
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ row: FolderRow, accountID: String) -> some View {
        let box = row.box
        let label = Label(row.name, systemImage: box.role?.symbol ?? "folder")
            .padding(.leading, CGFloat(row.depth) * 14)
            .contextMenu { FolderContextMenu(box: box) }
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
        } else if box.role == nil, !Platform.isPhone {
            // Drag a folder onto another to put it inside (the iPhone has Move To… instead).
            label
                .draggable(FolderDrag(accountID: accountID, path: box.path)) {
                    Label(row.name, systemImage: "folder").padding(8).glassEffect(.regular, in: .capsule)
                }
                .dropDestination(for: FolderDrag.self) { items, _ in
                    guard let item = items.first else { return false }
                    return model.dropFolder(item, into: box.path, accountID: accountID)
                }
                .tag(SidebarItem.mailbox(accountID: accountID, path: box.path))
        } else {
            label.tag(SidebarItem.mailbox(accountID: accountID, path: box.path))
        }
    }
}

/// What a dragged folder carries. JSON, so a conversation drop (plain data) never takes it.
struct FolderDrag: Codable, Transferable {
    var accountID: String
    var path: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
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

private extension AccountConfig {
    var inboxRowID: String { "inbox:\(id)" }
    var foldersSectionID: String { "folders:\(id)" }
}
