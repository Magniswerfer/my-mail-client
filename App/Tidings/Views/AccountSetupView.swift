import MailEngine
import SwiftUI

/// Onboarding (SPEC §16): iCloud address + app-specific password, validated live before saving.
struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add your iCloud Mail account", systemImage: "envelope.badge.person.crop")
                .font(.title2.weight(.semibold))

            Text("Tidings connects directly to iCloud over IMAP. Your mail stays on this Mac and with Apple.")
                .foregroundStyle(.secondary)

            Form {
                TextField("iCloud address", text: $address, prompt: Text(verbatim: "name@icloud.com"))
                    .textContentType(.username)
                SecureField("App-specific password", text: $password, prompt: Text(verbatim: "xxxx-xxxx-xxxx-xxxx"))
                    .textContentType(.password)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Text("Use your primary @icloud.com address, not a custom-domain address. You can send from custom domains later.")
                Link("Create an app-specific password at account.apple.com →",
                     destination: URL(string: "https://account.apple.com/account/manage")!)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting || !address.contains("@") || password.count < 16)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.addAccount(address: address, password: password.trimmingCharacters(in: .whitespaces))
        } catch let e as MailSessionError {
            if case .authenticationFailed = e {
                error = String(localized: "iCloud rejected the login. Check that the address is your @icloud.com address and the password is an app-specific password.")
            } else {
                error = e.description
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    LabeledContent(account.displayName, value: account.endpoint.host)
                }
            }
            Section("Storage") {
                LabeledContent("Location") {
                    Text(model.dataDirectory.path).textSelection(.enabled).font(.caption)
                }
                LabeledContent("Messages", value: "\((try? model.store.count()) ?? 0)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 300)
    }
}
