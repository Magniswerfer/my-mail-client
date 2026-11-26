import MailEngine
import SwiftUI

/// New Folder, Rename and Move To, as one small sheet.
struct FolderEditor: View {
    @Environment(AppModel.self) private var model
    let editing: FolderEditing
    @State private var name = ""
    /// The parent picked in "Location"; "" is the top level (Picker tags can't be nil-friendly everywhere).
    @State private var location = ""
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var nameFocused: Bool

    private var path: String? {
        switch editing.kind {
        case .create: nil
        case .rename(let p), .move(let p): p
        }
    }

    private var box: MailboxState? {
        path.flatMap { p in model.mailboxes.first { $0.accountID == editing.accountID && $0.path == p } }
    }

    private var title: String {
        switch editing.kind {
        case .create: String(localized: "New Folder")
        case .rename: String(localized: "Rename Folder")
        case .move: String(localized: "Move Folder")
        }
    }

    private var actionTitle: String {
        switch editing.kind {
        case .create: String(localized: "Create")
        case .rename: String(localized: "Rename")
        case .move: String(localized: "Move")
        }
    }

    private var showsName: Bool { if case .move = editing.kind { false } else { true } }
    private var showsLocation: Bool { if case .rename = editing.kind { false } else { true } }

    private var canSubmit: Bool {
        guard !isWorking else { return false }
        switch editing.kind {
        case .create: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .rename(let p):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed != FolderPath.name(of: p, separator: model.folderLayout(accountID: editing.accountID).separator)
        case .move(let p):
            return (location.isEmpty ? nil : location) != model.parentFolder(of: p, accountID: editing.accountID)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if showsName {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .onSubmit(submit)
                }
                if showsLocation {
                    Picker("Location", selection: $location) {
                        Text("Top Level").tag("")
                        ForEach(model.folderLocations(accountID: editing.accountID, excluding: path)) { row in
                            Text(verbatim: String(repeating: "    ", count: row.depth) + row.name).tag(row.box.path)
                        }
                    }
                }
                if let special = path.flatMap({ model.specialFolderName(within: $0, accountID: editing.accountID) }) {
                    Section {
                        Label {
                            Text("“\(special)” is a special folder. Tidings and other mail apps may stop finding it after this.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                if let error {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
                if model.accounts.count > 1, let account = model.account(id: editing.accountID) {
                    Section {
                    } footer: {
                        Text("In \(account.displayName)")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.folderEditing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(actionTitle, action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear {
                switch editing.kind {
                case .create(let parent): location = parent ?? ""
                case .rename(let p): name = FolderPath.name(of: p, separator: model.folderLayout(accountID: editing.accountID).separator)
                case .move(let p): location = model.parentFolder(of: p, accountID: editing.accountID) ?? ""
                }
                nameFocused = true
            }
        }
        .macFrame(minWidth: 420, minHeight: 220)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        let parent = location.isEmpty ? nil : location
        Task {
            do {
                switch editing.kind {
                case .create:
                    try await model.createFolder(named: name, in: parent, accountID: editing.accountID)
                case .rename(let p):
                    try await model.renameFolder(p, to: name, accountID: editing.accountID)
                case .move(let p):
                    try await model.moveFolder(p, into: parent, accountID: editing.accountID)
                }
                model.folderEditing = nil
            } catch let failure as FolderFailure {
                error = failure.message
            } catch {
                self.error = model.folderErrorMessage(error)
            }
            isWorking = false
        }
    }
}

/// The folder sheet and the delete confirmation, on the Mac window and the iPhone root.
struct FolderManagement: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.folderEditing) { editing in
                FolderEditor(editing: editing).environment(model)
            }
            .confirmationDialog(
                model.folderToDelete.map { String(localized: "Delete “\($0.name)”?") } ?? "",
                isPresented: Binding(get: { model.folderToDelete != nil }, set: { if !$0 { model.folderToDelete = nil } }),
                titleVisibility: .visible, presenting: model.folderToDelete
            ) { deletion in
                Button("Delete Folder", role: .destructive) { model.deleteFolder(deletion) }
                Button("Cancel", role: .cancel) { model.folderToDelete = nil }
            } message: { deletion in
                Text(deletionMessage(deletion))
            }
    }

    private func deletionMessage(_ d: FolderDeletion) -> String {
        var parts: [String] = []
        if let special = d.specialName {
            parts.append(String(localized: "“\(special)” is a special folder; Tidings and other mail apps use it."))
        }
        if d.subfolderCount > 0 {
            parts.append(String(localized: "It holds \(d.subfolderCount) subfolders, which are deleted too."))
        }
        // The count is what's synced here; say "any mail" when that's nothing, in case it isn't.
        parts.append(d.messageCount > 0 ? String(localized: "\(d.messageCount) messages are deleted from the server too.")
                                        : String(localized: "Any mail in it is deleted from the server too."))
        parts.append(String(localized: "This can't be undone."))
        return parts.joined(separator: " ")
    }
}

/// Right-click (long press on iPhone) on a folder in the sidebar.
struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let box: MailboxState

    var body: some View {
        Button("New Folder…", systemImage: "folder.badge.plus") {
            model.newFolder(accountID: box.accountID, in: box.role == nil ? box.path : nil)
        }
        if model.canChangeFolder(box) {
            Divider()
            Button("Rename…", systemImage: "pencil") { model.renameFolder(box) }
            Button("Move To…", systemImage: "folder") { model.moveFolder(box) }
            Menu("Use As", systemImage: "star") {
                ForEach(AccountSync.choosableRoles, id: \.self) { role in
                    Toggle(isOn: Binding(
                        get: { box.role == role },
                        set: { on in model.useFolder(on ? box : nil, as: role, accountID: box.accountID) }
                    )) {
                        Label(role.title, systemImage: role.symbol)
                    }
                }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDeleteFolder(box) }
        }
    }
}
