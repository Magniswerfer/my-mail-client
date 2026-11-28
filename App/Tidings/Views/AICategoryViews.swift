import MailEngine
import SwiftUI

/// Primary · Transactions · … · your AI categories · All · +, above the Inbox (the sidebar has
/// one Inbox row for all of them). Tab / ⇧Tab (and ⌘] / ⌘[) move between them.
struct CategoryTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = (try? model.store.threads(mailbox: "INBOX", accountID: model.inboxAccountID, ownAddresses: model.ownAddresses)) ?? []
        let current = model.currentCategoryTab
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.categoryTabs) { tab in
                        pill(tab, isOn: tab == current, unread: model.unreadCount(for: tab, inbox: inbox))
                            .id(tab.id)
                    }
                    Button {
                        model.editingAICategory = AICategoryEditing(category: AICategory(name: "", description: ""), isNew: true)
                    } label: {
                        Label("New AI Category", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderless)
                    .help("Describe a category and let the on-device model sort mail into it")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .onChange(of: current) { _, tab in
                if let tab { withAnimation(.snappy) { proxy.scrollTo(tab.id, anchor: .center) } }
            }
        }
        .background(.bar)
    }

    @ViewBuilder private func pill(_ tab: CategoryTab, isOn: Bool, unread: Int) -> some View {
        let (title, symbol, tint) = describe(tab)
        Button { model.selection = tab.selection } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(isOn ? .white : tint)
                Text(title).lineLimit(1)
                if unread > 0 {
                    Text("\(unread)").font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isOn ? .white.opacity(0.85) : .secondary)
                }
            }
            .font(.callout.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Tab / ⇧Tab to switch")
        // Drop a conversation on a category to move it (and teach the classifier).
        .dropDestination(for: ThreadDrag.self) { items, _ in
            guard case .builtIn(let category) = tab else { return false }
            let threads = model.threads(for: items)
            guard !threads.isEmpty else { return false }
            model.moveConversations(threads, to: category)
            return true
        }
        .contextMenu {
            if case .ai(let id) = tab, let category = model.aiCategory(id: id) {
                Button("Edit…", systemImage: "pencil") {
                    model.editingAICategory = AICategoryEditing(category: category, isNew: false)
                }
                Button("Delete", systemImage: "trash", role: .destructive) { model.delete(aiCategory: category) }
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func describe(_ tab: CategoryTab) -> (String, String, Color) {
        switch tab {
        case .all: (String(localized: "All"), "tray", .accentColor)
        case .builtIn(let c): (c.title, c.symbol, c.tint)
        case .ai(let id): (model.aiCategory(id: id)?.name ?? "", model.aiCategory(id: id)?.symbol ?? "sparkles", .indigo)
        }
    }
}

/// Name it, say what belongs, check the preview, save. The on-device model does the sorting;
/// ✓/✗ corrections from the context menu make it better.
struct AICategoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: AICategoryEditing
    @State private var name = ""
    @State private var description = ""
    @State private var symbol = "sparkles"
    @State private var senders: [String] = []
    @State private var preview: [StoredMessage]?
    @State private var previewing = false

    static let symbols = ["sparkles", "briefcase", "person.2", "dollarsign.circle", "airplane", "house", "graduationcap",
                          "heart", "cart", "wrench.and.screwdriver", "building.columns", "megaphone", "star", "leaf"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Investors"))
                    TextField("What belongs here", text: $description, prompt: Text("Updates, questions and term sheets from our investors"),
                              axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text(model.assistant == nil
                         ? "Without Apple Intelligence on this device, Tidings can't sort into it by itself. You can still add conversations from their right-click menu."
                         : "Sorted on this device, as mail arrives. Your recent Inbox is sorted when you save. Fix mistakes from a conversation's right-click menu and it learns.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !senders.isEmpty {
                    sendersSection
                }
                symbolSection
                previewSection
            }
            .formStyle(.grouped)
            .navigationTitle(editing.isNew ? String(localized: "New AI Category") : String(localized: "Edit Category"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .macFrame(width: 520, height: 600)
        .onAppear {
            name = editing.category.name
            description = Self.userDescription(of: editing.category)
            symbol = editing.category.symbol
            senders = editing.category.senders
        }
    }

    private var sendersSection: some View {
        Section {
            ForEach(senders, id: \.self) { address in
                HStack {
                    Text(address)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { senders.removeAll { $0 == address } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Always includes mail from")
        } footer: {
            Text("Set with “Always for” when you move a conversation here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var symbolSection: some View {
        Section("Symbol") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).frame(width: 30, height: 30)
                            .background(symbol == s ? AnyShapeStyle(Color.indigo.opacity(0.2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if previewing {
                ProgressView()
            } else if let preview {
                Text(preview.isEmpty ? "Nothing in your recent Inbox matches yet." : "Would catch \(preview.count) recent conversations:")
                    .foregroundStyle(.secondary)
                ForEach(preview.prefix(8), id: \.id) { m in
                    VStack(alignment: .leading) {
                        Text(m.subject).lineLimit(1)
                        Text("\(m.fromName ?? m.fromAddress) · \(MailDate.short(m.date))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Preview") { Task { await runPreview() } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.assistant == nil || previewing)
        }
    }

    /// What you wrote, without the "Name: " the saved description starts with.
    private static func userDescription(of category: AICategory) -> String {
        let full = category.about.description
        guard full != category.name else { return "" }
        let prefix = "\(category.name): "
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    private var built: AICategory {
        var c = editing.category
        c.name = name.trimmingCharacters(in: .whitespaces)
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        c.about.description = text.isEmpty ? c.name : "\(c.name): \(text)"
        c.symbol = symbol
        c.senders = senders
        return c
    }

    private func runPreview() async {
        previewing = true
        preview = await model.previewAICategory(built)
        previewing = false
    }

    private func save() {
        let category = built
        model.save(aiCategory: category, isNew: editing.isNew,
                   descriptionChanged: category.about.description != editing.category.about.description)
        dismiss()
    }
}

/// "In Investors ✓" for each AI category, in a conversation's right-click menu.
struct AICategoryMenu: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary

    var body: some View {
        if !model.aiCategories.isEmpty {
            Menu("AI Categories", systemImage: "sparkles") {
                ForEach(model.aiCategories) { category in
                    let isMember = model.aiMembership[thread.threadID]?.contains(category.id) == true
                    Button {
                        model.toggle(aiCategory: category.id, for: thread)
                    } label: {
                        Label(category.name, systemImage: isMember ? "checkmark" : category.symbol)
                    }
                }
                Divider()
                Button("New AI Category…", systemImage: "plus") {
                    model.editingAICategory = AICategoryEditing(category: AICategory(name: "", description: ""), isNew: true)
                }
            }
        }
    }
}
