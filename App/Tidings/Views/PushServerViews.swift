import MailEngine
import SwiftUI

/// Settings › Notifications › Push Server (ADR 0007): pair this device with your own server,
/// give it each account's app-specific password, see whether it's connected.
struct PushServerSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var secret = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Section {
            if model.isPushServerPaired, let pairing = model.pushServerPairing {
                LabeledContent("Server", value: pairing.url.host() ?? pairing.url.absoluteString)
                if let status = model.pushServerStatus {
                    if !status.pushConfigured {
                        Label("The server has no Apple push key yet, so it can't notify.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(model.accounts.filter { $0.id != "dev" || model.isDevServer }) { account in
                        accountRow(account, status: status.accounts.first { $0.login == account.login.lowercased() })
                    }
                }
                if let message = model.pushServerError ?? error {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Refresh") { Task { await model.refreshPushServerStatus() } }
                    Spacer()
                    Button("Unpair…", role: .destructive) { model.isConfirmingPushUnpair = true }
                }
            } else {
                TextField("Server address", text: $address, prompt: Text(verbatim: "https://push.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Pairing secret", text: $secret)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button(isWorking ? "Pairing…" : "Pair This Device") { pair() }
                    .disabled(isWorking || !(URL(string: address.trimmingCharacters(in: .whitespaces)).map(PushServerClient.isAllowed) ?? false) || secret.count < 16)
            }
        } header: {
            Text("Push Server")
        } footer: {
            Text("Your own always-on server notifies this iPhone about new mail, wakes snoozes and sends mail you scheduled, even when no device is awake. Each account needs a separate app-specific password for the server, so you can revoke it without touching your devices.")
        }
    }

    private func accountRow(_ account: AccountConfig, status: PushAPI.AccountStatus?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(account.displayName)
                Text(statusText(status)).font(.caption).foregroundStyle(status?.state == "failed" ? .red : .secondary)
            }
            Spacer()
            Button(status?.hasPassword == true ? "Change Password…" : "Add Password…") { model.pushPasswordAccount = account }
        }
    }

    private func statusText(_ status: PushAPI.AccountStatus?) -> String {
        guard let status, status.hasPassword else { return String(localized: "Not on the server yet") }
        switch status.state {
        case "idle": return String(localized: "Watching for new mail")
        case "failed": return String(localized: "Can't connect: \(status.error ?? "")")
        default: return String(localized: "Connecting…")
        }
    }

    private func pair() {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text) else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await model.pairPushServer(url: url, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
                secret = ""
            } catch {
                self.error = AppModel.describe(error)
            }
            isWorking = false
        }
    }
}

/// The server's own app-specific password for one account. It goes to the server only, never
/// into this device's Keychain.
struct PushServerPasswordSheet: View {
    let account: AccountConfig
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("App-specific password", text: $password)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text("Make a new one named “Tidings Push” at account.apple.com › Sign-In and Security › App-Specific Passwords. It's encrypted on the server and never sent back.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Push Server Password for \(account.displayName)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 220)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await model.setPushServerPassword(password.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
                dismiss()
            } catch {
                self.error = AppModel.describe(error)
            }
            isSaving = false
        }
    }
}

/// ⌘K "Push Server…": the same section over the main window.
struct PushServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { PushServerSection() }
                .formStyle(.grouped)
                .modifier(PushServerPresentations())
                .navigationTitle("Push Server")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

/// The push server section's sheet, dialog and status refresh. Applied to the whole settings
/// page, not the section: the section's rows are rebuilt as the list updates, and a sheet hung
/// on them closes on its own (iPhone).
struct PushServerPresentations: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .task { if model.isPushServerPaired { await model.refreshPushServerStatus() } }
            .sheet(item: $model.pushPasswordAccount) { account in
                PushServerPasswordSheet(account: account).environment(model)
            }
            .confirmationDialog("Unpair from the push server?", isPresented: $model.isConfirmingPushUnpair) {
                Button("Unpair This Device", role: .destructive) { Task { await model.unpairPushServer(everywhere: false) } }
                Button("Unpair All Devices", role: .destructive) { Task { await model.unpairPushServer(everywhere: true) } }
            } message: {
                Text("Mail you scheduled goes back to this device. The server keeps your accounts until you remove them there.")
            }
    }
}
