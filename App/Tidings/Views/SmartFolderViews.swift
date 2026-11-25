import MailEngine
import SwiftUI

/// The Smart Folders section of the sidebar: built-in folders, then yours, each with a count.
struct SmartFolderSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Smart Folders") {
            ForEach(SmartFolder.builtIn) { folder in
                row(folder)
            }
            ForEach(model.smartFolders) { folder in
                row(folder)
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { model.editingSmartFolder = folder }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(folder) }
                    }
            }
            .onMove { model.moveSmartFolders(from: $0, to: $1) }
        }
    }

    private func row(_ folder: SmartFolder) -> some View {
        Label(model.displayName(folder), systemImage: folder.symbol)
            .badge(model.smartFolderCounts[folder.id] ?? 0)
            .help(folder.query)
            .tag(SidebarItem.smartFolder(folder.id))
    }
}

/// Name a search to keep it (⌘S), or change a smart folder's name and search.
struct SmartFolderEditor: View {
    @Environment(AppModel.self) private var model
    @State var folder: SmartFolder
    @State private var count: Int?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $folder.name)
                    .focused($nameFocused)
                TextField("Search", text: $folder.query, prompt: Text("from:anna has:attachment after:thisyear"))
                    .font(.body.monospaced())
                Section {
                    if let count {
                        Text(count == 1 ? String(localized: "Finds 1 conversation right now.")
                                        : String(localized: "Finds \(count) conversations right now."))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Anything you can type in search works, like is:waiting, is:pinned, category:newsletters, after:30d.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.smartFolders.contains { $0.id == folder.id } ? String(localized: "Edit Smart Folder")
                                                                               : String(localized: "New Smart Folder"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.editingSmartFolder = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(folder) }
                        .disabled(folder.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task(id: folder.query) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                count = try? SearchEngine(store: model.store).conversationCount(SearchQuery(parsing: folder.query))
            }
            .onAppear { nameFocused = true }
        }
        .macFrame(minWidth: 460, minHeight: 300)
    }
}
