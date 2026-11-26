import MailEngine
import SwiftUI

/// Any IMAP/SMTP account. Typing the address fills in the servers: built in for common
/// providers, else the domain's autoconfig or Thunderbird's database (only the domain is sent),
/// else a guess (imap./smtp.<domain>). Changing a server field yourself stops the filling in.
struct OtherAccountForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The address is iCloud's: switch to the iCloud setup with it.
    var useICloud: (String) -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var password = ""

    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var imapUser = ""
    @State private var imapTLS = true
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var smtpUser = ""
    @State private var smtpSecurity: SMTPEndpoint.Security = .startTLS

    /// Where the filled-in settings came from, and anything to know about the provider.
    @State private var source: String?
    @State private var note: MailProvider.Note?
    @State private var isLookingUp = false
    /// You changed a server field: the address no longer fills them in.
    @State private var edited = false
    @State private var lookup: Task<Void, Never>?
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                field("Name", text: $name, prompt: Text("Work"))
                field("Email address", text: $address, prompt: Text(verbatim: "you@example.com"), kind: .email)
                Group {
                    #if os(iOS)
                    LabeledContent("Password") {
                        SecureField("Password", text: $password).multilineTextAlignment(.trailing)
                    }
                    #else
                    SecureField("Password", text: $password)
                    #endif
                }
                .textContentType(.password)
                .onSubmit { Task { await connect() } }
            } footer: {
                providerFooter
            }

            Section {
                field("Server", text: edit($imapHost), prompt: Text(verbatim: "imap.example.com"), kind: .host)
                field("Port", text: edit($imapPort), kind: .number)
                field("Username", text: edit($imapUser), kind: .host)
                Picker("Security", selection: edit($imapTLS)) {
                    Text("SSL/TLS").tag(true)
                    Text("None").tag(false)
                }
                .onChange(of: imapTLS) { _, tls in
                    if tls, imapPort == "143" { imapPort = "993" } else if !tls, imapPort == "993" { imapPort = "143" }
                }
            } header: {
                Text("Incoming Mail (IMAP)")
            } footer: {
                Text("Tidings connects to IMAP with SSL/TLS (usually port 993). STARTTLS for incoming mail isn't supported yet. No encryption only works for a server on this device.")
            }

            Section {
                field("Server", text: edit($smtpHost), prompt: Text(verbatim: "smtp.example.com"), kind: .host)
                field("Port", text: edit($smtpPort), kind: .number)
                field("Username", text: edit($smtpUser), kind: .host)
                Picker("Security", selection: edit($smtpSecurity)) {
                    Text("SSL/TLS").tag(SMTPEndpoint.Security.tls)
                    Text("STARTTLS").tag(SMTPEndpoint.Security.startTLS)
                    Text("None").tag(SMTPEndpoint.Security.none)
                }
                .onChange(of: smtpSecurity) { _, security in
                    if security == .tls, smtpPort == "587" { smtpPort = "465" }
                    if security == .startTLS, smtpPort == "465" { smtpPort = "587" }
                }
            } header: {
                Text("Outgoing Mail (SMTP)")
            } footer: {
                Text("The same password is used for both servers. It's kept in your Keychain.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.isDevServer {
                Section {
                    Button("Fill In Local Test Server") { fillInTestServer() }
                } footer: {
                    Text(verbatim: "Dev copy: a second account on the local Dovecot (user \"work\") with Mailpit for sending.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: address) { _, new in addressChanged(new) }
        .sheetButtons {
            if !model.needsAccountSetup {
                Button("Cancel") { model.isAddingAccount = false; dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        } trailing: {
            if isConnecting || isLookingUp { ProgressView().controlSize(.small) }
            Button("Connect") { Task { await connect() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
        }
    }

    @ViewBuilder private var providerFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source {
                Text("Server settings from \(source).")
            }
            switch note {
            case .appPassword:
                Text("This provider wants an app password: make one in its security settings and use it here.")
            case .oauthOnly:
                Text("This provider may only let other mail apps in with its own sign-in, which Tidings doesn't support yet. An app password may still work.")
            case .iCloud:
                HStack {
                    Text("This is an iCloud address.")
                    Button("Use iCloud Setup") { useICloud(address) }
                        .buttonStyle(.borderless)
                }
            case nil:
                EmptyView()
            }
        }
    }

    enum FieldKind { case text, email, host, number }

    /// A labeled field: the Mac's grouped form shows the label beside it already; on iPhone the
    /// label goes on the left and the text on the right, as in the system's Mail settings.
    @ViewBuilder
    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil, kind: FieldKind = .text) -> some View {
        let input = TextField(title, text: text, prompt: prompt)
            .autocorrectionDisabled(kind != .text)
            #if os(iOS)
            .textInputAutocapitalization(kind == .text ? .words : .never)
            .keyboardType(kind == .email ? .emailAddress : kind == .number ? .numberPad : kind == .host ? .URL : .default)
            #endif
        #if os(iOS)
        LabeledContent(title) { input.multilineTextAlignment(.trailing) }
        #else
        input
        #endif
    }

    /// A binding that marks the servers as yours when you change them.
    private func edit<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; edited = true })
    }

    private var isLocal: (String) -> Bool {
        { host in ["127.0.0.1", "localhost", "::1"].contains(host.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    private var canConnect: Bool {
        !isConnecting && MailProvider.domain(of: address) != nil && !password.isEmpty
            && !imapHost.trimmingCharacters(in: .whitespaces).isEmpty && UInt16(imapPort) != nil && !imapUser.isEmpty
            && !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty && Int(smtpPort) != nil && !smtpUser.isEmpty
            && (imapTLS || isLocal(imapHost)) && (smtpSecurity != .none || isLocal(smtpHost))
    }

    // MARK: Filling in

    private func addressChanged(_ new: String) {
        lookup?.cancel()
        guard !edited else { return }
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard MailProvider.domain(of: trimmed) != nil else { return }
        // At once: a guess, so the form is never empty; then the real settings when found.
        if let builtIn = MailProvider.builtIn(for: trimmed) {
            apply(builtIn)
            return
        }
        if let guess = MailProvider.guess(for: trimmed) { apply(guess, source: .some(nil)) }
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isLookingUp = true
            let found = await MailProvider.lookUp(trimmed)
            isLookingUp = false
            guard !Task.isCancelled, !edited, address.trimmingCharacters(in: .whitespaces) == trimmed, let found else { return }
            apply(found)
        }
    }

    private func apply(_ settings: MailServerSettings, source: String?? = .none) {
        imapHost = settings.imap.host
        imapPort = String(settings.imap.port)
        imapUser = settings.imap.username
        imapTLS = settings.imap.useTLS
        smtpHost = settings.smtp.host
        smtpPort = String(settings.smtp.port)
        smtpUser = settings.smtp.username
        smtpSecurity = settings.smtp.security
        switch source {
        case .none: self.source = settings.source
        case .some(let given): self.source = given
        }
        note = settings.note
    }

    private func fillInTestServer() {
        name = "Work"
        address = TestMailFactory.work.address
        password = "tidings-test"
        lookup?.cancel()
        imapHost = "127.0.0.1"; imapPort = "31143"; imapUser = "work"; imapTLS = false
        smtpHost = "127.0.0.1"; smtpPort = "31587"; smtpUser = TestMailFactory.work.address; smtpSecurity = .startTLS
        source = nil
        note = nil
        edited = true
    }

    // MARK: Connecting

    private func connect() async {
        guard canConnect, let imapPort = UInt16(imapPort), let smtpPort = Int(smtpPort) else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        let settings = MailServerSettings(
            imap: IMAPEndpoint(host: imapHost.trimmingCharacters(in: .whitespaces).lowercased(), port: imapPort,
                               useTLS: imapTLS, username: imapUser.trimmingCharacters(in: .whitespaces)),
            smtp: SMTPEndpoint(host: smtpHost.trimmingCharacters(in: .whitespaces).lowercased(), port: smtpPort,
                               security: smtpSecurity, username: smtpUser.trimmingCharacters(in: .whitespaces)),
            source: source ?? "")
        do {
            try await model.addAccount(name: name, address: address, settings: settings, password: password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
