import MailEngine
import SwiftUI

/// Senders (SPEC §11): who sends you the most mail, with ways to deal with them in bulk.
struct SendersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var senders: [SenderStats] = []
    @State private var filter = ""
    @State private var listsOnly = false
    @State private var period: Period = .ninetyDays
    @State private var selection: SenderStats.ID?

    enum Period: Hashable, CaseIterable {
        case ninetyDays, year, all
        var title: String {
            switch self {
            case .ninetyDays: String(localized: "Last 90 days")
            case .year: String(localized: "Last year")
            case .all: String(localized: "All time")
            }
        }
        var since: Date? {
            switch self {
            case .ninetyDays: Date().addingTimeInterval(-90 * 86_400)
            case .year: Date().addingTimeInterval(-365 * 86_400)
            case .all: nil
            }
        }
    }

    private var shown: [SenderStats] {
        senders.filter { sender in
            (!listsOnly || sender.isList)
                && (filter.isEmpty || sender.address.localizedCaseInsensitiveContains(filter)
                    || (sender.name?.localizedCaseInsensitiveContains(filter) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List(shown, selection: $selection) { sender in
                SenderRow(sender: sender)
                    .tag(sender.id)
                    .contextMenu { actions(for: sender) }
            }
            .overlay {
                if shown.isEmpty { ContentUnavailableView.search(text: filter) }
            }
            .searchable(text: $filter, placement: .toolbar, prompt: Text("Filter senders"))
            .navigationTitle("Senders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Toggle("Lists only", isOn: $listsOnly)
                        .help("Only senders of newsletters and other bulk mail")
                }
            }
        }
        .macFrame(minWidth: 680, minHeight: 520)
        .modifier(UnsubscribeConfirmation(isActive: true))
        .task(id: TaskKey(period: period, revision: model.sendersRevision)) {
            senders = (try? model.store.senderStats(ownAddresses: model.ownAddresses, since: period.since)) ?? []
        }
    }

    struct TaskKey: Hashable { var period: Period; var revision: Int }

    @ViewBuilder private func actions(for sender: SenderStats) -> some View {
        Button("Unsubscribe…", systemImage: "hand.raised") { model.requestUnsubscribe(address: sender.address) }
            .disabled(!sender.isList || sender.unsubscribedAt != nil)
        Button("Mark Their Inbox Mail Done", systemImage: "checkmark.circle") { model.archiveInboxMail(from: sender.address) }
            .disabled(sender.inboxCount == 0)
        Menu("Always Put Them in", systemImage: "tray.and.arrow.down") {
            ForEach(MailCategory.allCases, id: \.self) { category in
                Button(category.title, systemImage: category.symbol) {
                    model.moveSender(to: category, address: sender.address, name: sender.name ?? sender.address)
                    model.sendersRevision &+= 1
                }
            }
        }
        Divider()
        Button("Show Their Mail", systemImage: "magnifyingglass") { model.showMail(from: sender.address) }
    }
}

struct SenderRow: View {
    @Environment(AppModel.self) private var model
    let sender: SenderStats

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: sender.name ?? sender.address, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sender.name ?? sender.address).font(.headline).lineLimit(1)
                    Image(systemName: sender.category.symbol).font(.caption).foregroundStyle(sender.category.tint)
                }
                Text(sender.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(sender.count == 1 ? String(localized: "1 message") : String(localized: "\(sender.count) messages"))
                    .font(.callout.monospacedDigit())
                if sender.inboxCount > 0 {
                    Text(String(localized: "\(sender.inboxCount) in Inbox"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Group {
                if let at = sender.unsubscribedAt {
                    Label(String(localized: "Unsubscribed \(at.formatted(date: .abbreviated, time: .omitted))"), systemImage: "hand.raised.fill")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                } else if sender.isList {
                    Button("Unsubscribe") { model.requestUnsubscribe(address: sender.address) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
