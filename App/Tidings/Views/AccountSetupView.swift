import MailEngine
import SwiftUI

/// Adding an account: iCloud (an app-specific password, SPEC §16) or any IMAP/SMTP server.
/// Shown by itself while there are none, and from Settings › General and ⌘K to add another.
struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeAccountSetup) private var closeAccountSetup
    enum Kind: Hashable { case iCloud, other }
    @State private var kind: Kind = .iCloud
    /// An iCloud address typed in the other form, carried over by "Use iCloud Setup".
    @State private var iCloudAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Account type", selection: $kind) {
                Text("iCloud").tag(Kind.iCloud)
                Text("Other Mail Account").tag(Kind.other)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Platform.isMac ? 24 : 16)
            .padding(.top, Platform.isMac ? 20 : 8)
            switch kind {
            case .iCloud:
                ScrollView {
                    ICloudAccountForm(address: iCloudAddress, showsCancel: !model.needsAccountSetup && Platform.isMac)
                        .id(iCloudAddress)
                }
                .scrollBounceBehavior(.basedOnSize)
            case .other:
                OtherAccountForm(useICloud: { address in
                    iCloudAddress = address
                    kind = .iCloud
                })
            }
        }
        .macFrame(width: 540, height: kind == .other ? 640 : 470)
        .navigationTitle("Add Account")
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            #if os(iOS)
            if !model.needsAccountSetup, kind == .iCloud {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { closeSetup() }
                }
            }
            #endif
        }
    }
}

/// Onboarding (SPEC §16). iCloud has no third-party OAuth (docs/research/icloud-imap.md), so an
/// app-specific password is the only way in; this makes that a two-click step:
/// open Apple's page → generate → come back and press Paste. A valid password connects at once.
struct ICloudAccountForm: View {
    @Environment(\.closeAccountSetup) private var closeAccountSetup
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State var address = ""
    /// Adding another account (not the first): Cancel shows.
    var showsCancel = false
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
                if showsCancel {
                    Button("Cancel") { closeSetup() }
                        .keyboardShortcut(.cancelAction)
                }
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
        guard let text = Platform.clipboardString() else {
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
            closeSetup()
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

    /// Every pane, in order: the Mac's tabs and the iPhone's list are the same panes.
    enum Pane: String, CaseIterable, Identifiable {
        case identities, bundles, rules, assistant, notifications, snippets, general
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .identities: "Identities"
            case .bundles: "Bundles"
            case .rules: "Rules"
            case .assistant: "Assistant"
            case .notifications: "Notifications"
            case .snippets: "Snippets"
            case .general: "General"
            }
        }

        var symbol: String {
            switch self {
            case .identities: "person.crop.rectangle.stack"
            case .bundles: "square.stack.3d.up"
            case .rules: "line.3.horizontal.decrease.circle"
            case .assistant: "sparkles"
            case .notifications: "bell.badge"
            case .snippets: "text.badge.plus"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        if Platform.isMac {
            TabView {
                ForEach(Pane.allCases) { pane in
                    Tab(pane.title, systemImage: pane.symbol) { content(pane) }
                }
            }
            .macFrame(width: 560, height: 440)
        } else {
            // iPhone and iPad: a list of panes, as in the system's Settings (seven tabs would
            // spill into a More tab).
            List(Pane.allCases) { pane in
                NavigationLink {
                    content(pane)
                        .navigationTitle(pane.title)
                        .navigationBarTitleDisplayModeInline()
                } label: {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
        }
    }

    @ViewBuilder private func content(_ pane: Pane) -> some View {
        switch pane {
        case .identities: IdentitiesSettings()
        case .bundles: BundleSettings()
        case .rules: RulesView(inSettings: true)
        case .assistant: AssistantSettings()
        case .notifications: NotificationSettings()
        case .snippets: SnippetsSettings()
        case .general: GeneralSettings()
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.filterJunkKey) private var filterJunk = true
    /// Here, not on the main window: on the Mac Settings is a window of its own.
    @State private var isAdding = false
    @State private var removing: AccountConfig?
    /// An account from another device that needs its password typed here.
    @State private var signingIn: AccountConfig?

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts) { account in
                    AccountRow(account: account) { removing = account }
                }
                .onDelete { offsets in removing = offsets.first.map { model.accounts[$0] } }
                ForEach(model.accountsAwaitingPassword) { account in
                    AwaitingAccountRow(account: account, signIn: { signingIn = account }, remove: { removing = account })
                }
                Button("Add Account…") { isAdding = true }
            } header: {
                Text("Accounts")
            } footer: {
                if model.syncsAccountsThroughICloud {
                    Text("Accounts sync through iCloud, with their passwords in iCloud Keychain, so your other devices set them up too. Removing one removes it from all of them. The mail stays on the server.")
                } else {
                    Text("Removing an account deletes its mail, settings and password from this device. Nothing changes on the mail server or on your other devices.")
                }
            }
            Section {
                Toggle("Reader Mode for Every Message", isOn: Binding(get: { model.readerMode },
                                                                      set: { model.readerMode = $0 }))
            } header: {
                Text("Reading")
            } footer: {
                Text("Shows mail as clean text instead of its own layout. Read Later always opens this way.")
            }
            Section {
                Toggle("Filter Junk", isOn: $filterJunk)
            } header: {
                Text("Junk")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tidings learns from what's in Junk, from mail you move there, and from mail you move back out. New mail that's almost certainly junk goes to Junk; likely junk gets a warning. Mail from people you've written to is never moved.")
                    if let totals = try? model.store.junkTotals() {
                        Text("Learned from \(totals.spam) junk and \(totals.ham) other messages.")
                    }
                }
            }
            #if os(macOS)
            BackgroundSettingsSection()
            #endif
            Section("Storage") {
                LabeledContent("Location") {
                    Text(model.dataDirectory.path).textSelection(.enabled).font(.caption)
                }
                LabeledContent("Messages", value: "\((try? model.store.count()) ?? 0)")
            }
            Section {
                Toggle("Sync with iCloud", isOn: Binding(get: { model.isCloudSyncEnabled },
                                                         set: { model.isCloudSyncEnabled = $0 }))
                LabeledContent("Status", value: model.cloudStatusText)
            } header: {
                Text("iCloud")
            } footer: {
                Text("Rules, smart folders, sender rules, Reply Later, Read Later, snoozes, mutes and settings, in your private iCloud. Never your mail.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $signingIn) { account in
            AccountPasswordSheet(account: account).environment(model)
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack { AccountSetupView() }
                .environment(\.closeAccountSetup, { isAdding = false })
                .environment(model)
        }
        .modifier(AccountRemovalConfirmation(account: $removing))
    }
}

/// One account in Settings: what it is, where it connects, and Remove.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isICloud ? "icloud" : "envelope")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                Text(verbatim: account.isICloud ? account.endpoint.username
                                                : "\(account.endpoint.username) · \(account.endpoint.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = model.syncStatus[account.id] {
                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if Platform.isMac {
                Button("Remove…", role: .destructive, action: remove)
            }
        }
        .contextMenu {
            Button("Remove Account…", systemImage: "minus.circle", role: .destructive, action: remove)
        }
    }
}

/// "Remove this account?" before anything is deleted.
/// An account another device added, still waiting for its password on this one.
struct AwaitingAccountRow: View {
    let account: AccountConfig
    var signIn: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                Text("From your other devices · waiting for its password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Enter Password…", action: signIn)
        }
        .contextMenu {
            Button("Enter Password…", systemImage: "key", action: signIn)
            Button("Remove Account…", systemImage: "minus.circle", role: .destructive, action: remove)
        }
        .swipeActions {
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

/// Signs in to an account that came from another device. Usually not needed: iCloud Keychain
/// brings the password along, and the account joins by itself.
struct AccountPasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: AccountConfig
    @State private var password = ""
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Account", value: account.displayName)
                    LabeledContent("Login", value: account.login)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                } footer: {
                    Text(account.isICloud
                         ? String(localized: "An app-specific password from account.apple.com. It's kept in iCloud Keychain.")
                         : String(localized: "It's kept in iCloud Keychain, so your other devices have it too."))
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In")
            .sheetButtons {
                Button("Cancel") { dismiss() }
            } trailing: {
                if isChecking { ProgressView().controlSize(.small) }
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isChecking)
            }
        }
        .macFrame(width: 420)
    }

    private func signIn() {
        guard !password.isEmpty, !isChecking else { return }
        isChecking = true
        error = nil
        Task {
            do {
                try await model.completeAccount(account, password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isChecking = false
        }
    }
}

struct AccountRemovalConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var account: AccountConfig?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            account.map { String(localized: "Remove \($0.displayName)?") } ?? "",
            isPresented: Binding(get: { account != nil }, set: { if !$0 { account = nil } }),
            titleVisibility: .visible, presenting: account
        ) { account in
            Button("Remove Account", role: .destructive) { model.removeAccount(account) }
            Button("Cancel", role: .cancel) { self.account = nil }
        } message: { _ in
            if model.syncsAccountsThroughICloud {
                Text("It's removed from all your devices, with its mail, drafts, outbox and password there. The mail stays on the server.")
            } else {
                Text("Its mail, drafts, outbox and password are deleted from this device. The mail stays on the server, and your other devices keep the account.")
            }
        }
    }
}

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
        if Platform.isMac {
            HStack {
                label
                Spacer()
                schedulePicker.labelsHidden().fixedSize()
                if isDaily { timePicker.labelsHidden().fixedSize() }
            }
        } else {
            // iPhone and iPad: the system's own row (name left, choice right) and the time on a
            // row of its own, so the name never gets squeezed.
            schedulePicker
            if isDaily {
                timePicker.padding(.leading, 40)
            }
        }
    }

    private var schedule: BundleSchedule { model.bundleSchedules[category] ?? .immediately }

    private var isDaily: Bool { if case .daily = schedule { true } else { false } }

    private var label: some View {
        Label { Text(category.title) } icon: { Image(systemName: category.symbol).foregroundStyle(category.tint) }
    }

    private var schedulePicker: some View {
        Picker(selection: Binding(
            get: { isDaily ? 1 : 0 },
            set: { $0 == 0 ? model.setSchedule(.immediately, for: category) : model.setSchedule(.daily(hour: 17, minute: 0), for: category) }
        )) {
            Text("As it arrives").tag(0)
            Text("Once a day").tag(1)
        } label: {
            label
        }
    }

    private var timePicker: some View {
        DatePicker("Arrives at", selection: Binding(
            get: {
                guard case .daily(let hour, let minute) = schedule else { return Date() }
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.setSchedule(.daily(hour: c.hour ?? 17, minute: c.minute ?? 0), for: category)
            }
        ), displayedComponents: .hourAndMinute)
    }
}

extension EnvironmentValues {
    /// Closes the add-account sheet. Settings (a window of its own on the Mac) presents it from
    /// its own state and sets this; the main window's sheet follows the model's flag.
    @Entry var closeAccountSetup: (@MainActor () -> Void)? = nil
}

extension AccountSetupView {
    func closeSetup() {
        model.isAddingAccount = false
        closeAccountSetup?()
        dismiss()
    }
}

extension ICloudAccountForm {
    func closeSetup() {
        model.isAddingAccount = false
        closeAccountSetup?()
        dismiss()
    }
}

#if os(macOS)
/// Settings › General › In the Background: open at login (without a window) and the menu bar item.
struct BackgroundSettingsSection: View {
    @AppStorage(BackgroundMode.menuBarKey) private var showInMenuBar = false
    @State private var opensAtLogin = BackgroundMode.opensAtLogin
    @State private var needsApproval = BackgroundMode.needsApproval
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle("Open at Login", isOn: Binding(get: { opensAtLogin }, set: { set($0) }))
            if needsApproval {
                LabeledContent("Allow Tidings under Login Items in System Settings.") {
                    Button("Open System Settings") { BackgroundMode.openLoginItemsSettings() }
                }
            }
            Toggle("Show in Menu Bar", isOn: $showInMenuBar)
            if let failure {
                Text(failure).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("In the Background")
        } footer: {
            Text("With its window closed, Tidings keeps checking mail, running rules, bringing back snoozed mail and sending scheduled mail. Opening at login starts it without a window. Quit it (⌘Q) to stop.")
        }
        .onAppear { refresh() }
    }

    private func set(_ on: Bool) {
        do {
            try BackgroundMode.setOpensAtLogin(on)
            failure = nil
        } catch {
            failure = String(localized: "Couldn't change it: \(error.localizedDescription)")
        }
        refresh()
    }

    private func refresh() {
        opensAtLogin = BackgroundMode.opensAtLogin
        needsApproval = BackgroundMode.needsApproval
    }
}
#endif
