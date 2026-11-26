import MailEngine
import SwiftUI

/// Settings → Notifications: what's worth interrupting you for, and your VIPs (SPEC §10).
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newVIP = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Notify me about new mail", isOn: $model.notificationPolicy.isEnabled)
                    .onChange(of: model.notificationPolicy.isEnabled) { _, on in
                        if on { Task { _ = await model.notifier.authorize() } }
                    }
            } footer: {
                Text("Never for bundles. Mail that arrives while you're away is gathered into one notification.")
            }
            Section("Notify me about") {
                Toggle("Primary mail from people", isOn: $model.notificationPolicy.people)
                Toggle("Only from VIPs", isOn: $model.notificationPolicy.onlyVIPs)
                    .disabled(!model.notificationPolicy.people)
                    .padding(.leading, 18)
                Toggle("Pinned conversations", isOn: $model.notificationPolicy.pinned)
                Toggle("Replies when you're waiting for one", isOn: $model.notificationPolicy.replies)
                Toggle("Rules that say “Notify me”", isOn: $model.notificationPolicy.rules)
            }
            .disabled(!model.notificationPolicy.isEnabled)
            Section {
                ForEach(model.notificationPolicy.vips, id: \.self) { address in
                    HStack {
                        Text(address)
                        Spacer()
                        Button { model.notificationPolicy.vips.removeAll { $0 == address } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
                HStack {
                    TextField("Add an address", text: $newVIP)
                        .onSubmit(addVIP)
                    Button("Add", action: addVIP).disabled(!newVIP.contains("@"))
                }
                Button("Suggest from Who You Write To") { suggestVIPs() }
            } header: {
                Text("VIPs")
            } footer: {
                Text("VIPs' Primary mail always notifies. With “Only from VIPs”, other people's doesn't.")
            }
            PushServerSection()
        }
        .formStyle(.grouped)
    }

    private func addVIP() {
        let address = newVIP.trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@"), !model.notificationPolicy.vips.contains(address) else { return }
        model.notificationPolicy.vips.append(address)
        newVIP = ""
    }

    private func suggestVIPs() {
        let suggested = (try? model.store.frequentCorrespondents(ownAddresses: model.ownAddresses)) ?? []
        for address in suggested.map({ $0.address.lowercased() }) where !model.notificationPolicy.vips.contains(address) {
            model.notificationPolicy.vips.append(address)
        }
    }
}
