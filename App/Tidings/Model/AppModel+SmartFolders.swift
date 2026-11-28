import Foundation
import MailEngine

/// Smart folders (SPEC §7): saved searches in the sidebar with live counts.
extension AppModel {
    /// The built-in folders, then yours.
    var allSmartFolders: [SmartFolder] { SmartFolder.builtIn + smartFolders }

    func smartFolder(id: String) -> SmartFolder? { allSmartFolders.first { $0.id == id } }

    /// Built-in names in your language; yours as you named them.
    func displayName(_ folder: SmartFolder) -> String {
        switch folder.id {
        case SmartFolder.readLater.id: String(localized: "Read Later")
        case SmartFolder.attachments.id: String(localized: "Attachments")
        case SmartFolder.waitingForReply.id: String(localized: "Waiting for Reply")
        case SmartFolder.receiptsThisYear.id: String(localized: "Receipts This Year")
        default: folder.name
        }
    }

    func loadSmartFolders() {
        smartFolders = (try? store.smartFolders()) ?? []
    }

    /// The conversations a smart folder's search finds, newest first.
    func smartFolderThreads(_ folder: SmartFolder) throws -> [ThreadSummary] {
        let ids = try SearchEngine(store: store).conversations(SearchQuery(parsing: folder.query))
        return try store.threads(representedBy: ids, ownAddresses: ownAddresses)
    }

    /// Recounts every folder a moment after the store changed (reloads come in bursts).
    func scheduleSmartFolderCounts() {
        smartFolderCountTask?.cancel()
        smartFolderCountTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let engine = SearchEngine(store: self.store)
            let folders = self.allSmartFolders.map { ($0.id, $0.query) }
            // Every folder is a search: run them off the main thread.
            let counts = await Task.detached(priority: .utility) {
                var counts: [String: Int] = [:]
                for (id, query) in folders {
                    counts[id] = (try? engine.conversationCount(SearchQuery(parsing: query))) ?? 0
                }
                return counts
            }.value
            guard !Task.isCancelled else { return }
            if counts != self.smartFolderCounts { self.smartFolderCounts = counts }
        }
    }

    // MARK: Saving and editing

    /// ⌘S while searching: save what you typed as a smart folder.
    func saveCurrentSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        editingSmartFolder = SmartFolder(name: query, query: query)
    }

    func save(_ folder: SmartFolder) {
        guard !folder.isBuiltIn else { return }
        var folder = folder
        folder.name = folder.name.trimmingCharacters(in: .whitespaces)
        folder.query = folder.query.trimmingCharacters(in: .whitespaces)
        guard !folder.query.isEmpty else { return }
        if folder.name.isEmpty { folder.name = folder.query }
        let isNew = !smartFolders.contains { $0.id == folder.id }
        if isNew { smartFolders.append(folder) } else if let i = smartFolders.firstIndex(where: { $0.id == folder.id }) { smartFolders[i] = folder }
        persistSmartFolders()
        editingSmartFolder = nil
        if isNew { selection = .smartFolder(folder.id) } else { reload() }
    }

    func delete(_ folder: SmartFolder) {
        guard !folder.isBuiltIn else { return }
        smartFolders.removeAll { $0.id == folder.id }
        persistSmartFolders()
        if selection == .smartFolder(folder.id) { goToInbox() }
    }

    func moveSmartFolders(from source: IndexSet, to destination: Int) {
        smartFolders.move(fromOffsets: source, toOffset: destination)
        persistSmartFolders()
    }

    private func persistSmartFolders() {
        do {
            try store.saveSmartFolders(smartFolders)
        } catch {
            lastError = String(localized: "Couldn't save your smart folders: \(String(describing: error))")
        }
        scheduleSmartFolderCounts()
    }
}
