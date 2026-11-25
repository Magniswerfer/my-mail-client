import MailEngine
import SwiftUI

/// Settings → Rules, also a sheet from ⌘K "Rules…". Type a sentence to make a rule, or build
/// one by hand. Order matters: rules run top to bottom.
struct RulesManager: View {
    @Environment(AppModel.self) private var model
    @State private var sentence = ""
    @State private var making = false
    @State private var editing: RuleEditing?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack {
                    TextField("Describe a rule", text: $sentence,
                              prompt: Text("All mail about shoes goes to Shopping"))
                        .onSubmit { Task { await make() } }
                    if making { ProgressView().controlSize(.small) }
                    Button("Create") { Task { await make() } }
                        .disabled(sentence.trimmingCharacters(in: .whitespaces).isEmpty || making)
                }
            } footer: {
                Text(model.assistant == nil
                     ? "Without Apple Intelligence, describe-a-rule opens an empty rule to fill in, and “about” conditions can't run."
                     : "Tidings turns the sentence into a rule you can check and change before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.rules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                ForEach($model.rules) { $rule in
                    HStack {
                        Toggle(isOn: $rule.isEnabled) { EmptyView() }
                            .labelsHidden()
                            .onChange(of: rule.isEnabled) { model.persistRules() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? String(localized: "Untitled rule") : rule.name)
                            Text(RuleText.summary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editing = RuleEditing(rule: rule, isNew: false) }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { model.delete(rule: rule) }
                    }
                }
                .onMove { from, to in
                    model.rules.move(fromOffsets: from, toOffset: to)
                    model.persistRules()
                }
                .onDelete { offsets in
                    model.rules.remove(atOffsets: offsets)
                    model.persistRules()
                }
                Button("New Rule…", systemImage: "plus") {
                    editing = RuleEditing(rule: MailRule(name: "", conditions: [.from("")], actions: [.markDone]), isNew: true)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules run on new Inbox mail after spam checks and sorting, top to bottom. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { editing in RuleEditor(editing: editing) }
    }

    private func make() async {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        making = true
        let rule = await model.rule(fromSentence: text)
        making = false
        sentence = ""
        editing = RuleEditing(rule: rule, isNew: true)
    }
}

/// Plain-language descriptions of rules.
enum RuleText {
    static func summary(_ rule: MailRule) -> String {
        let joiner = rule.match == .all ? String(localized: " and ") : String(localized: " or ")
        let when = rule.conditions.map(condition).joined(separator: joiner)
        let then = rule.actions.map(action).joined(separator: ", ")
        return String(localized: "If \(when): \(then)")
    }

    static func condition(_ c: MailRule.Condition) -> String {
        switch c {
        case .from(let s): String(localized: "from contains “\(s)”")
        case .to(let s): String(localized: "to contains “\(s)”")
        case .subject(let s): String(localized: "subject contains “\(s)”")
        case .body(let s): String(localized: "text contains “\(s)”")
        case .category(let c): String(localized: "category is \(c.title)")
        case .hasAttachment: String(localized: "has an attachment")
        case .about(let s): String(localized: "is about \(s)")
        }
    }

    static func action(_ a: MailRule.Action) -> String {
        switch a {
        case .moveToFolder(let f): String(localized: "move to \(f)")
        case .setCategory(let c): String(localized: "put in \(c.title)")
        case .markDone: String(localized: "mark done")
        case .pin: String(localized: "pin")
        case .markRead: String(localized: "mark read")
        case .snooze(let d): String(localized: "snooze \(d) days")
        case .replyLater: String(localized: "reply later")
        case .notify: String(localized: "notify me")
        case .forward(let to): String(localized: "forward to \(to)")
        case .autoReply: String(localized: "reply automatically")
        case .runShortcut(let n): String(localized: "run shortcut “\(n)”")
        }
    }
}

// MARK: - Editor

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: RuleEditing
    @State private var name = ""
    @State private var match = MailRule.Match.all
    @State private var conditions: [ConditionDraft] = []
    @State private var actions: [ActionDraft] = []
    @State private var stop = false
    @State private var preview: RulePreview?
    @State private var previewing = false
    @State private var running = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    if let sentence = editing.rule.sentence {
                        Text("From “\(sentence)”").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Match", selection: $match) {
                        Text("All of these").tag(MailRule.Match.all)
                        Text("Any of these").tag(MailRule.Match.any)
                    }
                    ForEach($conditions) { $draft in ConditionRow(draft: $draft) }
                        .onDelete { conditions.remove(atOffsets: $0) }
                    Menu("Add Condition", systemImage: "plus") {
                        ForEach(ConditionDraft.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { conditions.append(ConditionDraft(kind: kind)) }
                        }
                    }
                } header: { Text("When a message…") }
                Section {
                    ForEach($actions) { $draft in ActionRow(draft: $draft, folders: folderNames) }
                        .onDelete { actions.remove(atOffsets: $0) }
                    Menu("Add Action", systemImage: "plus") {
                        ForEach(ActionDraft.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { actions.append(ActionDraft(kind: kind)) }
                        }
                    }
                    Toggle("Stop processing more rules", isOn: $stop)
                } header: {
                    Text("Then")
                } footer: {
                    if built.usesNaturalLanguage, built.actions.contains(where: Self.sendsMail) {
                        Text("Rules with an “about” condition leave forwards and replies in Drafts for you to send.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Preview") {
                    if previewing {
                        ProgressView()
                    } else if let preview {
                        Text(preview.judged
                             ? "Would have matched \(preview.matched.count) of the \(preview.checked) recent messages checked."
                             : "Would have matched \(preview.matched.count) recent messages.")
                        ForEach(preview.matched.prefix(8), id: \.id) { m in
                            VStack(alignment: .leading) {
                                Text(m.subject).lineLimit(1)
                                Text("\(m.senderDisplay) · \(MailDate.short(m.date))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Preview") { Task { await runPreview() } }.disabled(!isValid || previewing)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing.isNew ? String(localized: "New Rule") : String(localized: "Edit Rule"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(rule: built); dismiss() }.disabled(!isValid)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save and Run on Existing Mail") {
                        let rule = built
                        model.save(rule: rule)
                        running = true
                        Task {
                            _ = await model.runOnExistingMail(rule)
                            running = false
                            dismiss()
                        }
                    }
                    .disabled(!isValid || running)
                }
            }
        }
        .macFrame(width: 560, height: 640)
        .onAppear(perform: load)
    }

    private var folderNames: [String] {
        Array(Set(model.mailboxes.map(\.displayName))).sorted()
    }

    private var built: MailRule {
        var rule = editing.rule
        rule.name = name.trimmingCharacters(in: .whitespaces)
        rule.match = match
        rule.conditions = conditions.compactMap(\.condition)
        rule.actions = actions.compactMap(\.action)
        rule.stopProcessing = stop
        return rule
    }

    private var isValid: Bool { !built.conditions.isEmpty && !built.actions.isEmpty && !built.name.isEmpty }

    static func sendsMail(_ action: MailRule.Action) -> Bool {
        switch action { case .forward, .autoReply: true; default: false }
    }

    private func load() {
        name = editing.rule.name
        match = editing.rule.match
        conditions = editing.rule.conditions.map(ConditionDraft.init)
        actions = editing.rule.actions.map(ActionDraft.init)
        stop = editing.rule.stopProcessing
    }

    private func runPreview() async {
        previewing = true
        preview = await model.preview(built)
        previewing = false
    }
}

/// Editable form of a condition.
struct ConditionDraft: Identifiable {
    enum Kind: CaseIterable { case from, to, subject, body, category, hasAttachment, about
        var title: String {
            switch self {
            case .from: String(localized: "From contains")
            case .to: String(localized: "To contains")
            case .subject: String(localized: "Subject contains")
            case .body: String(localized: "Text contains")
            case .category: String(localized: "Category is")
            case .hasAttachment: String(localized: "Has an attachment")
            case .about: String(localized: "Is about (AI)")
            }
        }
    }
    let id = UUID()
    var kind: Kind
    var text = ""
    var category = MailCategory.primary

    init(kind: Kind) { self.kind = kind }

    init(_ c: MailRule.Condition) {
        switch c {
        case .from(let s): kind = .from; text = s
        case .to(let s): kind = .to; text = s
        case .subject(let s): kind = .subject; text = s
        case .body(let s): kind = .body; text = s
        case .category(let c): kind = .category; category = c
        case .hasAttachment: kind = .hasAttachment
        case .about(let s): kind = .about; text = s
        }
    }

    var condition: MailRule.Condition? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .from: return t.isEmpty ? nil : .from(t)
        case .to: return t.isEmpty ? nil : .to(t)
        case .subject: return t.isEmpty ? nil : .subject(t)
        case .body: return t.isEmpty ? nil : .body(t)
        case .category: return .category(category)
        case .hasAttachment: return .hasAttachment
        case .about: return t.isEmpty ? nil : .about(t)
        }
    }
}

struct ConditionRow: View {
    @Binding var draft: ConditionDraft

    var body: some View {
        HStack {
            Picker("", selection: $draft.kind) {
                ForEach(ConditionDraft.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch draft.kind {
            case .category:
                Picker("", selection: $draft.category) {
                    ForEach(MailCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            case .hasAttachment:
                Spacer()
            case .about:
                TextField("a topic, e.g. shoes", text: $draft.text)
            default:
                TextField("text", text: $draft.text)
            }
        }
    }
}

/// Editable form of an action.
struct ActionDraft: Identifiable {
    enum Kind: CaseIterable { case moveToFolder, setCategory, markDone, pin, markRead, snooze, replyLater, notify, forward, autoReply, runShortcut
        var title: String {
            switch self {
            case .moveToFolder: String(localized: "Move to folder")
            case .setCategory: String(localized: "Put in category")
            case .markDone: String(localized: "Mark done")
            case .pin: String(localized: "Pin")
            case .markRead: String(localized: "Mark read")
            case .snooze: String(localized: "Snooze")
            case .replyLater: String(localized: "Reply later")
            case .notify: String(localized: "Notify me")
            case .forward: String(localized: "Forward to")
            case .autoReply: String(localized: "Reply with")
            case .runShortcut: String(localized: "Run shortcut")
            }
        }
    }
    let id = UUID()
    var kind: Kind
    var text = ""
    var category = MailCategory.primary
    var days = 1

    init(kind: Kind) { self.kind = kind }

    init(_ a: MailRule.Action) {
        switch a {
        case .moveToFolder(let f): kind = .moveToFolder; text = f
        case .setCategory(let c): kind = .setCategory; category = c
        case .markDone: kind = .markDone
        case .pin: kind = .pin
        case .markRead: kind = .markRead
        case .snooze(let d): kind = .snooze; days = d
        case .replyLater: kind = .replyLater
        case .notify: kind = .notify
        case .forward(let to): kind = .forward; text = to
        case .autoReply(let t): kind = .autoReply; text = t
        case .runShortcut(let n): kind = .runShortcut; text = n
        }
    }

    var action: MailRule.Action? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .moveToFolder: return t.isEmpty ? nil : .moveToFolder(t)
        case .setCategory: return .setCategory(category)
        case .markDone: return .markDone
        case .pin: return .pin
        case .markRead: return .markRead
        case .snooze: return .snooze(days: max(1, days))
        case .replyLater: return .replyLater
        case .notify: return .notify
        case .forward: return t.contains("@") ? .forward(to: t) : nil
        case .autoReply: return t.isEmpty ? nil : .autoReply(text: t)
        case .runShortcut: return t.isEmpty ? nil : .runShortcut(name: t)
        }
    }
}

struct ActionRow: View {
    @Binding var draft: ActionDraft
    let folders: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Picker("", selection: $draft.kind) {
                ForEach(ActionDraft.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch draft.kind {
            case .moveToFolder:
                Picker("", selection: $draft.text) {
                    Text("Choose…").tag("")
                    ForEach(folders, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            case .setCategory:
                Picker("", selection: $draft.category) {
                    ForEach(MailCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            case .snooze:
                Stepper("\(draft.days) days", value: $draft.days, in: 1...60)
            case .forward:
                TextField("address", text: $draft.text)
            case .autoReply:
                TextField("message", text: $draft.text, axis: .vertical).lineLimit(2...4)
            case .runShortcut:
                TextField("shortcut name", text: $draft.text)
            default:
                Spacer()
            }
        }
    }
}
