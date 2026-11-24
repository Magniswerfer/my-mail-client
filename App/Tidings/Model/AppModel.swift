import AppKit
import Foundation
import MailEngine
import Observation

enum SidebarItem: Hashable {
    case inbox
    case snoozed
    case outbox
    case category(MailCategory)
    case mailbox(accountID: String, path: String)
}

/// One row in the stream: a conversation, or an Inbox-style bundle of conversations.
enum StreamItem: Identifiable, Hashable {
    case thread(ThreadSummary)
    /// Delivered conversations of a bundle; `deliveredAt` is set for scheduled bundles.
    case bundle(MailCategory, [ThreadSummary], deliveredAt: Date?)

    var id: String {
        switch self {
        case .thread(let t): t.threadID
        case .bundle(let c, _, _): "bundle:\(c.rawValue)"
        }
    }

    var date: Date {
        switch self {
        case .thread(let t): t.arrivedAt
        case .bundle(_, let threads, let deliveredAt): deliveredAt ?? threads.map(\.arrivedAt).max() ?? .distantPast
        }
    }
}

@MainActor @Observable
final class AppModel {
    // Navigation
    var selection: SidebarItem = .inbox {
        didSet {
            if selection != oldValue { selectedThreadID = nil }
            // Choosing a place in the sidebar leaves search, so the click visibly goes there.
            if !searchText.isEmpty { searchText = "" }
            reload()
        }
    }
    var selectedThreadID: String? { didSet { scheduleMarkRead() } }
    var expandedBundles: Set<MailCategory> = []
    /// Show only pinned conversations (Google Inbox's pin toggle).
    var pinnedOnly = false { didSet { reload() } }

    // Triage UI
    var toast: Toast?
    var isSnoozePickerShown = false
    var isCategoryPickerShown = false
    var isPaletteShown = false
    var sweepCandidate: SweepRequest?
    weak var undoManager: UndoManager?
    /// Set by the root view: opens a composer window for a draft id.
    @ObservationIgnored var openComposeWindow: ((Int64) -> Void)?
    var outboxItems: [OutboxItem] = []
    var draftItems: [OutboxItem] = []
    @ObservationIgnored var markReadTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    /// Layers 2–3 of the classifier (on-device embeddings + Foundation Models); nil if unavailable.
    @ObservationIgnored var refinement: Refinement?
    @ObservationIgnored var refinementTask: Task<Void, Never>?
    private(set) var isRefining = false
    var bundleSchedules: [MailCategory: BundleSchedule] = BundleScheduleStorage.load()
    /// "Now" for delivery schedules; bumped at each delivery so the stream re-renders.
    var now = Date()
    /// Bumped on every reload so views that read the store directly (the reader) redraw.
    private(set) var revision = 0
    @ObservationIgnored var deliveryTask: Task<Void, Never>?

    // Data
    var accounts: [AccountConfig] = []
    private(set) var threads: [ThreadSummary] = []
    private(set) var mailboxes: [MailboxState] = []
    private(set) var inboxUnreadCount = 0
    private(set) var syncStatus: [String: String] = [:]
    var lastError: String?

    // Search
    var searchText = "" { didSet { selectedHitID = nil; runSearch() } }
    /// The highlighted search result; selecting one opens its conversation.
    var selectedHitID: Int64? {
        didSet { if let id = selectedHitID { selectedThreadID = threadID(forMessage: id) } }
    }
    private(set) var searchHits: [SearchHit] = []
    private(set) var facets: SearchFacets?
    private(set) var searchMilliseconds: Double = 0
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var needsAccountSetup: Bool { accounts.isEmpty }

    let store: MailStore
    let cache: MessageCache
    let dataDirectory: URL
    let isDevServer: Bool
    var syncs: [String: AccountSync] = [:]
    private var tasks: [Task<Void, Never>] = []

    init() {
        isDevServer = ProcessInfo.processInfo.arguments.contains("-TidingsDevServer")
            || ProcessInfo.processInfo.environment["TIDINGS_DEV_SERVER"] == "1"
        let devUser = UserDefaults.standard.string(forKey: "TidingsDevUser") ?? "magnus"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDevServer ? (devUser == "magnus" ? "Tidings-Dev" : "Tidings-Dev-\(devUser)") : "Tidings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dataDirectory = base
        do {
            store = try MailStore(path: base.appendingPathComponent("mail.sqlite").path)
        } catch {
            fatalError("Could not open the mail store at \(base.path): \(error)")
        }
        cache = MessageCache(directory: base.appendingPathComponent("Cache", isDirectory: true))
        var dev = Self.devAccount
        dev.endpoint.username = devUser
        accounts = isDevServer ? [dev] : AccountStorage.load()
        if !isDevServer {
            var changed = false
            for index in accounts.indices where accounts[index].identities == nil {
                accounts[index].identities = [Identity(address: accounts[index].endpoint.username, name: NSFullUserName())]
                changed = true
            }
            if changed { AccountStorage.save(accounts) }
        }
        reload()
        reloadOutbox()
        scheduleDeliveryRefresh()
    }

    static let devAccount = AccountConfig(
        id: "dev", displayName: "Dev (local Dovecot)",
        endpoint: IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "magnus"),
        addresses: [TestMailFactory.me.address],
        smtp: SMTPEndpoint(host: "127.0.0.1", port: 31587, security: .startTLS, username: TestMailFactory.me.address,
                           allowSelfSignedLocalhost: true),
        identities: [Identity(address: TestMailFactory.me.address, name: "Magnus Kaspersen", signature: "Magnus"),
                     Identity(address: "m@tidings.test", name: "Magnus H. Kaspersen", signature: "Magnus H. Kaspersen\nTidings")]
    )

    // MARK: Sync

    func start() {
        if refinement == nil {
            // Loading the embedding model takes a moment: keep it off the main thread.
            let store = self.store
            Task.detached { [weak self] in
                let loaded = Refinement.onDevice(store: store)
                await MainActor.run { self?.refinement = loaded }
            }
        }
        for account in accounts where syncs[account.id] == nil {
            let password: String
            if account.id == "dev" {
                password = "tidings-test"
            } else if let stored = Keychain.password(account: account.endpoint.username) {
                password = stored
            } else {
                lastError = String(localized: "No password in the Keychain for \(account.endpoint.username).")
                continue
            }
            let sync = AccountSync(account: account, password: password, store: store, cache: cache,
                                   profile: account.id == "dev" ? .iCloudSimulation : nil)
            syncs[account.id] = sync
            // Subscribe before starting the loop, or a fast first sync can finish (and emit
            // everything, including "idle") before anyone is listening.
            tasks.append(Task { [weak self] in
                let events = await sync.events()
                self?.tasks.append(Task.detached { await sync.run() })
                for await event in events { self?.handle(event, account: account) }
            })
        }
    }

    private func handle(_ event: AccountSync.Event, account: AccountConfig) {
        switch event {
        case .started: syncStatus[account.id] = String(localized: "Syncing…")
        case .mailboxProgress(let mailbox, let done, let total):
            syncStatus[account.id] = String(localized: "\(mailbox): \(done) of \(total)")
            if done % 100 == 0 || done == total { reload() }
        case .mailboxSynced: reload()
        case .idle:
            syncStatus[account.id] = String(localized: "Up to date")
            lastError = nil
            reload()
            scheduleRefinement()
        case .failed(let message):
            syncStatus[account.id] = String(localized: "Offline")
            lastError = message
        case .sending:
            syncStatus[account.id] = String(localized: "Sending…")
            reloadOutbox()
        case .sent:
            reloadOutbox()
            if case .some(let t) = toast, t.undoSend != nil { show(Toast(message: String(localized: "Sent"), symbol: "checkmark")) }
        case .sendFailed(_, let message):
            reloadOutbox()
            lastError = message
            show(Toast(message: String(localized: "Couldn't send: \(message)"), symbol: "exclamationmark.triangle"))
        }
    }

    /// One background sorting pass after each sync, never two at once.
    func scheduleRefinement() {
        guard refinementTask == nil, let refinement else { return }
        isRefining = true
        refinementTask = Task { [weak self] in
            let report = try? await refinement.run()
            guard let self else { return }
            self.isRefining = false
            self.refinementTask = nil
            if (report?.changed ?? 0) > 0 { self.reload() }
        }
    }

    // MARK: Accounts

    func addAccount(address: String, password: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        let endpoint = IMAPEndpoint.iCloud(address: trimmed)
        // Validate before saving anything: read-only login + capability check.
        _ = try await MailSession.open(endpoint: endpoint, password: password) { session in session.capabilities }
        try Keychain.save(password: password, account: trimmed)
        let account = AccountConfig(displayName: trimmed, endpoint: endpoint, addresses: [trimmed],
                                    identities: [Identity(address: trimmed, name: NSFullUserName())])
        accounts.append(account)
        AccountStorage.save(accounts)
        start()
    }

    // MARK: Loading

    var ownAddresses: Set<String> { Set(accounts.flatMap(\.addresses)) }

    var currentMailboxTitle: String {
        switch selection {
        case .inbox: String(localized: "Inbox")
        case .snoozed: String(localized: "Snoozed")
        case .outbox: String(localized: "Outbox")
        case .category(let c): c.title
        case .mailbox(let accountID, let path):
            mailboxes.first { $0.accountID == accountID && $0.path == path }?.role?.title ?? path
        }
    }

    func reload() {
        now = Date()
        revision &+= 1
        do {
            switch selection {
            case .inbox:
                threads = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)
                if pinnedOnly { threads = threads.filter(\.isPinned) }
            case .outbox:
                threads = []
            case .snoozed:
                threads = try store.threads(mailbox: AccountSync.snoozedMailbox, ownAddresses: ownAddresses)
                    .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            case .category(let category):
                threads = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses).filter { $0.latest.category == category }
            case .mailbox(let accountID, let path):
                threads = try store.threads(mailbox: path, accountID: accountID, ownAddresses: ownAddresses)
            }
            mailboxes = try accounts.flatMap { try store.mailboxStates(accountID: $0.id) }
            inboxUnreadCount = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)
                .filter { $0.latest.category == .primary }.reduce(0) { $0 + $1.unreadCount }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The Inbox stream: primary conversations as rows, every other category collapsed into a
    /// bundle placed where its newest conversation would be.
    /// Conversations held back until a bundle's next delivery, with when that is.
    func waiting(_ category: MailCategory) -> (count: Int, next: Date)? {
        guard let schedule = bundleSchedules[category], let last = schedule.lastDelivery(before: now),
              let next = schedule.nextDelivery(after: now) else { return nil }
        let count = threads.filter { $0.latest.category == category && $0.arrivedAt > last }.count
        return count > 0 ? (count, next) : nil
    }

    func setSchedule(_ schedule: BundleSchedule, for category: MailCategory) {
        bundleSchedules[category] = schedule
        BundleScheduleStorage.save(bundleSchedules)
        scheduleDeliveryRefresh()
    }

    /// Re-renders the stream when the next bundle is delivered.
    func scheduleDeliveryRefresh() {
        deliveryTask?.cancel()
        guard let next = bundleSchedules.values.compactMap({ $0.nextDelivery(after: Date()) }).min() else { return }
        deliveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled else { return }
            self?.now = Date()
            self?.scheduleDeliveryRefresh()
        }
    }

    var streamItems: [StreamItem] {
        guard selection == .inbox else { return threads.map(StreamItem.thread) }
        var items: [StreamItem] = []
        var bundles: [MailCategory: [ThreadSummary]] = [:]
        for thread in threads {
            if thread.latest.category == .primary { items.append(.thread(thread)) }
            else { bundles[thread.latest.category, default: []].append(thread) }
        }
        for (category, members) in bundles {
            // Scheduled bundles show what arrived before their last delivery; the rest waits.
            if let delivered = bundleSchedules[category]?.lastDelivery(before: now) {
                let ready = members.filter { $0.arrivedAt <= delivered }
                if !ready.isEmpty { items.append(.bundle(category, ready, deliveredAt: delivered)) }
            } else {
                items.append(.bundle(category, members, deliveredAt: nil))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    /// Flattened rows as displayed (bundles expanded inline), used for j/k navigation.
    var visibleThreadIDs: [String] {
        streamItems.flatMap { item -> [String] in
            switch item {
            case .thread(let t): [t.threadID]
            case .bundle(let c, let members, _): expandedBundles.contains(c) ? members.map(\.threadID) : []
            }
        }
    }

    func unreadCount(_ category: MailCategory) -> Int {
        (try? store.threads(mailbox: "INBOX").filter { $0.latest.category == category }.reduce(0) { $0 + $1.unreadCount }) ?? 0
    }

    func toggleBundle(_ category: MailCategory) {
        if expandedBundles.contains(category) { expandedBundles.remove(category) } else { expandedBundles.insert(category) }
    }

    /// j/k: the next/previous conversation in the stream, or result while searching.
    /// The lists scroll to follow (StreamView / SearchResultsView).
    func moveSelection(_ delta: Int) {
        if isSearching {
            let ids = searchHits.map(\.id)
            guard !ids.isEmpty else { return }
            let index = selectedHitID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
            selectedHitID = ids[max(0, min(ids.count - 1, index + delta))]
            return
        }
        let ids = visibleThreadIDs
        guard !ids.isEmpty else { return }
        let index = selectedThreadID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selectedThreadID = ids[max(0, min(ids.count - 1, index + delta))]
    }

    // MARK: Search

    private func runSearch() {
        let query = SearchQuery(parsing: searchText)
        guard !query.isEmpty else {
            searchHits = []
            facets = nil
            return
        }
        let engine = SearchEngine(store: store)
        do {
            let hits = try engine.hits(query)
            searchHits = hits.hits
            searchMilliseconds = Double(hits.duration.components.attoseconds) / 1e15
            facets = query.wantsFacets ? try engine.facets(query) : nil
        } catch {
            searchHits = []
            facets = nil
        }
    }

    func addSearchFilter(_ token: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(token) else { return }
        searchText = trimmed.isEmpty ? token : "\(trimmed) \(token)"
    }

    func threadID(forMessage id: Int64) -> String? {
        (try? store.message(id: id))?.threadID
    }

    // MARK: Reading

    func messages(inThread threadID: String) -> [StoredMessage] {
        (try? store.messages(inThread: threadID)) ?? []
    }

    func rawMessage(_ message: StoredMessage) async throws -> Data {
        guard let sync = syncs[message.accountID] else {
            throw MailSessionError.commandFailed(command: "read", detail: "account is not connected")
        }
        return try await sync.rawMessage(message)
    }
}

/// Account list persistence. Passwords live only in the Keychain.
enum AccountStorage {
    static let key = "accounts.v1"

    static func load() -> [AccountConfig] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AccountConfig].self, from: data)) ?? []
    }

    static func save(_ accounts: [AccountConfig]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: key)
    }
}
