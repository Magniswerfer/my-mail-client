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

    /// Primary (where the Inbox opens), the other five categories, yours, and All always last.
    var categoryTabs: [CategoryTab] {
        MailCategory.allCases.map(CategoryTab.builtIn) + aiCategories.map { .ai($0.id) } + [.all]
    }

    /// Somewhere in the Inbox: All or one of its category tabs. The sidebar shows a single
    /// Inbox row for all of them; the tabs above the list pick between them.
    var isInInbox: Bool { currentCategoryTab != nil }

    /// The sidebar's Inbox, ⌘1 and G I open on Primary; All is one of the tabs.
    /// Every account's Inbox together (the unified one), even when one account's was showing.
    func goToInbox() {
        inboxAccountID = nil
        selection = .category(.primary)
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
        // Only what the All list shows: mail a scheduled bundle holds until its delivery isn't
        // there yet (its own tab still counts it).
        case .all: return unread.filter { !isHeldForDelivery($0) }.count
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
        if selection == .aiCategory(aiCategory.id) { goToInbox() }
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
    }

    func moveAICategories(from: IndexSet, to: Int) {
        aiCategories.move(fromOffsets: from, toOffset: to)
        try? store.saveAICategories(aiCategories)
    }

    // MARK: Sorting (on device)

    /// After each sync: new Inbox mail through every AI category. A new category first sorts
    /// your recent Inbox. Senders you chose "always" for go in directly; the rest need the
    /// on-device model (the judge).
    func scheduleAICategories() {
        let hasJudge = ruleJudge != nil
        let categories = aiCategories.filter { hasJudge || !$0.senders.isEmpty }
        guard aiCategoryTask == nil, !categories.isEmpty else { return }
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
                        if category.includesSender(message.fromAddress) {
                            try? self.store.assign(threadID: thread, to: category.id, byYou: true)
                            changed = true
                        } else if hasJudge, await engine.matches(rule, message) {
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

    // MARK: Moving into your categories

    /// Whether every one of these conversations is already in the category.
    func allIn(aiCategory id: String, _ threads: [ThreadSummary]) -> Bool {
        !threads.isEmpty && threads.allSatisfy { aiMembership[$0.threadID]?.contains(id) == true }
    }

    /// "Move to Investors" for these conversations: they show under its tab (their built-in
    /// category stays) and become examples for the model. Undoable.
    func moveConversations(_ threads: [ThreadSummary], toAICategory id: String) {
        isCategoryPickerShown = false
        guard var category = aiCategory(id: id), !threads.isEmpty else { return }
        let previous = threads.map { ($0.threadID, try? store.membershipSource(threadID: $0.threadID, categoryID: id)) }
        for thread in threads {
            try? store.setMembership(threadID: thread.threadID, categoryID: id, isMember: true)
        }
        let examples = threads.prefix(4).map {
            AboutCondition.Example(text: "\($0.latest.senderDisplay): \($0.latest.subject)", matches: true)
        }
        category.about.examples = Array((category.about.examples + examples).suffix(12))
        replace(aiCategory: category)
        multiSelection = []
        let undoToken = offerUndo(named: String(localized: "Move")) { [weak self] in
            guard let self else { return }
            for (thread, source) in previous {
                try? self.store.restoreMembership(threadID: thread, categoryID: id, source: source)
            }
            self.aiMembership = (try? self.store.aiCategoryMembership()) ?? [:]
            self.toast = nil
            self.reload()
        }
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
        reload()
        show(Toast(message: threads.count == 1 ? String(localized: "Moved to \(category.name)")
                                               : String(localized: "\(threads.count) moved to \(category.name)"),
                   symbol: category.symbol, undo: undoToken))
    }

    /// "Always for GitLab" with one of your categories: their mail goes in now and from now on.
    func moveSender(toAICategory id: String, thread: ThreadSummary? = nil) {
        isCategoryPickerShown = false
        guard var category = aiCategory(id: id), let thread = thread ?? targetThreads.first else { return }
        let address = thread.latest.fromAddress.lowercased()
        let name = thread.latest.senderDisplay
        let hadSender = category.includesSender(address)
        if !hadSender { category.senders.append(address) }
        replace(aiCategory: category)
        let threads = (try? store.threadIDs(fromSender: address)) ?? []
        let previous = threads.map { ($0, try? store.membershipSource(threadID: $0, categoryID: id)) }
        for t in threads { try? store.setMembership(threadID: t, categoryID: id, isMember: true) }
        let undoToken = offerUndo(named: String(localized: "Move")) { [weak self] in
            guard let self else { return }
            if !hadSender, var c = self.aiCategory(id: id) {
                c.senders.removeAll { $0 == address }
                self.replace(aiCategory: c)
            }
            for (t, source) in previous {
                try? self.store.restoreMembership(threadID: t, categoryID: id, source: source)
            }
            self.aiMembership = (try? self.store.aiCategoryMembership()) ?? [:]
            self.toast = nil
            self.reload()
        }
        aiMembership = (try? store.aiCategoryMembership()) ?? [:]
        reload()
        show(Toast(message: String(localized: "Got it: mail from \(name) goes to \(category.name) from now on"),
                   symbol: category.symbol, undo: undoToken))
    }

    private func replace(aiCategory category: AICategory) {
        if let i = aiCategories.firstIndex(where: { $0.id == category.id }) { aiCategories[i] = category }
        try? store.saveAICategories(aiCategories)
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
