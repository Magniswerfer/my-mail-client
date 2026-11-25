import Foundation
import MailEngine
import SwiftUI

extension SmartFolder {
    var localizedName: String {
        switch id {
        case "builtin.attachments": String(localized: "Attachments")
        case "builtin.waiting": String(localized: "Waiting for Reply")
        case "builtin.receipts": String(localized: "Receipts This Year")
        default: name
        }
    }
}

/// Smart folders (saved searches, SPEC §7) and the semantic "Related" tier of search.
extension AppModel {
    func loadSmartFolders() {
        smartFolders = SmartFolder.builtIns() + ((try? store.smartFolders()) ?? [])
        refreshSmartCounts()
    }

    /// The conversations a smart folder shows, newest first.
    func smartThreads(_ folder: SmartFolder) -> [ThreadSummary] {
        let ids: [String]
        if folder.query == SmartFolder.waitingQuery {
            ids = (try? store.waitingForReplyThreadIDs(ownAddresses: ownAddresses)) ?? []
        } else {
            let hits = (try? SearchEngine(store: store).hits(SearchQuery(parsing: folder.query), limit: 400))?.hits ?? []
            ids = (try? store.threadIDs(forMessageIDs: hits.map(\.id))) ?? []
        }
        return (try? store.threads(mailbox: nil, threadIDs: ids, ownAddresses: ownAddresses)) ?? []
    }

    /// Live counts in the sidebar (after syncs and changes).
    func refreshSmartCounts() {
        var counts: [String: Int] = [:]
        for folder in smartFolders { counts[folder.id] = smartThreads(folder).count }
        smartCounts = counts
    }

    /// ⌘S while searching: keep this search in the sidebar.
    func saveCurrentSearch(named name: String) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !trimmed.isEmpty else { return }
        let folder = SmartFolder(name: trimmed, query: query)
        smartFolders.append(folder)
        try? store.saveSmartFolders(smartFolders)
        refreshSmartCounts()
        selection = .smart(folder.id)
        show(Toast(message: String(localized: "Saved “\(trimmed)” in the sidebar"), symbol: "folder.badge.gearshape"))
    }

    func deleteSmartFolder(_ folder: SmartFolder) {
        guard !folder.isBuiltIn else { return }
        smartFolders.removeAll { $0.id == folder.id }
        try? store.saveSmartFolders(smartFolders)
        if selection == .smart(folder.id) { selection = .inbox }
    }

    // MARK: Semantic search

    /// After a short pause: messages that mean the same as the query but don't share its words
    /// ("Related"), from the on-device embeddings. Only for plain-language queries.
    func scheduleRelated() {
        relatedTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ")
        guard words.count >= 2, !text.contains(":") else { relatedMessages = []; return }
        relatedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            if self.topicEmbedder == nil { self.topicEmbedder = ContextualEmbedder() }
            guard let vector = self.topicEmbedder?.embed(text) else { self.relatedMessages = []; return }
            let shown = Set(self.searchHits.map(\.id))
            let near = (try? self.store.nearest(to: vector, limit: 15, excluding: shown)) ?? []
            guard !Task.isCancelled else { return }
            self.relatedMessages = near.compactMap { (try? self.store.message(id: $0.id)) ?? nil }
        }
    }
}
