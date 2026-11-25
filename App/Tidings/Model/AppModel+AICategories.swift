import Foundation
import MailEngine
import SwiftUI

/// Opens the AI category editor (new, or editing one).
struct AICategoryEditing: Identifiable {
    let id = UUID()
    var category: AICategory
    var isNew: Bool
}

/// One tab in the Inbox's category bar (Tab / ⇧Tab cycle them).
enum CategoryTab: Hashable, Identifiable {
    case all
    case builtIn(MailCategory)
    case ai(String)

    var id: String {
        switch self {
        case .all: "all"
        case .builtIn(let c): "c.\(c.rawValue)"
        case .ai(let id): "ai.\(id)"
        }
    }

    var selection: SidebarItem {
        switch self {
        case .all: .inbox
        case .builtIn(let c): .category(c)
        case .ai(let id): .aiCategory(id)
        }
    }
}

extension AppModel {
    // MARK: Tabs

    /// All, the six categories, then yours, in order.
    var categoryTabs: [CategoryTab] {
        [.all] + MailCategory.allCases.map(CategoryTab.builtIn) + aiCategories.map { .ai($0.id) }
    }

    /// The tab for what's on screen, if it's one of them.
    var currentCategoryTab: CategoryTab? {
        switch selection {
        case .inbox: .all
        case .category(let c): .builtIn(c)
        case .aiCategory(let id): .ai(id)
        default: nil
        }
    }

    /// Tab / ⇧Tab, ⌘] / ⌘[: the next or previous category (wraps; from elsewhere starts at All).
    func cycleCategory(_ delta: Int) {
        let tabs = categoryTabs
        guard !tabs.isEmpty else { return }
        let index = currentCategoryTab.flatMap(tabs.firstIndex) ?? (delta > 0 ? -1 : 0)
        let next = (index + delta + tabs.count) % tabs.count
        selection = tabs[next].selection
    }

    func aiCategory(id: String) -> AICategory? { aiCategories.first { $0.id == id } }

    /// Unread conversations per tab, from the Inbox already loaded for the stream.
    func unreadCount(for tab: CategoryTab, inbox: [ThreadSummary]) -> Int {
        let unread = inbox.filter { $0.unreadCount > 0 && !$0.isReplyLater }
        switch tab {
        case .all: return unread.count
        case .builtIn(let c): return unread.filter { displayCategory($0) == c }.count
        case .ai(let id): return unread.filter { aiMembership[$0.threadID]?.contains(id) == true }.count
        }
    }

    // MARK: Storage

    func loadAICategories() {
        aiCategories = (try? store.aiCategories()) ?? []
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
    }

    func save(aiCategory: AICategory, isNew: Bool, descriptionChanged: Bool) {
        if let i = aiCategories.firstIndex(where: { $0.id == aiCategory.id }) { aiCategories[i] = aiCategory } else { aiCategories.append(aiCategory) }
        try? store.saveAICategories(aiCategories)
        if descriptionChanged, !isNew { try? store.resetAICategory(aiCategory.id) }
        scheduleAICategories()
        if isNew {
            selection = .aiCategory(aiCategory.id)
            show(Toast(message: assistant == nil
                       ? String(localized: "“\(aiCategory.name)” is ready. Without Apple Intelligence, add conversations to it yourself.")
                       : String(localized: "Sorting your recent mail into “\(aiCategory.name)”…"),
                       symbol: aiCategory.symbol))
        }
    }

    func delete(aiCategory: AICategory) {
        aiCategories.removeAll { $0.id == aiCategory.id }
        try? store.saveAICategories(aiCategories)
        if selection == .aiCategory(aiCategory.id) { selection = .inbox }
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
    }

    func moveAICategories(from: IndexSet, to: Int) {
        aiCategories.move(fromOffsets: from, toOffset: to)
        try? store.saveAICategories(aiCategories)
    }

    // MARK: Sorting (on device)

    /// After each sync: new Inbox mail through every AI category. A new category first sorts
    /// your recent Inbox. Runs only with the on-device model (the judge).
    func scheduleAICategories() {
        guard aiCategoryTask == nil, !aiCategories.isEmpty, ruleJudge != nil else { return }
        let categories = aiCategories
        let engine = ruleEngine
        aiCategoryTask = Task { [weak self] in
            guard let self else { return }
            var changed = false
            for category in categories {
                let rule = self.calibrated(category.asRule)
                for _ in 0..<5 {   // at most a few batches per pass; the rest next time
                    let batch = (try? self.store.messagesToSort(into: category.id, ownAddresses: self.ownAddresses)) ?? []
                    guard let last = batch.last?.id else { break }
                    for message in batch {
                        guard let thread = message.threadID else { continue }
                        if await engine.matches(rule, message) {
                            try? self.store.assign(threadID: thread, to: category.id)
                            changed = true
                        }
                    }
                    try? self.store.markSorted(into: category.id, upTo: last)
                    if Task.isCancelled { break }
                }
            }
            self.aiCategoryTask = nil
            if changed {
                self.aiMembership = (try? self.store.aiCategoryMembership()) ?? [:]
                self.reload()
            }
        }
    }

    // MARK: Corrections

    /// "In Investors" ✓/✗ from the context menu: sticks, and becomes an example for the model.
    func toggle(aiCategory id: String, for thread: ThreadSummary) {
        guard var category = aiCategory(id: id) else { return }
        let isMember = aiMembership[thread.threadID]?.contains(id) == true
        try? store.setMembership(threadID: thread.threadID, categoryID: id, isMember: !isMember)
        let example = AboutCondition.Example(text: "\(thread.latest.senderDisplay): \(thread.latest.subject)", matches: !isMember)
        category.about.examples = Array((category.about.examples + [example]).suffix(12))
        if let i = aiCategories.firstIndex(where: { $0.id == id }) { aiCategories[i] = category }
        try? store.saveAICategories(aiCategories)
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
        reload()
        show(Toast(message: isMember ? String(localized: "Removed from “\(category.name)”") : String(localized: "Added to “\(category.name)”"),
                   symbol: category.symbol))
    }

    /// What a new or edited category would catch in your recent mail (on-device).
    func previewAICategory(_ category: AICategory) async -> [StoredMessage] {
        guard ruleJudge != nil else { return [] }
        return (try? await ruleEngine.preview(calibrated(category.asRule), store: store, limit: 300)) ?? []
    }
}
