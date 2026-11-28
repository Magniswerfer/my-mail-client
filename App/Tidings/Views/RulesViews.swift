import MailEngine
import SwiftUI

/// Rules (⌥⌘R): your ordered list. Drag to reorder; the switch turns a rule off.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// In Settings there's no sheet to close.
    var inSettings = false
    @State private var isHistoryShown = false
    @State private var selection: Rule.ID?

    var body: some View {
        if inSettings {
            // Settings: the window (Mac) or the settings sheet's stack (iPhone) is the frame.
            content
        } else {
            NavigationStack { content }
                .macFrame(minWidth: 640, minHeight: 460)
        }
    }

    /// The Mac's Settings window has no toolbar to spare, so there the buttons sit under the list.
    private var buttonsBelow: Bool { inSettings && Platform.isMac }

    private var content: some View {
        @Bindable var model = model
        return Group {
            if model.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
        .navigationTitle("Rules")
        // Mac: its own window, so these sit in the compact title bar. iPhone: a sheet's toolbar.
        .toolbar {
            if !Platform.isMac && !inSettings {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            if !buttonsBelow {
                ToolbarItemGroup(placement: .primaryAction) { historyButton; newButton }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if buttonsBelow {
                HStack {
                    newButton
                    historyButton
                    Spacer()
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .padding(10)
            }
        }
        .sheet(item: $model.editingRule) { rule in
            RuleEditor(rule: rule).environment(model)
        }
        .sheet(isPresented: $isHistoryShown) {
            RuleHistoryView().environment(model)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No rules yet", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Rules sort new mail as it arrives, after Tidings' own sorting: move it to a category or folder, pin it, mark it read or done.")
        } actions: {
            Button("New Rule") { model.newRule() }.buttonStyle(.glassProminent)
        }
    }

    private var rulesList: some View {
        List(selection: $selection) {
            ForEach(model.rules) { rule in
                RuleRow(rule: rule, count: model.ruleCounts[rule.id] ?? 0)
                    .tag(rule.id)
                    .contextMenu { menu(for: rule) }
            }
            .onMove { model.moveRules(from: $0, to: $1) }
        }
        .contextMenu(forSelectionType: Rule.ID.self) { _ in } primaryAction: { ids in
            if let opened = rule(withID: ids.first) { model.editingRule = opened }
        }
        .onKeyPress(.return) {
            guard let selected = rule(withID: selection) else { return .ignored }
            model.editingRule = selected
            return .handled
        }
    }

    private func rule(withID id: Rule.ID?) -> Rule? {
        guard let id else { return nil }
        return model.rules.first { $0.id == id }
    }

    private var historyButton: some View {
        Button { isHistoryShown = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            .help("What your rules did, with Undo")
    }

    private var newButton: some View {
        Button { model.newRule() } label: { Label("New Rule", systemImage: "plus") }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .help("New Rule (⌥⌘N)")
    }

    @ViewBuilder private func menu(for rule: Rule) -> some View {
        Button("Edit…", systemImage: "pencil") { model.editingRule = rule }
        Button("Run on Inbox Now", systemImage: "play") { model.runOnInbox(rule) }
            .disabled(!rule.isComplete)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(rule) }
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.setEnabled($0, for: rule) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? String(localized: "Untitled rule") : rule.name).font(.headline)
                    if rule.stopProcessing {
                        Image(systemName: "stop.circle").foregroundStyle(.secondary)
                            .help("Stops processing more rules")
                    }
                }
                Text(rule.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count) this week")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

// MARK: - Editor

/// One rule: name, conditions, actions, and a live preview of what it would match in the Inbox.
struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var preview: [StoredMessage] = []
    @State private var previewing = false
    @State private var applyNow = false
    @State private var sentence = ""
    @State private var drafting = false
    @State private var draftFailed = false

    /// Matches listed in the preview when the on-device model isn't involved.
    private static let previewListLimit = 8
    /// Typing settles this long before the preview goes through the Inbox.
    private static let previewDelay: Duration = .milliseconds(250)

    var body: some View {
        NavigationStack {
            Form {
                if model.ruleDrafter != nil {
                    draftSection
                }
                Section {
                    TextField("Name", text: $rule.name, prompt: Text("Shoe shops to Advertising"))
                }
                conditionsSection
                actionsSection
                Section {
                    previewContent
                } header: {
                    Text("Preview")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule.name.isEmpty ? String(localized: "New Rule") : rule.name)
            .sheetButtons {
                Button("Cancel") { model.editingRule = nil }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(!rule.isComplete)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .task(id: rule.conditions) { await refreshPreview() }
        }
        // Small enough to fit the main window's 560-pt minimum; the form scrolls.
        .macFrame(minWidth: 620, minHeight: 420, idealHeight: 520)
    }

    private var draftSection: some View {
        Section {
            HStack {
                TextField("Describe the rule", text: $sentence,
                          prompt: Text("Move mail about shoes from shops to Advertising"))
                    .onSubmit { draft() }
                if drafting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Draft") { draft() }
                        .disabled(sentence.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } footer: {
            Text(draftFailed ? String(localized: "Couldn't turn that into a rule. Try saying what mail it's for and what to do with it.")
                             : String(localized: "Write it in your own words; the on-device model fills in the rule below for you to check."))
        }
    }

    private var conditionsSection: some View {
        Section {
            Picker("When", selection: $rule.matchAll) {
                Text("All conditions match").tag(true)
                Text("Any condition matches").tag(false)
            }
            ForEach(rule.conditions.indices, id: \.self) { index in
                HStack {
                    ConditionEditor(condition: element(of: \.conditions, at: index, fallback: .hasAttachment(true)))
                    removeButton { if rule.conditions.indices.contains(index) { rule.conditions.remove(at: index) } }
                }
            }
            Menu {
                ForEach(ConditionKind.available(about: model.ruleJudge != nil), id: \.self) { kind in
                    Button(kind.title) { rule.conditions.append(kind.makeDefault()) }
                }
            } label: {
                Label("Add Condition", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("Conditions")
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(rule.actions.indices, id: \.self) { index in
                HStack {
                    ActionEditor(action: element(of: \.actions, at: index, fallback: .pin))
                    removeButton { if rule.actions.indices.contains(index) { rule.actions.remove(at: index) } }
                }
            }
            Menu {
                ForEach(ActionKind.available, id: \.self) { kind in
                    Button(kind.title) { rule.actions.append(kind.makeDefault()) }
                }
            } label: {
                Label("Add Action", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Toggle("Stop processing more rules", isOn: $rule.stopProcessing)
        } header: {
            Text("Actions")
        } footer: {
            Text("Rules run on new mail in the Inbox, after Tidings' own sorting. Only the first action that takes mail out of the Inbox (Done, Snooze, Move to Folder) runs.")
        }
    }

    @ViewBuilder private var previewContent: some View {
        if rule.conditions.isEmpty {
            Text("Add a condition to see what this rule would match.").foregroundStyle(.secondary)
        } else if previewing && preview.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Looking through the Inbox…").foregroundStyle(.secondary) }
        } else {
            Text(preview.isEmpty ? String(localized: "Matches nothing in the Inbox right now.")
                                 : String(localized: "Matches \(preview.count) messages in the Inbox right now."))
            if rule.usesLanguageModel {
                Text("The on-device model checked the \(RuleEngine.modelPreviewLimit) likeliest messages. Mark right ✓ or wrong ✗ to teach it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(preview.prefix(rule.usesLanguageModel ? RuleEngine.modelPreviewLimit : Self.previewListLimit), id: \.id) { message in
                previewRow(message)
            }
            if !preview.isEmpty && rule.isComplete {
                Toggle("Also apply it to these now", isOn: $applyNow)
            }
        }
    }

    private func previewRow(_ message: StoredMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(message.senderDisplay).font(.callout.weight(.medium))
                Text(message.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if rule.usesLanguageModel {
                Spacer()
                Button { teach(message, matches: true) } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless).help("Right: this matches")
                    .accessibilityLabel("Right: this matches")
                Button { teach(message, matches: false) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Wrong: this doesn't match")
                    .accessibilityLabel("Wrong: this doesn't match")
            }
        }
    }

    /// A binding to one row that tolerates the row having just been removed (SwiftUI can read a
    /// row's binding once more after its element is gone).
    private func element<T>(of path: WritableKeyPath<Rule, [T]>, at index: Int, fallback: T) -> Binding<T> {
        Binding(
            get: { rule[keyPath: path].indices.contains(index) ? rule[keyPath: path][index] : fallback },
            set: { if rule[keyPath: path].indices.contains(index) { rule[keyPath: path][index] = $0 } }
        )
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .help("Remove")
    }

    private func refreshPreview() async {
        guard !rule.conditions.isEmpty else { preview = []; return }
        previewing = true
        defer { previewing = false }
        try? await Task.sleep(for: Self.previewDelay)
        guard !Task.isCancelled else { return }
        let found = (try? await model.ruleEngine.preview(model.calibrated(rule), store: model.store)) ?? []
        guard !Task.isCancelled else { return }
        preview = found
    }

    private func save() {
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            rule.name = rule.conditions.first?.summary ?? String(localized: "Untitled rule")
        }
        model.save(rule)
        if applyNow, let saved = model.rules.first(where: { $0.id == rule.id }) { model.runOnInbox(saved) }
        model.editingRule = nil
    }

    private func draft() {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !drafting else { return }
        drafting = true
        draftFailed = false
        Task {
            let drafted = await model.draftRule(text, replacing: rule)
            drafting = false
            if let drafted { rule = drafted } else { draftFailed = true }
        }
    }

    /// ✓/✗ from the preview become examples for the model (every "about …" condition).
    private func teach(_ message: StoredMessage, matches: Bool) {
        let example = AboutCondition.Example(text: "\(message.senderDisplay): \(message.subject)", matches: matches)
        rule.conditions = rule.conditions.map { condition in
            guard case .about(var about) = condition else { return condition }
            about.examples.removeAll { $0.text == example.text }
            about.examples.append(example)
            return .about(about)
        }
        if !matches { preview.removeAll { $0.id == message.id } }
    }
}

// MARK: Condition and action rows

enum ConditionKind: CaseIterable, Hashable {
    case sender, recipient, subject, text, category, attachment, about

    /// "About …" needs the on-device judge (embeddings and/or Foundation Models).
    static func available(about: Bool) -> [ConditionKind] { about ? allCases : allCases.filter { $0 != .about } }

    var title: String {
        switch self {
        case .sender: String(localized: "Sender")
        case .recipient: String(localized: "Recipient")
        case .subject: String(localized: "Subject")
        case .text: String(localized: "Subject or text")
        case .category: String(localized: "Category")
        case .attachment: String(localized: "Attachments")
        case .about: String(localized: "About (in your words)")
        }
    }

    init(_ condition: RuleCondition) {
        switch condition {
        case .sender: self = .sender
        case .recipient: self = .recipient
        case .subject: self = .subject
        case .text: self = .text
        case .category: self = .category
        case .hasAttachment: self = .attachment
        case .about: self = .about
        }
    }

    func makeDefault(keeping text: TextMatch? = nil) -> RuleCondition {
        let match = text ?? TextMatch(.contains, "")
        switch self {
        case .sender: return .sender(match)
        case .recipient: return .recipient(match)
        case .subject: return .subject(match)
        case .text: return .text(match)
        case .category: return .category(.advertising)
        case .attachment: return .hasAttachment(true)
        case .about: return .about(AboutCondition(""))
        }
    }
}

struct ConditionEditor: View {
    @Binding var condition: RuleCondition

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { ConditionKind(condition) }, set: { kind in
                condition = kind.makeDefault(keeping: textMatch)
            })) {
                ForEach(ConditionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .compactPicker()
            switch condition {
            case .sender, .recipient, .subject, .text:
                Picker("", selection: Binding(get: { textMatch?.operation ?? .contains },
                                              set: { op in setText { $0.operation = op } })) {
                    ForEach(TextMatch.Operation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .compactPicker()
                TextField("", text: Binding(get: { textMatch?.value ?? "" }, set: { value in setText { $0.value = value } }),
                          prompt: Text(ConditionKind(condition) == .sender ? "@shop.dk" : ""))
            case .category(let category):
                Picker("", selection: Binding(get: { category }, set: { condition = .category($0) })) {
                    ForEach(MailCategory.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .compactPicker()
                Spacer()
            case .hasAttachment(let has):
                Picker("", selection: Binding(get: { has }, set: { condition = .hasAttachment($0) })) {
                    Text("has some").tag(true)
                    Text("has none").tag(false)
                }
                .compactPicker()
                Spacer()
            case .about(let about):
                TextField("", text: Binding(get: { about.description }, set: { text in
                    var changed = about
                    changed.description = text
                    condition = .about(changed)
                }), prompt: Text("shoes and sneakers"))
            }
        }
    }

    private var textMatch: TextMatch? {
        switch condition {
        case .sender(let m), .recipient(let m), .subject(let m), .text(let m): m
        default: nil
        }
    }

    private func setText(_ change: (inout TextMatch) -> Void) {
        guard var match = textMatch else { return }
        change(&match)
        condition = ConditionKind(condition).makeDefault(keeping: match)
    }
}

enum ActionKind: CaseIterable, Hashable {
    case category, pin, markRead, replyLater, done, snooze, folder, notify, forward, autoReply, shortcut

    static var available: [ActionKind] { allCases }

    var title: String {
        switch self {
        case .category: String(localized: "Move to category")
        case .pin: String(localized: "Pin")
        case .markRead: String(localized: "Mark as read")
        case .replyLater: String(localized: "Set aside to reply later")
        case .done: String(localized: "Mark done")
        case .snooze: String(localized: "Snooze")
        case .folder: String(localized: "Move to folder")
        case .notify: String(localized: "Notify me")
        case .forward: String(localized: "Forward to")
        case .autoReply: String(localized: "Reply with")
        case .shortcut: String(localized: "Run shortcut")
        }
    }

    init(_ action: RuleAction) {
        switch action {
        case .setCategory: self = .category
        case .pin: self = .pin
        case .markRead: self = .markRead
        case .replyLater: self = .replyLater
        case .done: self = .done
        case .snooze: self = .snooze
        case .moveToFolder: self = .folder
        case .notify: self = .notify
        case .forward: self = .forward
        case .autoReply: self = .autoReply
        case .runShortcut: self = .shortcut
        }
    }

    func makeDefault() -> RuleAction {
        switch self {
        case .category: .setCategory(.advertising)
        case .pin: .pin
        case .markRead: .markRead
        case .replyLater: .replyLater
        case .done: .done
        case .snooze: .snooze(hours: 24)
        case .folder: .moveToFolder("")
        case .notify: .notify
        case .forward: .forward(to: "")
        case .autoReply: .autoReply(text: "")
        case .shortcut: .runShortcut(name: "")
        }
    }
}

struct ActionEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var action: RuleAction

    static let snoozeChoices: [Int?] = [1, 3, 24, 72, 168, nil]

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { ActionKind(action) }, set: { action = $0.makeDefault() })) {
                ForEach(ActionKind.available, id: \.self) { Text($0.title).tag($0) }
            }
            .compactPicker()
            switch action {
            case .setCategory(let category):
                Picker("", selection: Binding(get: { category }, set: { action = .setCategory($0) })) {
                    ForEach(MailCategory.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .compactPicker()
            case .snooze(let hours):
                Picker("", selection: Binding(get: { hours }, set: { action = .snooze(hours: $0) })) {
                    ForEach(Self.snoozeChoices, id: \.self) { choice in
                        Text(choice.map(Self.duration) ?? String(localized: "someday")).tag(choice)
                    }
                }
                .compactPicker()
            case .moveToFolder(let path):
                Picker("", selection: Binding(get: { path }, set: { action = .moveToFolder($0) })) {
                    Text("Choose…").tag("")
                    ForEach(folders, id: \.self) { Text(MailboxState.displayName($0)).tag($0) }
                }
                .compactPicker()
            case .forward(let to):
                TextField("address", text: Binding(get: { to }, set: { action = .forward(to: $0) }),
                          prompt: Text(verbatim: "anna@example.com"))
                    .frame(maxWidth: 260)
            case .autoReply(let text):
                TextField("message", text: Binding(get: { text }, set: { action = .autoReply(text: $0) }), axis: .vertical)
                    .lineLimit(1...4)
                    .frame(maxWidth: 300)
            case .runShortcut(let name):
                TextField("shortcut name", text: Binding(get: { name }, set: { action = .runShortcut(name: $0) }))
                    .frame(maxWidth: 220)
            default:
                EmptyView()
            }
            Spacer()
        }
    }

    /// Folders across accounts (by path), without the Inbox and the ones rules shouldn't fill.
    private var folders: [String] {
        let excluded: Set<MailboxRole> = [.inbox, .sent, .drafts]
        let paths = model.mailboxes
            .filter { !($0.role.map(excluded.contains) ?? false) && !AccountSync.isSnoozedMailbox($0.path) && $0.path.uppercased() != "INBOX" }
            .map(\.path)
        return Array(Set(paths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func duration(_ hours: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = hours % 24 == 0 ? [.day] : [.hour]
        return String(localized: "for \(formatter.string(from: TimeInterval(hours) * 3600) ?? "\(hours)")")
    }
}

// MARK: - History

/// What your rules did, newest first, each with Undo.
struct RuleHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [RuleRun] = []

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("When a rule acts on new mail, it shows up here."))
                } else {
                    List(runs) { run in runRow(run) }
                }
            }
            .navigationTitle("Rule History")
            .sheetButtons {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                EmptyView()
            }
        }
        .macFrame(minWidth: 560, minHeight: 420, idealHeight: 440)
        .task { runs = (try? model.store.ruleRuns()) ?? [] }
    }

    private func runRow(_ run: RuleRun) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(run.sender).font(.headline).lineLimit(1)
                    Spacer()
                    Text(run.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(run.subject).lineLimit(1)
                Text("\(run.ruleNames.joined(separator: ", ")): \(run.actions.map(\.summary).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if run.undoneAt != nil {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Undo") {
                    model.undo(run)
                    if let index = runs.firstIndex(of: run) { runs[index].undoneAt = Date() }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension View {
    /// A picker inside a condition or action row: no label, only as wide as its choice.
    func compactPicker() -> some View {
        labelsHidden().fixedSize()
    }
}
