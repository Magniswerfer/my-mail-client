import Foundation
import MailEngine
import Observation

enum SidebarItem: Hashable {
    case inbox
    case snoozed
    case category(MailCategory)
    case mailbox(accountID: String, path: String)
}

/// One row in the stream: a conversation, or an Inbox-style bundle of conversations.
enum StreamItem: Identifiable, Hashable {
    case thread(ThreadSummary)
    case bundle(MailCategory, [ThreadSummary])

    var id: String {
        switch self {
        case .thread(let t): t.threadID
        case .bundle(let c, _): "bundle:\(c.rawValue)"
        }
    }

    var date: Date {
        switch self {
        case .thread(let t): t.arrivedAt
        case .bundle(_, let threads): threads.map(\.arrivedAt).max() ?? .distantPast
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
    var isPaletteShown = false
    var sweepCandidate: SweepRequest?
    weak var undoManager: UndoManager?
    @ObservationIgnored var markReadTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?

    // Data
    private(set) var accounts: [AccountConfig] = []
    private(set) var threads: [ThreadSummary] = []
    private(set) var mailboxes: [MailboxState] = []
    private(set) var inboxUnreadCount = 0
    private(set) var syncStatus: [String: String] = [:]
    var lastError: String?

    // Search
    var searchText = "" { didSet { runSearch() } }
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDevServer ? "Tidings-Dev" : "Tidings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dataDirectory = base
        do {
            store = try MailStore(path: base.appendingPathComponent("mail.sqlite").path)
        } catch {
            fatalError("Could not open the mail store at \(base.path): \(error)")
        }
        cache = MessageCache(directory: base.appendingPathComponent("Cache", isDirectory: true))
        accounts = isDevServer ? [Self.devAccount] : AccountStorage.load()
        reload()
    }

    static let devAccount = AccountConfig(
        id: "dev", displayName: "Dev (local Dovecot)",
        endpoint: IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "magnus"),
        addresses: [TestMailFactory.me.address]
    )

    // MARK: Sync

    func start() {
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
            tasks.append(Task { [weak self] in
                let events = await sync.events()
                for await event in events { self?.handle(event, account: account) }
            })
            tasks.append(Task.detached { await sync.run() })
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
        case .failed(let message):
            syncStatus[account.id] = String(localized: "Offline")
            lastError = message
        }
    }

    // MARK: Accounts

    func addAccount(address: String, password: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        let endpoint = IMAPEndpoint.iCloud(address: trimmed)
        // Validate before saving anything: read-only login + capability check.
        _ = try await MailSession.open(endpoint: endpoint, password: password) { session in session.capabilities }
        try Keychain.save(password: password, account: trimmed)
        let account = AccountConfig(displayName: trimmed, endpoint: endpoint, addresses: [trimmed])
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
        case .category(let c): c.title
        case .mailbox(let accountID, let path):
            mailboxes.first { $0.accountID == accountID && $0.path == path }?.role?.title ?? path
        }
    }

    func reload() {
        do {
            switch selection {
            case .inbox:
                threads = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)
                if pinnedOnly { threads = threads.filter(\.isPinned) }
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
    var streamItems: [StreamItem] {
        guard selection == .inbox else { return threads.map(StreamItem.thread) }
        var items: [StreamItem] = []
        var bundles: [MailCategory: [ThreadSummary]] = [:]
        for thread in threads {
            if thread.latest.category == .primary { items.append(.thread(thread)) }
            else { bundles[thread.latest.category, default: []].append(thread) }
        }
        for (category, members) in bundles {
            items.append(.bundle(category, members))
        }
        return items.sorted { $0.date > $1.date }
    }

    /// Flattened rows as displayed (bundles expanded inline), used for j/k navigation.
    var visibleThreadIDs: [String] {
        streamItems.flatMap { item -> [String] in
            switch item {
            case .thread(let t): [t.threadID]
            case .bundle(let c, let members): expandedBundles.contains(c) ? members.map(\.threadID) : []
            }
        }
    }

    func unreadCount(_ category: MailCategory) -> Int {
        (try? store.threads(mailbox: "INBOX").filter { $0.latest.category == category }.reduce(0) { $0 + $1.unreadCount }) ?? 0
    }

    func toggleBundle(_ category: MailCategory) {
        if expandedBundles.contains(category) { expandedBundles.remove(category) } else { expandedBundles.insert(category) }
    }

    func moveSelection(_ delta: Int) {
        let ids = isSearching ? searchHits.compactMap { hit in threadID(forMessage: hit.id) } : visibleThreadIDs
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
