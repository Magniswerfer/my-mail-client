import MailEngine
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.selection = s } })) {
            Section {
                Label("Inbox", systemImage: "tray")
                    .tag(SidebarItem.inbox)
                    .badge(model.threads.isEmpty ? 0 : inboxUnread)
                Label("Snoozed", systemImage: "clock")
                    .tag(SidebarItem.snoozed)
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

    private var inboxUnread: Int {
        model.threads.filter { $0.latest.category == .primary }.reduce(0) { $0 + $1.unreadCount }
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

    private func displayName(_ box: MailboxState) -> String {
        switch box.role {
        case .sent: String(localized: "Sent")
        case .drafts: String(localized: "Drafts")
        case .archive: String(localized: "Archive")
        case .trash: String(localized: "Trash")
        case .junk: String(localized: "Junk")
        default: box.path
        }
    }
}
