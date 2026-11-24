import MailEngine
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.selection = s } })) {
            Section {
                // `.tag` must be the outermost modifier, or the row can't be selected.
                Label("Inbox", systemImage: "tray")
                    .badge(inboxUnread)
                    .tag(SidebarItem.inbox)
                Label("Snoozed", systemImage: "clock")
                    .tag(SidebarItem.snoozed)
                if !model.outboxItems.isEmpty || !model.draftItems.isEmpty {
                    Label("Outbox", systemImage: "paperplane")
                        .badge(model.outboxItems.count)
                        .tag(SidebarItem.outbox)
                }
            }

            Section("Bundles") {
                ForEach(MailCategory.allCases, id: \.self) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.symbol).foregroundStyle(category.tint)
                    }
                    .tag(SidebarItem.category(category))
                }
            }

            ForEach(model.accounts) { account in
                Section(model.accounts.count > 1 ? account.displayName : String(localized: "Folders")) {
                    ForEach(folders(for: account.id), id: \.path) { box in
                        Label(displayName(box), systemImage: box.role?.symbol ?? "folder")
                            .tag(SidebarItem.mailbox(accountID: account.id, path: box.path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Unread Primary conversations in the Inbox, whatever view is showing.
    private var inboxUnread: Int { model.inboxUnreadCount }

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

    private func displayName(_ box: MailboxState) -> String {
        box.role?.title ?? box.path
    }
}
