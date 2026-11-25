import Foundation
import MailEngine
import Observation

enum SidebarItem: Hashable {
    case inbox
    case snoozed
    /// Conversations set aside with Reply Later (L).
    case replyLater
    case outbox
    case category(MailCategory)
    case mailbox(accountID: String, path: String)
}

/// One row in the stream: a conversation, or an Inbox-style bundle of conversations.
enum StreamItem: Identifiable, Hashable {
    case thread(ThreadSummary)
    /// Delivered conversations of a bundle; `deliveredAt` is set for scheduled bundles.
    case bundle(MailCategory, [ThreadSummary], deliveredAt: Date?)
    /// Conversations set aside with Reply Later, gathered at the top of the Inbox.
    case replyLater([ThreadSummary])

    var id: String {
        switch self {
        case .thread(let t): t.threadID
        case .bundle(let c, _, _): "bundle:\(c.rawValue)"
        case .replyLater: "replyLater"
        }
    }

    var date: Date {
        switch self {
        case .thread(let t): t.arrivedAt
        case .bundle(_, let threads, let deliveredAt): deliveredAt ?? threads.map(\.arrivedAt).max() ?? .distantPast
        case .replyLater: .distantFuture
        }
    }
}

@MainActor @Observable
final class AppModel {
    // Navigation
    var selection: SidebarItem = .inbox {
        didSet {
            if selection != oldValue {
                selectedThreadID = nil
                selectionIndexHint = nil
                heldCategories = [:]
            }
            // Choosing a place in the sidebar leaves search, so the click visibly goes there.
            endSearch()
            reload()
        }
    }
    var selectedThreadID: String? {
        didSet {
            scheduleMarkRead()
            updateReader(debounced: isKeyboardNavigating)
            if let id = selectedThreadID, !isSearching, let index = visibleThreadIDs.firstIndex(of: id) {
                selectionIndexHint = index
            }
        }
    }
    /// Where the selection last was in the list. If the selected conversation leaves the list
    /// without us moving it (another device, a sync), j/k/E carry on from here instead of
    /// starting over at the top.
    @ObservationIgnored var selectionIndexHint: Int?
    /// The category each conversation was shown under, for a category you're looking at or a
    /// bundle you've opened. The background classifier keeps learning after each sync, and
    /// without this a conversation could hop to another bundle (taking rows with it) while
    /// you triage. Released when you leave the view, collapse the bundle, or move it yourself.
    @ObservationIgnored var heldCategories: [String: MailCategory] = [:]

    /// The category a conversation is shown under: where you saw it, else its current one.
    func displayCategory(_ thread: ThreadSummary) -> MailCategory {
        heldCategories[thread.threadID] ?? thread.latest.category
    }

    /// Lets these conversations follow their category again (you moved them on purpose).
    func releaseHolds(_ threadIDs: some Sequence<String>) {
        for id in threadIDs { heldCategories[id] = nil }
    }
    /// What the reader shows. Follows the selection at once for clicks, and after a short pause
    /// while j/k are being pressed, so fast navigation never waits on rendering mail.
    private(set) var readerThreadID: String?
    /// Direction of the last j/k move (+1/-1, 0 for clicks); the list keeps one row of lookahead.
    @ObservationIgnored var lastMoveDirection = 0
    /// Set while j/k or a triage key moves the selection, so the reader waits for a pause.
    @ObservationIgnored var isKeyboardNavigating = false
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    /// Conversations just acted on (Done, Snooze, …) that stay hidden until the engine catches up,
    /// so a row leaves the list in the same instant the selection moves on.
    @ObservationIgnored var pendingRemovals: Set<String> = []

    private func updateReader(debounced: Bool) {
        readerTask?.cancel()
        guard debounced else {
            readerThreadID = selectedThreadID
            return
        }
        readerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.readerThreadID = self.selectedThreadID
        }
    }
    var expandedBundles: Set<MailCategory> = []
    /// Where an open bundle sits in the stream, captured when it's opened. A bundle is placed by
    /// its newest conversation, so without this, archiving that one would move the whole open
    /// bundle down the list mid-triage. It can still move up (new mail), never down.
    @ObservationIgnored private var bundleAnchors: [MailCategory: Date] = [:]
    /// Open bundles that were pinned to the top (they had new mail) when opened; they stay there until collapsed.
    @ObservationIgnored private var pinnedOpenBundles: Set<MailCategory> = []
    /// Show only pinned conversations (Google Inbox's pin toggle).
    var pinnedOnly = false { didSet { reload() } }

    // Triage UI
    var toast: Toast?
    var isSnoozePickerShown = false
    /// A conversation to snooze that isn't the selection (iPhone swipe); nil means the selection.
    var snoozeTarget: String?
    var isCategoryPickerShown = false
    var isFolderPickerShown = false
    var isPaletteShown = false
    var sweepCandidate: SweepRequest?
    weak var undoManager: UndoManager?
    /// Set by the root view: opens a composer window for a draft id.
    @ObservationIgnored var openComposeWindow: ((Int64) -> Void)?
    var outboxItems: [OutboxItem] = []
    var draftItems: [OutboxItem] = []
    /// Follow-ups Tidings drafted for conversations still waiting on someone (Auto Drafts).
    var autoDrafts: [AutoDraft] = []

    // Assistant (on-device): summaries, follow-up drafts. Nil writer = no Apple Intelligence.
    @ObservationIgnored var writer: (any MailWriter)?
    @ObservationIgnored var writerChecked = false
    @ObservationIgnored var autoDraftTask: Task<Void, Never>?

    // Reply Later: the focused answering session, when open.
    var replySession: ReplySession?
    var isShortcutsShown = false
    /// The app's model, for App Intents and links that arrive without a view.
    @ObservationIgnored static weak var shared: AppModel?

    // Rules (SPEC §6)
    var rules: [Rule] = []
    /// Conversations each rule acted on in the last 7 days.
    var ruleCounts: [String: Int] = [:]
    var isRulesShown = false
    /// The rule open in the editor (new or existing).
    var editingRule: Rule?
    @ObservationIgnored var ruleTask: Task<Void, Never>?
    /// Decides "about …" conditions on device; nil until the embedding model has loaded, or
    /// when neither embeddings nor Foundation Models are available.
    var ruleJudge: OnDeviceRuleJudge?
    /// Turns a sentence into a rule (Foundation Models); nil without Apple Intelligence.
    @ObservationIgnored let ruleDrafter: (any RuleDrafter)? = FoundationModelsRuleDrafter()

    // Contact sidebar
    var isContactPanelShown = false
    /// Whose profile the panel shows; nil follows the open conversation.
    var contactAddress: String?
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
    var revision = 0
    @ObservationIgnored var deliveryTask: Task<Void, Never>?
    @ObservationIgnored var reloadTask: Task<Void, Never>?
    /// When a triage action last removed a row; quick repeats skip the animation.
    @ObservationIgnored var lastRemovalAt = Date.distantPast

    // Data
    var accounts: [AccountConfig] = []
    internal(set) var threads: [ThreadSummary] = []
    private(set) var mailboxes: [MailboxState] = []
    private(set) var inboxUnreadCount = 0
    /// How many conversations are set aside with Reply Later (the sidebar badge).
    private(set) var replyLaterCount = 0
    private(set) var syncStatus: [String: String] = [:]
    var lastError: String?

    // Search
    var searchText = "" { didSet { selectedHitID = nil; runSearch() } }
    /// Bumped when search is left on purpose (a place picked, a link opened), so the window can
    /// move focus to the list. Emptying the field by typing doesn't count: you're still searching.
    private(set) var searchEndedCount = 0

    func endSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
        searchEndedCount &+= 1
    }
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
                accounts[index].identities = [Identity(address: accounts[index].endpoint.username, name: Platform.fullUserName)]
                changed = true
            }
            if changed { AccountStorage.save(accounts) }
        }
        reload()
        reloadOutbox()
        loadRules()
        scheduleDeliveryRefresh()
        Self.shared = self
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
                let judge = OnDeviceRuleJudge(store: store, embedder: loaded?.embedder)
                await MainActor.run {
                    self?.refinement = loaded
                    self?.ruleJudge = judge
                }
            }
        }
        for account in accounts where syncs[account.id] == nil {
            guard let sync = makeSync(for: account) else { continue }
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

    private func makeSync(for account: AccountConfig) -> AccountSync? {
        let password: String
        if account.id == "dev" {
            password = "tidings-test"
        } else if let stored = Keychain.password(account: account.endpoint.username) {
            password = stored
        } else {
            lastError = String(localized: "No password in the Keychain for \(account.endpoint.username).")
            return nil
        }
        return AccountSync(account: account, password: password, store: store, cache: cache,
                           profile: account.id == "dev" ? .iCloudSimulation : nil)
    }

    // MARK: Foreground and background (iPhone)

    /// Closes every connection. `start()` opens them again.
    func stopSync() {
        for task in tasks { task.cancel() }
        tasks = []
        syncs = [:]
    }

    /// Before iOS suspends the app: mail in its undo-send window goes now, queued Done/Pin/Snooze
    /// reach the server, then the connections close (a suspended app's sockets die anyway).
    /// Send-later mail stays queued for the next catch-up.
    func finishWorkBeforeSuspending(timeout: Duration = .seconds(25)) async {
        let soon = Date().addingTimeInterval(AccountSync.defaultUndoSendDelay + 5)
        let due = ((try? store.outbox()) ?? []).filter { $0.state == .queued && ($0.sendAt ?? .distantPast) <= soon }
        for item in due {
            if let id = item.id { try? await syncs[item.accountID]?.retrySend(id: id) }
        }
        let dueIDs = Set(due.compactMap(\.id))
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let outbox = (try? store.outbox()) ?? []
            let sending = outbox.contains { item in item.id.map(dueIDs.contains) == true && (item.state == .queued || item.state == .sending) }
            let pending = accounts.contains { !((try? store.pendingActions(accountID: $0.id)) ?? []).isEmpty }
            if !sending && !pending { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        stopSync()
        reloadOutbox()
    }

    /// iOS background refresh: one catch-up per account on its own connection.
    func backgroundCatchUp() async {
        for account in accounts {
            guard let sync = makeSync(for: account) else { continue }
            try? await sync.catchUp()
        }
        reload()
        reloadOutbox()
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
            scheduleAutoDrafts()
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

    /// One background sorting pass after each sync, never two at once; then your rules, which
    /// come after AI sorting so they can read and override the category (SPEC §6).
    func scheduleRefinement() {
        guard refinementTask == nil else { return }
        guard let refinement else {
            scheduleRules()
            return
        }
        isRefining = true
        refinementTask = Task { [weak self] in
            let report = try? await refinement.run()
            guard let self else { return }
            self.isRefining = false
            self.refinementTask = nil
            if (report?.changed ?? 0) > 0 { self.reload() }
            self.scheduleRules()
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
                                    identities: [Identity(address: trimmed, name: Platform.fullUserName)])
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
        case .replyLater: String(localized: "Set Aside")
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
            // One read of the Inbox serves the stream, a category and the unread count.
            var inboxCache: [ThreadSummary]?
            func inbox() throws -> [ThreadSummary] {
                if let inboxCache { return inboxCache }
                let loaded = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)
                inboxCache = loaded
                return loaded
            }
            switch selection {
            case .inbox:
                threads = try inbox()
                if pinnedOnly { threads = threads.filter(\.isPinned) }
            case .outbox:
                threads = []
            case .snoozed:
                threads = try store.threads(mailbox: AccountSync.snoozedMailbox, ownAddresses: ownAddresses)
                    .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            case .replyLater:
                threads = try inbox().filter(\.isReplyLater)
            case .category(let category):
                // Set-aside conversations live in Set Aside, as they do in the Inbox's Reply Later row.
                threads = try inbox().filter { !$0.isReplyLater && displayCategory($0) == category }
                for thread in threads where heldCategories[thread.threadID] == nil { heldCategories[thread.threadID] = category }
            case .mailbox(let accountID, let path):
                threads = try store.threads(mailbox: path, accountID: accountID, ownAddresses: ownAddresses)
            }
            if !pendingRemovals.isEmpty { threads.removeAll { pendingRemovals.contains($0.threadID) } }
            if selection == .inbox { holdOpenBundles() }
            mailboxes = try accounts.flatMap { try store.mailboxStates(accountID: $0.id) }
            inboxUnreadCount = try inbox().filter { $0.latest.category == .primary }.reduce(0) { $0 + $1.unreadCount }
            replyLaterCount = try inbox().filter(\.isReplyLater).count
        } catch {
            lastError = String(describing: error)
        }
    }

    /// A reload a moment from now, folding together the ones asked for in the meantime
    /// (pressing E ten times in a row reads the store once, not ten times).
    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.reloadTask = nil
            self.reload()
        }
    }

    /// The Inbox stream: primary conversations as rows, every other category collapsed into a
    /// bundle placed where its newest conversation would be.
    /// Conversations held back until a bundle's next delivery, with when that is.
    func waiting(_ category: MailCategory) -> (count: Int, next: Date)? {
        guard let schedule = bundleSchedules[category], let last = schedule.lastDelivery(before: now),
              let next = schedule.nextDelivery(after: now) else { return nil }
        let count = threads.filter { displayCategory($0) == category && $0.arrivedAt > last }.count
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
        let later = threads.filter(\.isReplyLater)
        if !later.isEmpty { items.append(.replyLater(later)) }
        for thread in threads where !thread.isReplyLater {
            let category = displayCategory(thread)
            if category == .primary { items.append(.thread(thread)) }
            else { bundles[category, default: []].append(thread) }
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
        return items.sorted { a, b in
            let (ta, tb) = (tier(a), tier(b))
            return ta != tb ? ta > tb : sortDate(a) > sortDate(b)
        }
    }

    /// Reply Later sits on top, then bundles with new mail, then everything by time.
    private func tier(_ item: StreamItem) -> Int {
        switch item {
        case .replyLater: 2
        case .bundle(let category, let members, _): isBundlePinned(category, members) ? 1 : 0
        case .thread: 0
        }
    }

    /// A bundle with unread mail is pinned to the top of the Inbox. An open bundle keeps the
    /// place it had when you opened it, so reading or clearing it doesn't send it down the list.
    private func isBundlePinned(_ category: MailCategory, _ members: [ThreadSummary]) -> Bool {
        if expandedBundles.contains(category) { return pinnedOpenBundles.contains(category) }
        return members.contains { $0.unreadCount > 0 }
    }

    private func sortDate(_ item: StreamItem) -> Date {
        if case .bundle(let category, _, _) = item, let anchor = bundleAnchors[category] { return max(anchor, item.date) }
        return item.date
    }

    /// Flattened rows as displayed (bundles expanded inline), used for j/k navigation.
    var visibleThreadIDs: [String] {
        streamItems.flatMap { item -> [String] in
            switch item {
            case .thread(let t): [t.threadID]
            case .bundle(let c, let members, _): expandedBundles.contains(c) ? members.map(\.threadID) : []
            case .replyLater: []
            }
        }
    }

    func unreadCount(_ category: MailCategory) -> Int {
        (try? store.threads(mailbox: "INBOX").filter { $0.latest.category == category }.reduce(0) { $0 + $1.unreadCount }) ?? 0
    }

    func toggleBundle(_ category: MailCategory) {
        if expandedBundles.contains(category) {
            expandedBundles.remove(category)
            bundleAnchors[category] = nil
            pinnedOpenBundles.remove(category)
            heldCategories = expandedBundles.isEmpty ? [:] : heldCategories.filter { $0.value != category }
        } else {
            if let item = streamItems.first(where: { if case .bundle(category, _, _) = $0 { true } else { false } }) {
                bundleAnchors[category] = sortDate(item)
                if tier(item) == 1 { pinnedOpenBundles.insert(category) }
            }
            expandedBundles.insert(category)
            holdOpenBundles()
        }
    }

    /// While a bundle is open, conversations stay where they're shown, in it or around it, so
    /// rows don't move in or out of it mid-triage (see `heldCategories`).
    private func holdOpenBundles() {
        guard !expandedBundles.isEmpty else { return }
        for thread in threads where heldCategories[thread.threadID] == nil {
            heldCategories[thread.threadID] = thread.latest.category
        }
    }

    /// "Check for New Mail" (⇧⌘N): every folder of every account, now.
    func checkForNewMail() {
        start()
        for (accountID, sync) in syncs {
            syncStatus[accountID] = String(localized: "Checking for new mail…")
            Task { await sync.checkNow() }
        }
    }

    /// j/k: the next/previous conversation in the stream, or result while searching.
    /// The lists scroll to follow (StreamView / SearchResultsView).
    func moveSelection(_ delta: Int) {
        if isSearching {
            let ids = searchHits.map(\.id)
            guard !ids.isEmpty else { return }
            let index = selectedHitID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
            lastMoveDirection = delta > 0 ? 1 : -1
            isKeyboardNavigating = true
            selectedHitID = ids[max(0, min(ids.count - 1, index + delta))]
            isKeyboardNavigating = false
            return
        }
        let ids = visibleThreadIDs
        guard !ids.isEmpty else { return }
        // If the selection has left the list, the row that took its place is "next".
        let index = selectedThreadID.flatMap { ids.firstIndex(of: $0) }
            ?? selectionIndexHint.map { delta > 0 ? $0 - 1 : $0 }
            ?? (delta > 0 ? -1 : ids.count)
        lastMoveDirection = delta > 0 ? 1 : -1
        isKeyboardNavigating = true
        selectedThreadID = ids[max(0, min(ids.count - 1, index + delta))]
        isKeyboardNavigating = false
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
