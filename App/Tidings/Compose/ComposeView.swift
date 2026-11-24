import MailEngine
import SwiftUI
import UniformTypeIdentifiers

/// A composer window (one per draft). ⌘↩ sends; ⌘W closes and keeps the draft.
struct ComposeWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draftID: Int64
    @State private var model: ComposeModel?

    var body: some View {
        Group {
            if let model {
                ComposeView(model: model, close: { dismiss() })
            } else {
                ContentUnavailableView("This draft is gone", systemImage: "doc.questionmark",
                                       description: Text("It was sent or discarded in another window."))
            }
        }
        .macFrame(minWidth: 560, minHeight: 420)
        .onAppear { model = model ?? ComposeModel(draftID: draftID, app: app) }
        .onDisappear { model?.saveNow() }
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComposeModel
    let close: () -> Void
    @State private var isImporting = false
    @State private var isSendLaterShown = false
    @State private var isAvailabilityShown = false
    @State private var pendingSend: PendingSend?

    /// A send held back by the pre-send check.
    struct PendingSend: Identifiable {
        let id = UUID()
        var date: Date?
        var markDone: Bool?
        var problems: [SendCheck.Problem]
    }
    @State private var isSending = false
    @FocusState private var focused: Field?

    enum Field { case to, cc, bcc, subject }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RichTextEditor(text: Binding(get: { model.body }, set: { model.body = $0; model.changed() }),
                           focusOnAppear: model.kind != .new && model.kind != .forward,
                           insertion: model.insertion)
                .padding(.horizontal, 12)
            if !model.attachments.isEmpty { attachmentStrip }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(model.subject.isEmpty ? String(localized: "New Message") : model.subject)
        .toolbar { toolbar }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls: urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.attach(urls: [url]) } }
                }
            }
            return true
        }
        .onAppear {
            if model.kind == .new { focused = .to } else if model.kind == .forward { focused = .to }
        }
        .sheet(isPresented: $isSendLaterShown) { sendLaterSheet }
        .confirmationDialog(String(localized: "Send anyway?"), isPresented: Binding(
            get: { pendingSend != nil }, set: { if !$0 { pendingSend = nil } }
        ), titleVisibility: .visible, presenting: pendingSend) { pending in
            if pending.problems.contains(where: { if case .missingAttachment = $0 { true } else { false } }) {
                Button("Attach Files…") { isImporting = true }
            }
            ForEach(Array(pending.problems.enumerated()), id: \.offset) { _, problem in
                if case .missingPerson(let person) = problem {
                    Button(String(localized: "Add \(IntroReply.firstName(person))")) { model.add(person) }
                }
            }
            Button("Send Anyway") { Task { await send(at: pending.date, markDone: pending.markDone, checked: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.problems.map(Self.describe).joined(separator: "\n"))
        }
        .sheet(isPresented: $isAvailabilityShown) {
            AvailabilityPicker { text in model.insertion = TextInsertion(text: text) }
        }
    }

    // MARK: Header fields

    private var header: some View {
        VStack(spacing: 0) {
            if model.availableIdentities.count > 1 {
                row(String(localized: "From")) {
                    Picker("", selection: $model.identity) {
                        ForEach(model.availableIdentities) { identity in
                            Text(identity.mailAddress.description).tag(identity)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
            row(String(localized: "To")) {
                RecipientField(text: $model.to, onChange: model.changed)
                    .focused($focused, equals: .to)
                Button(model.showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") { model.showCcBcc.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
            if model.showCcBcc {
                row(String(localized: "Cc")) { RecipientField(text: $model.cc, onChange: model.changed).focused($focused, equals: .cc) }
                row(String(localized: "Bcc")) { RecipientField(text: $model.bcc, onChange: model.changed).focused($focused, equals: .bcc) }
            }
            row(String(localized: "Subject")) {
                TextField("", text: $model.subject)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($focused, equals: .subject)
                    .onChange(of: model.subject) { model.changed() }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().padding(.leading, 76)
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(attachment.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            model.attachments.remove(at: index)
                            model.changed()
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(12)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                model.saveNow()
                close()
            }
            .help("Close and keep the draft")
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button { isImporting = true } label: { Label("Attach", systemImage: "paperclip") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Attach files (⌘⇧A)")
            Button { isAvailabilityShown = true } label: { Label("Share Availability", systemImage: "calendar.badge.clock") }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .help("Insert free times from your calendar (⌥⌘A)")
            Button(role: .destructive) {
                model.discard()
                close()
            } label: { Label("Discard", systemImage: "trash") }
                .help("Discard draft")
            Menu {
                if model.isReply {
                    Button(AssistSettings.sendAndDone ? String(localized: "Send and Keep in Inbox") : String(localized: "Send and Mark Done")) {
                        Task { await send(at: nil, markDone: !AssistSettings.sendAndDone) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                }
                Button("Send Later…") { isSendLaterShown = true }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            } primaryAction: {
                Task { await send(at: nil) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help(model.isReply && AssistSettings.sendAndDone ? "Send and mark the conversation done (⌘↩)" : "Send (⌘↩)")
            .disabled(isSending)
        }
    }

    private var sendLaterSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send later").font(.headline)
            ForEach(SnoozePreset.all().filter { $0.date != nil }) { preset in
                Button {
                    isSendLaterShown = false
                    Task { await send(at: preset.date) }
                } label: {
                    HStack {
                        Image(systemName: preset.symbol).frame(width: 22)
                        Text(preset.title)
                        Spacer()
                        Text(preset.detail).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { isSendLaterShown = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .macFrame(width: 360)
    }

    private func send(at date: Date?, markDone: Bool? = nil, checked: Bool = false) async {
        if !checked {
            let problems = model.sendProblems()
            if !problems.isEmpty {
                pendingSend = PendingSend(date: date, markDone: markDone, problems: problems)
                return
            }
        }
        isSending = true
        defer { isSending = false }
        if await model.send(at: date, markDone: markDone) { close() }
    }

    static func describe(_ problem: SendCheck.Problem) -> String {
        switch problem {
        case .missingAttachment(let phrase):
            String(localized: "You wrote “\(phrase)”, but nothing is attached.")
        case .missingPerson(let person):
            String(localized: "You mention \(IntroReply.firstName(person)), but they aren't on this message.")
        }
    }
}

/// A comma-separated address field with suggestions from people you've mailed.
struct RecipientField: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    var onChange: () -> Void
    @State private var suggestions: [MailAddress] = []
    @State private var highlighted = 0

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 6) {
            field
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, address in
                            Button { accept(address) } label: {
                                Text(address.name ?? address.address).lineLimit(1)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        #else
        field
            .popover(isPresented: Binding(get: { !suggestions.isEmpty }, set: { if !$0 { suggestions = [] } }),
                     attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { suggestionList }
        #endif
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .onChange(of: text) {
                suggestions = app.suggestions(for: text)
                highlighted = 0
                onChange()
            }
            .onKeyPress(.downArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                highlighted = min(highlighted + 1, suggestions.count - 1); return .handled
            }
            .onKeyPress(.upArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                highlighted = max(highlighted - 1, 0); return .handled
            }
            .onKeyPress(.tab) {
                guard suggestions.indices.contains(highlighted) else { return .ignored }
                accept(suggestions[highlighted]); return .handled
            }
            .onKeyPress(.escape) {
                guard !suggestions.isEmpty else { return .ignored }
                suggestions = []; return .handled
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, address in
                Button { accept(address) } label: {
                    VStack(alignment: .leading) {
                        Text(address.name ?? address.address)
                        if address.name != nil { Text(address.address).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(index == highlighted ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Text("Tab to choose").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8)
        }
        .padding(6)
        .frame(width: 300)
    }

    private func accept(_ address: MailAddress) {
        var parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(address.description)
        text = parts.joined(separator: ", ") + ", "
        suggestions = []
    }
}

/// Outbox and local drafts: queued, scheduled, failed (with the reason) and unsent drafts.
struct OutboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if !model.outboxItems.isEmpty {
                Section("Outbox") {
                    ForEach(model.outboxItems, id: \.id) { item in
                        row(item)
                    }
                }
            }
            if !model.draftItems.isEmpty {
                Section("Drafts") {
                    ForEach(model.draftItems, id: \.id) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if let id = item.id { model.openComposeWindow?(id) } }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.outboxItems.isEmpty && model.draftItems.isEmpty {
                ContentUnavailableView("Nothing waiting to be sent", systemImage: "paperplane",
                                       description: Text("Press C to write a new message."))
            }
        }
    }

    private func row(_ item: OutboxItem) -> some View {
        let message = item.message
        return HStack(alignment: .top) {
            Image(systemName: icon(item.state)).foregroundStyle(item.state == .failed ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message?.subject.isEmpty == false ? message!.subject : String(localized: "(no subject)")).font(.headline)
                Text(message?.envelopeRecipients.joined(separator: ", ") ?? "").font(.caption).foregroundStyle(.secondary)
                if let id = item.id, model.autoDrafts.contains(where: { $0.outboxID == id }) {
                    Label("Follow-up drafted for you", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                }
                if let error = item.lastError {
                    Text(error).font(.caption).foregroundStyle(item.state == .failed ? .red : .orange)
                }
            }
            Spacer()
            if item.state == .queued, let sendAt = item.sendAt {
                Text(sendAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let id = item.id {
                if item.state == .failed {
                    Button("Retry") { model.retrySend(id) }
                }
                if item.state == .queued || item.state == .failed {
                    Button("Edit") { model.editQueued(id) }
                }
                if item.state == .draft {
                    Button("Open") { model.openComposeWindow?(id) }
                }
                Button(role: .destructive) { model.deleteOutboxItem(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(item.state == .sending)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ state: OutboxItem.State) -> String {
        switch state {
        case .draft: "doc"
        case .queued: "clock"
        case .sending: "paperplane"
        case .failed: "exclamationmark.triangle"
        }
    }
}
