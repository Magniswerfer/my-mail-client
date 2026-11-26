import Foundation
import MailEngine
import Observation

enum SidebarItem: Hashable {
    case inbox
    /// One account's Inbox (sidebar row under the unified Inbox). The model shows it as the
    /// Inbox with `inboxAccountID` set; `selection` itself never holds this.
    case accountInbox(String)
    case snoozed
    /// Conversations set aside with Reply Later (L).
    case replyLater
    case outbox
    case category(MailCategory)
    case mailbox(accountID: String, path: String)
    /// A saved search (SPEC §7), by id.
    case smartFolder(String)
    /// A category you described, sorted by the on-device model, by id.
    case aiCategory(String)
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
    var selection: SidebarItem = .category(.primary) {
        didSet {
            // One account's Inbox is a filter on the Inbox: leaving the Inbox ends it.
            if !isInInbox { inboxAccountID = nil }
            if selection != oldValue {
                selectedThreadID = nil
                selectionIndexHint = nil
                heldCategories = [:]
                isSelecting = false
            }
            // Choosing a place in the sidebar leaves search, so the click visibly goes there.
            endSearch()
            reload()
        }
    }
    var selectedThreadID: String? {
        didSet {
            // A click, J/K or a removal moves the focus out of a ⌘A block: back to one row.
            if !multiSelection.isEmpty, !(selectedThreadID.map(multiSelection.contains) ?? false) { multiSelection = [] }
            scheduleMarkRead()
            updateReader(debounced: isKeyboardNavigating)
            if let id = selectedThreadID, !isSearching, let index = visibleThreadIDs.firstIndex(of: id) {
                selectionIndexHint = index
            }
        }
    }
    /// More than one selected conversation (⌘A selects the focused one and everything below),
    /// always including `selectedThreadID`, which stays the focus the reader shows. Empty when
    /// one row is selected. Triage acts on all of them (see `targetThreads`).
    var multiSelection: Set<String> = []
    /// iPhone and iPad: Select mode, where taps tick conversations (into `multiSelection`)
    /// instead of opening them, and the bottom bar acts on all ticked ones.
    var isSelecting = false {
        didSet { if !isSelecting { multiSelection = [] } }
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
    /// Mac: replies and forwards open inside the reading pane, under the conversation (like
    /// Gmail and Outlook), one per conversation: conversation id → its draft. Moving to another
    /// conversation keeps the draft here, so coming back shows it again; Pop Out moves it to a window.
    var inlineDrafts: [String: Int64] = [:]
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
    /// Mac release builds: Sparkle's "Check for Updates…" (nil elsewhere, and the command hides).
    @ObservationIgnored var checkForUpdates: (@MainActor () -> Void)?
    /// The app's model, for App Intents and links that arrive without a view.
    @ObservationIgnored static weak var shared: AppModel?

    // Attachments (SPEC §11)
    var isAttachmentsShown = false
    /// Reader mode for every message (Settings › General, View menu, ⌘K); Read Later opens in it
    /// anyway. Kept between launches.
    var readerMode = UserDefaults.standard.bool(forKey: "readerMode") {
        didSet { UserDefaults.standard.set(readerMode, forKey: "readerMode") }
    }
    /// What Quick Look shows (nil closes it).
    var quickLookURL: URL?

    // Senders and unsubscribe (SPEC §11)
    var isSendersShown = false
    /// Mac: the Senders window is open, so it (not the main window) asks before unsubscribing.
    var isSendersWindowOpen = false
    var unsubscribeCandidate: UnsubscribeRequest?
    /// Bumped when sender data changes (the Senders screen reloads).
    var sendersRevision = 0

    // iCloud sync of app state (ADR 0006)
    @ObservationIgnored var cloudSync: CloudSync?
    @ObservationIgnored var cloudPushTask: Task<Void, Never>?
    var cloudStatus: CloudSync.CloudStatus = .off

    // Notifications (SPEC §10)
    var notificationPolicy: NotificationPolicy = NotificationPolicyStorage.load() {
        didSet { NotificationPolicyStorage.save(notificationPolicy) }
    }
    @ObservationIgnored lazy var notifier = MailNotifier(model: self)

    // Smart folders (SPEC §7): yours; the built-in ones live in `SmartFolder.builtIn`.
    var smartFolders: [SmartFolder] = []
    /// Conversations each smart folder finds right now.
    var smartFolderCounts: [String: Int] = [:]
    /// The saved search being named or edited.
    var editingSmartFolder: SmartFolder?
    @ObservationIgnored var smartFolderCountTask: Task<Void, Never>?

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

    // AI categories (described in words, sorted on device)
    var aiCategories: [AICategory] = []
    /// threadID → AI category ids (one read per reload).
    var aiMembership: [String: Set<String>] = [:]
    var editingAICategory: AICategoryEditing?
    @ObservationIgnored var aiCategoryTask: Task<Void, Never>?

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
    /// Showing one account's Inbox (and its category tabs) instead of the unified one. Nil, the
    /// default, is every account together. Set with `goToInbox(account:)`.
    var inboxAccountID: String?
    /// The add-account sheet (Settings, ⌘K); it also shows by itself while there are no accounts.
    var isAddingAccount = false
    /// The account Settings or ⌘K asked to remove, waiting for confirmation.
    var accountToRemove: AccountConfig?
    /// Accounts another device added through iCloud whose password hasn't reached this device's
    /// Keychain (iCloud Keychain is slow or off). They join as soon as it has one.
    var accountsAwaitingPassword: [AccountConfig] = []
    /// ⌘K "Sign In to …": the password sheet for one of them, over the main window.
    var accountToSignIn: AccountConfig?
    /// Unread Primary conversations per account (the sidebar's per-account Inbox badges).
    private(set) var accountUnreadCounts: [String: Int] = [:]
    internal(set) var threads: [ThreadSummary] = []
    private(set) var mailboxes: [MailboxState] = []
    private(set) var inboxUnreadCount = 0
    /// How many conversations are set aside with Reply Later (the sidebar badge).
    private(set) var replyLaterCount = 0
    private(set) var syncStatus: [String: String] = [:]
    /// Why an account can't connect right now (its sign-in or network error), until it does.
    private(set) var accountErrors: [String: String] = [:]
    var lastError: String?

    // Search
    var searchText = "" {
        didSet {
            selectedHitID = nil
            if searchText.isEmpty { searchEverywhere = false }
            runSearch()
        }
    }
    /// Search looks in the place you're in (a category, folder, smart folder) unless widened
    /// with "Search Everywhere" (⌥⌘F). From the Inbox it always searches everything.
    var searchEverywhere = false { didSet { if searchEverywhere != oldValue { runSearch() } } }
    /// The person the search seems to mean (card on top of the results).
    private(set) var searchContact: ContactHit?
    /// Close in meaning to the search, beyond the keyword hits (semantic second tier).
    private(set) var relatedHits: [SearchHit] = []
    @ObservationIgnored var relatedTask: Task<Void, Never>?
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

    /// The account setup sheet: when there are none yet, or when adding another.
    var isAccountSetupShown: Bool {
        get { needsAccountSetup || isAddingAccount }
        set { if !newValue { isAddingAccount = false } }
    }

    let store: MailStore
    let cache: MessageCache
    let dataDirectory: URL
    let isDevServer: Bool
    var syncs: [String: AccountSync] = [:]
    /// Each account's event listener and sync loop, so one account can be stopped on its own.
    private var tasks: [String: [Task<Void, Never>]] = [:]

    init() {
        isDevServer = ProcessInfo.processInfo.arguments.contains("-TidingsDevServer")
            || ProcessInfo.processInfo.environment["TIDINGS_DEV_SERVER"] == "1"
        CalendarBridge.shared.isEnabled = !isDevServer
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
        // The dev copy keeps its own account list and Keychain items, apart from the real app's.
        Keychain.service = isDevServer ? "Tidings-Dev" : "Tidings"
        var dev = Self.devAccount
        dev.endpoint.username = devUser
        if isDevServer {
            if devUser != "magnus" { AccountStorage.devKey = "accounts.dev.v1.\(devUser)" }
            // The local Dovecot account is always there; accounts added in the dev copy follow it.
            var saved = AccountStorage.load(dev: true)
            if let i = saved.firstIndex(where: { $0.id == "dev" }) { dev.identities = saved.remove(at: i).identities ?? dev.identities }
            accounts = [dev] + saved
        } else {
            accounts = AccountStorage.load()
        }
        accountsAwaitingPassword = AccountStorage.loadAwaiting(dev: isDevServer)
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
        loadSmartFolders()
        loadAICategories()
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
        startCloudSync()
        _ = notifier   // become the notification delegate before any tap arrives
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
            let id = account.id
            // Subscribe before starting the loop, or a fast first sync can finish (and emit
            // everything, including "idle") before anyone is listening.
            tasks[id, default: []].append(Task { [weak self] in
                let events = await sync.events()
                self?.tasks[id, default: []].append(Task.detached { await sync.run() })
                for await event in events { self?.handle(event, account: account) }
            })
        }
    }

    private func makeSync(for account: AccountConfig) -> AccountSync? {
        let password: String
        if account.id == "dev" {
            password = "tidings-test"
        } else if let stored = Keychain.password(for: account) {
            password = stored
        } else {
            lastError = String(localized: "No password in the Keychain for \(account.endpoint.username).")
            return nil
        }
        return AccountSync(account: account, password: password, store: store, cache: cache,
                           profile: account.id == "dev" ? .iCloudSimulation : nil)
    }

    /// Closes one account's connections (it's being removed).
    func stopSync(accountID: String) {
        for task in tasks[accountID] ?? [] { task.cancel() }
        tasks[accountID] = nil
        syncs[accountID] = nil
        syncStatus[accountID] = nil
    }

    // MARK: Foreground and background (iPhone)

    /// Closes every connection. `start()` opens them again.
    func stopSync() {
        for task in tasks.values.joined() { task.cancel() }
        tasks = [:]
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
            accountErrors[account.id] = nil
            lastError = nil
            cloudAfterMailSync()
            reload()
            scheduleRefinement()
            scheduleAutoDrafts()
            scheduleEventScan()
        case .failed(let message):
            syncStatus[account.id] = String(localized: "Offline")
            lastError = message
            let first = accountErrors[account.id] == nil
            accountErrors[account.id] = message
            // Mail only goes out over a working connection: say so instead of a silent wait.
            let due = outboxItems.contains { $0.accountID == account.id && $0.state == .queued && ($0.sendAt ?? .distantFuture) <= Date() }
            if first, due {
                show(Toast(message: String(localized: "Not sent yet: can't connect to \(account.displayName). It's waiting in the Outbox."),
                           symbol: "exclamationmark.triangle"))
            }
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

    /// iCloud: an app-specific password for the address (SPEC §16).
    func addAccount(address: String, password: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        let endpoint = IMAPEndpoint.iCloud(address: trimmed)
        let account = AccountConfig(displayName: trimmed, endpoint: endpoint, addresses: [trimmed],
                                    identities: [Identity(address: trimmed, name: Platform.fullUserName)])
        try checkNotAdded(account)
        // Validate before saving anything: read-only login + capability check.
        _ = try await MailSession.open(endpoint: endpoint, password: password) { session in session.capabilities }
        try save(account, password: password)
    }

    /// Any IMAP/SMTP account. Both servers are tried with the password before anything is saved.
    func addAccount(name: String, address: String, settings: MailServerSettings, password: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        var smtp = settings.smtp
        // The dev copy's local Mailpit has a self-signed certificate (only ever for localhost).
        if isDevServer { smtp.allowSelfSignedLocalhost = true }
        let title = name.trimmingCharacters(in: .whitespaces)
        let account = AccountConfig(displayName: title.isEmpty ? trimmed : title, endpoint: settings.imap, addresses: [trimmed],
                                    smtp: smtp, identities: [Identity(address: trimmed, name: Platform.fullUserName)])
        try checkNotAdded(account)
        do {
            _ = try await MailSession.open(endpoint: settings.imap, password: password) { session in session.capabilities }
        } catch {
            throw AccountSetupError.incoming(String(describing: error))
        }
        do {
            try await SMTPClient.verify(endpoint: smtp, password: password)
        } catch {
            throw AccountSetupError.outgoing(String(describing: error))
        }
        try save(account, password: password)
    }

    /// An account another device added through iCloud: its password is checked against the
    /// servers, then it joins like one added here.
    func completeAccount(_ account: AccountConfig, password: String) async throws {
        do {
            _ = try await MailSession.open(endpoint: account.endpoint, password: password) { session in session.capabilities }
        } catch {
            throw AccountSetupError.incoming(String(describing: error))
        }
        if let smtp = account.smtp {
            do {
                try await SMTPClient.verify(endpoint: smtp, password: password)
            } catch {
                throw AccountSetupError.outgoing(String(describing: error))
            }
        }
        accountsAwaitingPassword.removeAll { $0.login == account.login }
        try save(account, password: password)
    }

    private func checkNotAdded(_ account: AccountConfig) throws {
        if accounts.contains(where: { $0.login == account.login }) { throw AccountSetupError.alreadyAdded }
    }

    private func save(_ account: AccountConfig, password: String) throws {
        try Keychain.save(password: password, account: account.login)
        accounts.append(account)
        persistAccounts()
        isAddingAccount = false
        cloudSync?.setAccounts(cloudAccounts)
        start()
        reload()
    }

    /// Removes an account from this device: its connections, its mail and state here, its cached
    /// messages and its Keychain password. Nothing on the mail server or in iCloud changes, so
    /// other devices keep it, and adding it again brings everything back.
    /// `everywhere`: with iCloud sync on, your other devices remove it too (its record and its
    /// iCloud Keychain password go); false when another device removed it and this one follows.
    func removeAccount(_ account: AccountConfig, everywhere: Bool = true) {
        accountToRemove = nil
        accountErrors[account.id] = nil
        let cloud = cloudAccounts
        stopSync(accountID: account.id)
        do {
            try store.deleteAccount(account.id, cloudAccounts: cloud)
        } catch {
            lastError = String(describing: error)
        }
        cache.removeAccount(account.id)
        if account.id != "dev" {
            let others = accounts.filter { $0.id != account.id }
            for key in Set([account.login, account.endpoint.username]) where !others.contains(where: { $0.login == key || $0.endpoint.username == key }) {
                Keychain.delete(account: key, everywhere: everywhere && Keychain.synchronizes)
            }
        }
        accounts.removeAll { $0.id == account.id }
        accountsAwaitingPassword.removeAll { $0.login == account.login }
        persistAccounts()
        cloudSync?.setAccounts(cloudAccounts)
        for (thread, draft) in inlineDrafts where (try? store.outboxItem(id: draft)) == nil { inlineDrafts[thread] = nil }
        if inboxAccountID == account.id { inboxAccountID = nil }
        if case .mailbox(let id, _) = selection, id == account.id { goToInbox() }
        selectedThreadID = nil
        reloadOutbox()
        reload()
        show(Toast(message: String(localized: "Removed \(account.displayName)"), symbol: "person.crop.circle.badge.minus"))
    }

    /// One account's Inbox (nil: every account together, the default).
    func goToInbox(account id: String?) {
        let changed = inboxAccountID != id
        inboxAccountID = id
        if !isInInbox {
            selection = .category(.primary)     // reloads
        } else if changed {
            selectedThreadID = nil
            selectionIndexHint = nil
            heldCategories = [:]
            endSearch()
            reload()
        }
    }

    func account(id: String) -> AccountConfig? { accounts.first { $0.id == id } }

    // MARK: Loading

    var ownAddresses: Set<String> { Set(accounts.flatMap(\.addresses)) }

    /// Mac list column title (as in Mail): "Inbox" for All and every category tab; the tab is
    /// in the subtitle.
    var listTitle: String {
        if isSearching { return String(localized: "Search") }
        if isInInbox, let id = inboxAccountID, let account = account(id: id) { return account.displayName }
        return isInInbox ? String(localized: "Inbox") : currentMailboxTitle
    }

    /// Under the list title: "Primary · 20 conversations, 5 unread".
    var listSubtitle: String {
        guard !isSearching else { return "" }
        let unread = threads.filter { $0.unreadCount > 0 }.count
        let counts = unread > 0 ? String(localized: "\(threads.count) conversations, \(unread) unread")
                                : String(localized: "\(threads.count) conversations")
        guard isInInbox else { return counts }
        let tab = selection == .inbox ? String(localized: "All") : currentMailboxTitle
        return "\(tab) · \(counts)"
    }

    var currentMailboxTitle: String {
        switch selection {
        case .inbox: String(localized: "Inbox")
        case .accountInbox(let id): account(id: id)?.displayName ?? String(localized: "Inbox")
        case .snoozed: String(localized: "Snoozed")
        case .replyLater: String(localized: "Set Aside")
        case .outbox: String(localized: "Outbox")
        case .category(let c): c.title
        case .mailbox(let accountID, let path):
            mailboxes.first { $0.accountID == accountID && $0.path == path }?.role?.title ?? path
        case .smartFolder(let id): smartFolder(id: id).map(displayName) ?? String(localized: "Smart Folder")
        case .aiCategory(let id): aiCategory(id: id)?.name ?? String(localized: "Category")
        }
    }

    func reload() {
        now = Date()
        revision &+= 1
        scheduleCloudPush()
        do {
            // One read of the Inbox serves the stream, a category and the unread count.
            var unifiedCache: [ThreadSummary]?
            func unified() throws -> [ThreadSummary] {
                if let unifiedCache { return unifiedCache }
                let loaded = try store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)
                unifiedCache = loaded
                return loaded
            }
            // The Inbox on screen: every account's, or one account's.
            var filteredCache: [ThreadSummary]?
            func inbox() throws -> [ThreadSummary] {
                guard let id = inboxAccountID else { return try unified() }
                if let filteredCache { return filteredCache }
                let loaded = try store.threads(mailbox: "INBOX", accountID: id, ownAddresses: ownAddresses)
                filteredCache = loaded
                return loaded
            }
            switch selection {
            case .inbox, .accountInbox:
                threads = try inbox()
            case .outbox:
                threads = []
            case .snoozed:
                // Each account's snoozed folder ("Snoozed", or "INBOX.Snoozed" on some servers).
                let paths = Set(mailboxes.map(\.path).filter(AccountSync.isSnoozedMailbox)
                                + [AccountSync.snoozedMailbox, "INBOX.Snoozed", "INBOX/Snoozed"])
                var seen = Set<String>()
                threads = try paths.flatMap { try store.threads(mailbox: $0, ownAddresses: ownAddresses) }
                    .filter { seen.insert($0.threadID).inserted }
                    .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            case .replyLater:
                threads = try inbox().filter(\.isReplyLater)
            case .category(let category):
                // Set-aside conversations live in Set Aside, as they do in the Inbox's Reply Later row.
                threads = try inbox().filter { !$0.isReplyLater && displayCategory($0) == category }
                for thread in threads where heldCategories[thread.threadID] == nil { heldCategories[thread.threadID] = category }
            case .mailbox(let accountID, let path):
                threads = try store.threads(mailbox: path, accountID: accountID, ownAddresses: ownAddresses)
            case .smartFolder(let id):
                threads = try smartFolder(id: id).map(smartFolderThreads) ?? []
            case .aiCategory(let id):
                aiMembership = (try? store.aiCategoryMembership()) ?? aiMembership
                threads = try inbox().filter { !$0.isReplyLater && aiMembership[$0.threadID]?.contains(id) == true }
            }
            // Pinned Only works on every Inbox tab (the Inbox now opens on Primary, not All).
            if pinnedOnly, isInInbox { threads = threads.filter(\.isPinned) }
            if !pendingRemovals.isEmpty { threads.removeAll { pendingRemovals.contains($0.threadID) } }
            if selection == .inbox { holdOpenBundles() }
            mailboxes = try accounts.flatMap { try store.mailboxStates(accountID: $0.id) }
            let primary = try unified().filter { $0.latest.category == .primary }
            inboxUnreadCount = primary.reduce(0) { $0 + $1.unreadCount }
            accountUnreadCounts = accounts.count > 1
                ? primary.reduce(into: [:]) { counts, thread in counts[thread.latest.accountID, default: 0] += thread.unreadCount }
                : [:]
            replyLaterCount = try unified().filter(\.isReplyLater).count
            scheduleSmartFolderCounts()
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

    /// Waiting for its bundle's next delivery, so the Inbox stream doesn't show it yet (the
    /// same rule `streamItems` uses).
    func isHeldForDelivery(_ thread: ThreadSummary) -> Bool {
        guard !thread.isReplyLater, !thread.isPinned else { return false }
        let category = displayCategory(thread)
        guard category != .primary, let delivered = bundleSchedules[category]?.lastDelivery(before: now) else { return false }
        return thread.arrivedAt > delivered
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
        guard selection == .inbox else {
            // Pinned first everywhere (stable, so each list keeps its own order otherwise);
            // Snoozed stays in wake-up order.
            guard selection != .snoozed else { return threads.map(StreamItem.thread) }
            return (threads.filter(\.isPinned) + threads.filter { !$0.isPinned }).map(StreamItem.thread)
        }
        var items: [StreamItem] = []
        var bundles: [MailCategory: [ThreadSummary]] = [:]
        let later = threads.filter(\.isReplyLater)
        if !later.isEmpty { items.append(.replyLater(later)) }
        for thread in threads where !thread.isReplyLater {
            let category = displayCategory(thread)
            // A pinned conversation is its own row at the top, even from a bundled category.
            if category == .primary || thread.isPinned { items.append(.thread(thread)) }
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

    /// Pinned conversations sit on top, then Reply Later, then bundles with new mail, then
    /// everything by time.
    private func tier(_ item: StreamItem) -> Int {
        switch item {
        case .thread(let thread): thread.isPinned ? 3 : 0
        case .replyLater: 2
        case .bundle(let category, let members, _): isBundlePinned(category, members) ? 1 : 0
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
            let ids = searchHits.map(\.id) + relatedHits.map(\.id)
            guard !ids.isEmpty else { return }
            let index = selectedHitID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
            lastMoveDirection = delta > 0 ? 1 : -1
            isKeyboardNavigating = true
            selectedHitID = ids[max(0, min(ids.count - 1, index + delta))]
            isKeyboardNavigating = false
            return
        }
        multiSelection = []
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

    /// Where search looks by default: the place you're in, unless that's the Inbox.
    var searchScope: SidebarItem? {
        guard !searchEverywhere else { return nil }
        switch selection {
        case .category, .mailbox, .smartFolder, .snoozed: return selection
        default: return nil
        }
    }

    /// The search as typed, plus the scope's own operators.
    private var scopedSearchText: String {
        // In one account's Inbox, a category search stays in that account.
        let account = inboxAccountID.map { " account:\($0)" } ?? ""
        switch searchScope {
        case .category(let c): return "\(searchText) category:\(c.rawValue)\(account)"
        case .mailbox(let id, let path): return "\(searchText) in:\"\(path)\" account:\(id)"
        case .snoozed: return "\(searchText) in:\"\(AccountSync.snoozedMailbox)\""
        case .smartFolder(let id): return "\(smartFolder(id: id)?.query ?? "") \(searchText)"
        default: return searchText
        }
    }

    private func runSearch() {
        relatedTask?.cancel()
        let typed = SearchQuery(parsing: searchText)
        guard !typed.isEmpty else {
            searchHits = []
            facets = nil
            searchContact = nil
            relatedHits = []
            return
        }
        let query = SearchQuery(parsing: scopedSearchText).resolvingAccounts(accounts)
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
        // The person card: never yourself.
        let contact = try? engine.contact(for: typed)
        searchContact = contact.flatMap { ownAddresses.contains($0.address.lowercased()) ? nil : $0 }
        scheduleRelated(for: typed, excluding: Set(searchHits.map(\.id)))
    }

    /// Semantic second tier: a moment after typing stops, off the main thread.
    private func scheduleRelated(for query: SearchQuery, excluding: Set<Int64>) {
        relatedHits = []
        let text = (query.terms + query.phrases).joined(separator: " ")
        guard text.count >= 3, let embedder = refinement?.embedder else { return }
        let engine = SearchEngine(store: store)
        relatedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                (try? engine.related(to: text, embedder: embedder, excluding: excluding)) ?? []
            }.value
            guard !Task.isCancelled, let self else { return }
            self.relatedHits = found
        }
    }

    /// ⌥⌘F: widen a scoped search to all mail, or narrow it back.
    func toggleSearchEverywhere() {
        guard isSearching else { return }
        if searchEverywhere { searchEverywhere = false } else if searchScope != nil { searchEverywhere = true }
    }

    /// All mail from the person on the card.
    func searchAll(from contact: ContactHit) {
        searchText = "from:\(contact.address)"
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

    /// The conversation as the reader shows it: a message that reached two of your accounts
    /// (same Message-ID) once, the copy in the account you're looking at (else the first).
    func readerMessages(inThread threadID: String) -> [StoredMessage] {
        let all = messages(inThread: threadID)
        guard accounts.count > 1 else { return all }
        var chosen: [String: StoredMessage] = [:]
        for message in all {
            guard let key = message.messageID else { continue }
            if let existing = chosen[key], existing.accountID == inboxAccountID || message.accountID != inboxAccountID { continue }
            chosen[key] = message
        }
        return all.filter { message in
            guard let key = message.messageID else { return true }
            return chosen[key]?.id == message.id
        }
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
    static func loadAwaiting(dev: Bool) -> [AccountConfig] {
        guard let data = UserDefaults.standard.data(forKey: dev ? "\(devKey).awaiting" : "accounts.awaiting.v1") else { return [] }
        return (try? JSONDecoder().decode([AccountConfig].self, from: data)) ?? []
    }

    static func saveAwaiting(_ accounts: [AccountConfig], dev: Bool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: dev ? "\(devKey).awaiting" : "accounts.awaiting.v1")
    }

    static let key = "accounts.v1"
    /// The dev copy's own list (`-TidingsDevServer`), so it never touches the real one; one per
    /// `-TidingsDevUser`, like its data folder.
    nonisolated(unsafe) static var devKey = "accounts.dev.v1"

    static func load(dev: Bool = false) -> [AccountConfig] {
        guard let data = UserDefaults.standard.data(forKey: dev ? devKey : key) else { return [] }
        return (try? JSONDecoder().decode([AccountConfig].self, from: data)) ?? []
    }

    static func save(_ accounts: [AccountConfig], dev: Bool = false) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: dev ? devKey : key)
    }
}

/// Why adding an account didn't work, for the setup form.
enum AccountSetupError: LocalizedError {
    case alreadyAdded
    case incoming(String)
    case outgoing(String)

    var errorDescription: String? {
        switch self {
        case .alreadyAdded: String(localized: "That account is already in Tidings.")
        case .incoming(let detail): String(localized: "Couldn't sign in to the incoming (IMAP) server: \(detail)")
        case .outgoing(let detail): String(localized: "Signed in to IMAP, but the outgoing (SMTP) server said no: \(detail)")
        }
    }
}
