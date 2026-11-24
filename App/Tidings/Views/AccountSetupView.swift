import MailEngine
import AppKit
import SwiftUI

/// Onboarding (SPEC §16). iCloud has no third-party OAuth (docs/research/icloud-imap.md), so an
/// app-specific password is the only way in; this makes that a two-click step:
/// open Apple's page → generate → come back and press Paste. A valid password connects at once.
struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var openedApple = false
    @State private var error: String?

    static let appleURL = URL(string: "https://account.apple.com/account/manage/section/security")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add your iCloud Mail account", systemImage: "envelope.badge.person.crop")
                .font(.title2.weight(.semibold))
            Text("Apple doesn't offer \"Sign in with Apple\" to mail apps other than its own, so iCloud asks for an app-specific password. It only takes a moment, and you can revoke it anytime.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("iCloud address", text: $address, prompt: Text(verbatim: "name@icloud.com"))
                .textContentType(.username)
                .textFieldStyle(.roundedBorder)

            step(1, done: openedApple, title: "Create a password at Apple",
                 detail: "Sign-In and Security → App-Specific Passwords → +. Name it \"Tidings\", then copy it.") {
                Button("Open account.apple.com") {
                    openURL(Self.appleURL)
                    openedApple = true
                }
                .buttonStyle(.glass)
            }

            step(2, done: AppPassword.isValid(password), title: "Paste it here",
                 detail: "Tidings only reads the clipboard when you press Paste.") {
                HStack {
                    SecureField("App-specific password", text: $password, prompt: Text(verbatim: "xxxx-xxxx-xxxx-xxxx"))
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await connect() } }
                    Button("Paste") { paste() }
                        .buttonStyle(.glass)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Use your primary @icloud.com address. Custom-domain addresses come later as sending identities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting || !address.contains("@") || !AppPassword.isValid(password))
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(_ n: Int, done: Bool, title: LocalizedStringKey, detail: LocalizedStringKey,
                      @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            error = String(localized: "The clipboard is empty. Copy the password at account.apple.com first.")
            return
        }
        guard let normalized = AppPassword.normalize(text) else {
            error = String(localized: "That doesn't look like an app-specific password (four groups of four letters).")
            return
        }
        error = nil
        password = normalized
        if address.contains("@") { Task { await connect() } }
    }

    private func connect() async {
        guard !isConnecting, AppPassword.isValid(password) else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.addAccount(address: address, password: password)
        } catch let e as MailSessionError {
            if case .authenticationFailed = e {
                error = String(localized: "iCloud rejected the login. Check that the address is your @icloud.com address and the password is a fresh app-specific password.")
            } else {
                error = e.description
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Apple's app-specific password format: four groups of four lowercase letters.
enum AppPassword {
    static func normalize(_ raw: String) -> String? {
        let letters = raw.lowercased().filter(\.isLetter)
        guard letters.count == 16, letters.allSatisfy({ $0.isASCII }) else { return nil }
        let chars = Array(letters)
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func isValid(_ s: String) -> Bool { normalize(s) == s }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Identities", systemImage: "person.crop.rectangle.stack") { IdentitiesSettings() }
            Tab("Bundles", systemImage: "square.stack.3d.up") { BundleSettings() }
            Tab("General", systemImage: "gearshape") {
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
            }
        }
        .frame(width: 560, height: 440)
    }
}

/// Sending identities (SPEC §9): the iCloud address plus custom-domain addresses, each with a
/// name and signature. Sending from a custom domain works when it's set up in iCloud+.
struct IdentitiesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newAddress = ""

    var body: some View {
        Form {
            ForEach(model.accounts) { account in
                Section(account.displayName) {
                    ForEach(account.sendingIdentities) { identity in
                        IdentityEditor(accountID: account.id, identity: identity)
                    }
                    HStack {
                        TextField("Add address", text: $newAddress, prompt: Text(verbatim: "you@your-domain.com"))
                        Button("Add") {
                            model.addIdentity(address: newAddress, accountID: account.id)
                            newAddress = ""
                        }
                        .disabled(!newAddress.contains("@"))
                    }
                    Text("Custom-domain addresses must be set up in iCloud+ (Settings → Apple Account → iCloud → Custom Email Domain).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct IdentityEditor: View {
    @Environment(AppModel.self) private var model
    let accountID: String
    @State var identity: Identity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(identity.address).font(.headline)
                Spacer()
                Button(role: .destructive) { model.removeIdentity(identity, accountID: accountID) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(model.identities(for: accountID).count <= 1)
            }
            TextField("Name", text: $identity.name)
            TextField("Signature", text: $identity.signature, axis: .vertical)
                .lineLimit(2...5)
        }
        .padding(.vertical, 4)
        .onChange(of: identity) { model.updateIdentity(identity, accountID: accountID) }
    }
}

/// When each bundle arrives (SPEC §4).
struct BundleSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(MailCategory.allCases.filter { $0 != .primary }, id: \.self) { category in
                    BundleScheduleRow(category: category)
                }
            } footer: {
                Text("Scheduled bundles gather mail and arrive in the Inbox once a day. Opening a bundle in the sidebar always shows everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct BundleScheduleRow: View {
    @Environment(AppModel.self) private var model
    let category: MailCategory

    var body: some View {
        let schedule = model.bundleSchedules[category] ?? .immediately
        HStack {
            Label { Text(category.title) } icon: { Image(systemName: category.symbol).foregroundStyle(category.tint) }
            Spacer()
            Picker("", selection: Binding(
                get: { if case .daily = schedule { 1 } else { 0 } },
                set: { $0 == 0 ? model.setSchedule(.immediately, for: category) : model.setSchedule(.daily(hour: 17, minute: 0), for: category) }
            )) {
                Text("As it arrives").tag(0)
                Text("Once a day").tag(1)
            }
            .labelsHidden()
            .fixedSize()
            if case .daily(let hour, let minute) = schedule {
                DatePicker("", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())! },
                    set: { date in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                        model.setSchedule(.daily(hour: c.hour ?? 17, minute: c.minute ?? 0), for: category)
                    }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
