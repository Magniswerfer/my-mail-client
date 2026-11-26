import Foundation
import MailEngine
import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String
    /// The change Undo takes back (registered on the undo manager too).
    var undo: UndoToken? = nil
    /// Outbox id of a message in its undo-send window.
    var undoSend: Int64? = nil

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// One undoable change, offered both in a toast and on the undo manager (⌘Z, the Edit menu,
/// shake). It's the undo manager's target for just this change, so the toast can take back
/// exactly this one and remove it from the stack. Runs at most once.
@MainActor final class UndoToken {
    private var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }

    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}

/// Filled in once the engine has applied an action. Undo is registered *during* the key press
/// (so AppKit's undo grouping sees it) and reads the box when it runs.
@MainActor final class ChangeBox {
    var changes: [TriageChange] = []
    var undone = false
}

struct SweepRequest: Identifiable {
    let id = UUID()
    var threadIDs: [String]
    var title: String
}

/// Snooze choices (SPEC §4). Times are computed when the picker opens.
struct SnoozePreset: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let date: Date?

    static func all(now: Date = Date(), calendar: Calendar = .current) -> [SnoozePreset] {
        func at(_ hour: Int, daysFrom base: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }
        let laterToday: Date = {
            let inThree = now.addingTimeInterval(3 * 3600)
            let evening = at(18, daysFrom: now)
            return evening > inThree ? evening : calendar.nextDate(after: inThree, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? inThree
        }()
        let tomorrow = at(8, daysFrom: calendar.date(byAdding: .day, value: 1, to: now)!)
        let saturday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 7), matchingPolicy: .nextTime)!
        let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 8, weekday: 2), matchingPolicy: .nextTime)!
        func label(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return [
            SnoozePreset(id: "later", title: String(localized: "Later today"), detail: label(laterToday), symbol: "clock", date: laterToday),
            SnoozePreset(id: "tomorrow", title: String(localized: "Tomorrow"), detail: label(tomorrow), symbol: "sunrise", date: tomorrow),
            SnoozePreset(id: "weekend", title: String(localized: "This weekend"), detail: label(saturday), symbol: "sofa", date: saturday),
            SnoozePreset(id: "nextweek", title: String(localized: "Next week"), detail: label(monday), symbol: "briefcase", date: monday),
            SnoozePreset(id: "someday", title: String(localized: "Someday"), detail: String(localized: "No reminder"), symbol: "infinity", date: nil),
        ]
    }
}

extension AppModel {
    // MARK: Targets

    /// What an action applies to: the selected conversation, or every one in a ⌘A block
    /// (in list order, so the focused one comes first).
    var targetThreads: [ThreadSummary] {
        if !multiSelection.isEmpty {
            let byID = Dictionary(threads.map { ($0.threadID, $0) }, uniquingKeysWith: { a, _ in a })
            let selected = visibleThreadIDs.filter(multiSelection.contains).compactMap { byID[$0] }
            if !selected.isEmpty { return selected }
        }
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.threadID == id }) else { return [] }
        return [thread]
    }

    // MARK: Selecting several

    /// ⌘A: the focused conversation and every one below it as shown (open bundles included),
    /// or all of them with nothing focused, so the next triage key handles the whole block.
    func selectFocusedAndBelow() {
        guard !isSearching else { return }
        let ids = visibleThreadIDs
        guard !ids.isEmpty else { return }
        let start = selectedThreadID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let block = ids[start...]
        multiSelection = block.count > 1 ? Set(block) : []
        if selectedThreadID != block.first { selectedThreadID = block.first }
    }

    /// What the stream list shows selected: the ⌘A block, else the one conversation.
    var listSelection: Set<String> {
        multiSelection.isEmpty ? Set(selectedThreadID.map { [$0] } ?? []) : multiSelection
    }

    /// The list's own selection changing: a click (one row), or ⇧/⌘-click (several). The focus
    /// stays put if it's still selected, else moves to the first selected row.
    func setListSelection(_ ids: Set<String>) {
        guard ids.count > 1 else {
            multiSelection = []
            if selectedThreadID != ids.first { selectedThreadID = ids.first }
            return
        }
        multiSelection = ids
        if !(selectedThreadID.map(ids.contains) ?? false) {
            selectedThreadID = visibleThreadIDs.first(where: ids.contains) ?? ids.first
        }
    }

    /// Esc: back to just the focused conversation. False when there was nothing to clear.
    @discardableResult
    func clearMultiSelection() -> Bool {
        guard !multiSelection.isEmpty else { return false }
        multiSelection = []
        return true
    }

    /// The mailbox the current view shows (where moves start from).
    var sourceMailbox: String {
        switch selection {
        case .inbox, .accountInbox, .category, .outbox, .replyLater, .aiCategory: "INBOX"
        case .snoozed: AccountSync.snoozedMailbox
        case .mailbox(_, let path): path
        // Results come from any folder: act where the selected conversation is.
        case .smartFolder: targetThreads.first?.latest.mailbox ?? "INBOX"
        }
    }

    // MARK: Performing

    @discardableResult
    func perform(_ kind: TriageKind, on threads: [ThreadSummary]? = nil, toast showToast: Bool = true,
                 inAccount onlyAccount: String? = nil) -> ChangeBox? {
        let targets = threads ?? targetThreads
        guard !targets.isEmpty else { return nil }
        // In Read Later, Done means "finished reading": the mail itself is already filed.
        if kind == .done, isInReadLater, showToast {
            finishReading(targets)
            return nil
        }
        let nextSelection = neighbour(after: targets.map(\.threadID))
        let box = ChangeBox()
        if showToast {
            let undoToken = offerUndo(named: kind.toastText(count: targets.count)) { [weak self] in self?.undo(box: box) }
            show(Toast(message: kind.toastText(count: targets.count), symbol: kind.symbol, undo: undoToken))
        }
        let ids = Set(targets.map(\.threadID))
        if kind == .done || kind == .markRead || kind == .trash || kind == .junk { ids.forEach(notifier.clear) }
        let removes = removesFromCurrentView(kind)
        if removes {
            // One motion: the row leaves and the selection moves on together, before the engine
            // has written anything (it catches up a moment later; see `pendingRemovals`).
            pendingRemovals.formUnion(ids)
            // The first press animates; presses in quick succession don't wait on animations.
            let animation: Animation? = Date().timeIntervalSince(lastRemovalAt) < 0.5 ? nil : .snappy(duration: 0.18)
            lastRemovalAt = Date()
            // Like j/k: the reader follows once you pause, so rapid E never waits on rendering mail.
            isKeyboardNavigating = true
            withAnimation(animation) {
                self.threads.removeAll { ids.contains($0.threadID) }
                selectedThreadID = nextSelection
            }
            isKeyboardNavigating = false
        }
        let source = sourceMailbox
        // A smart folder mixes folders: each conversation is acted on where it lives.
        let perFolder: Bool = if case .smartFolder = selection { true } else { false }
        struct Where: Hashable { var accountID: String; var mailbox: String }
        Task {
            // A conversation can live in more than one account (mail sent to two of your
            // addresses): it's acted on in each, unless you're looking at one account's Inbox.
            let owners = self.owningAccounts(of: targets.map(\.threadID))
            var groups: [Where: [ThreadSummary]] = [:]
            for thread in targets {
                for account in onlyAccount.map({ [$0] }) ?? owners[thread.threadID] ?? [thread.latest.accountID] {
                    groups[Where(accountID: account, mailbox: perFolder ? thread.latest.mailbox : source), default: []].append(thread)
                }
            }
            for (place, group) in groups {
                guard let sync = syncs[place.accountID] else { continue }
                do {
                    if let change = try await sync.perform(kind, threadIDs: group.map(\.threadID), from: place.mailbox) {
                        box.changes.append(change)
                    }
                } catch {
                    lastError = String(describing: error)
                }
            }
            // Undo was pressed before the engine finished: reverse right away.
            if box.undone { await undo(box) }
            // The store has the change now, so these can't come back on the next reload.
            pendingRemovals.subtract(ids)
            // Removals already show; batch their reloads. Flag changes (pin, read) show on reload.
            if removes { scheduleReload() } else { reload() }
        }
        return box
    }

    /// Like `perform`, for a conversation that may not be in the list on screen (e.g. replying
    /// from search). Quiet: no toast, no undo registration; the caller handles both.
    @discardableResult
    func performQuietly(_ kind: TriageKind, threadID: String, accountID: String, from mailbox: String = "INBOX") -> ChangeBox {
        if let loaded = threads.first(where: { $0.threadID == threadID }), mailbox == sourceMailbox {
            return perform(kind, on: [loaded], toast: false) ?? ChangeBox()
        }
        let box = ChangeBox()
        Task {
            for account in owningAccounts(of: [threadID])[threadID] ?? [accountID] {
                if let change = try? await syncs[account]?.perform(kind, threadIDs: [threadID], from: mailbox) {
                    box.changes.append(change)
                }
            }
            if box.undone { await undo(box) }
            reload()
        }
        return box
    }

    /// The accounts to act in for each conversation: every account that has a message of it,
    /// or only the one whose Inbox you're looking at.
    func owningAccounts(of threadIDs: [String]) -> [String: [String]] {
        if isInInbox, let id = inboxAccountID { return Dictionary(uniqueKeysWithValues: threadIDs.map { ($0, [id]) }) }
        let found = (try? store.accountIDs(threadIDs: threadIDs)) ?? [:]
        return found.mapValues { $0.sorted() }
    }

    /// Whether an action takes the conversation out of the list on screen.
    func removesFromCurrentView(_ kind: TriageKind) -> Bool {
        // A smart folder is a search: whether the conversation still belongs is up to the
        // search, and the list refreshes right after the action.
        if case .smartFolder = selection { return false }
        return switch kind {
        // Set aside: it leaves the Inbox and categories for Set Aside (and the Inbox's Reply
        // Later row). Elsewhere (Snoozed, folders) it only gets marked.
        case .replyLater:
            switch selection {
            case .inbox, .category, .aiCategory: true
            default: false
            }
        // Taken off the pile: it leaves Set Aside.
        case .clearReplyLater: selection == .replyLater
        default: kind.removesFromView
        }
    }

    /// Whether you're looking at the Read Later pile.
    var isInReadLater: Bool { selection == .smartFolder(SmartFolder.readLater.id) }

    func isReadLater(_ thread: ThreadSummary) -> Bool {
        messages(inThread: thread.threadID).contains { $0.flags.contains(readLaterKeyword) }
    }

    /// Read Later (⇧R): the keyword, then Done when it's in the Inbox, as one undoable step,
    /// for the selection (a ⌘A block too). Again on conversations already on the pile (or in
    /// it) takes them off: finished reading.
    func readLater(_ thread: ThreadSummary? = nil) {
        let targets = thread.map { [$0] } ?? targetThreads
        guard !targets.isEmpty else { return }
        if isInReadLater || targets.allSatisfy(isReadLater) {
            finishReading(targets)
            return
        }
        let accounts = targets.map { ($0.threadID, $0.latest.accountID) }
        let flags = accounts.map { performQuietly(.readLater, threadID: $0.0, accountID: $0.1) }
        let done = sourceMailbox == "INBOX" ? perform(.done, on: targets, toast: false) : nil
        let undo: @MainActor () -> Void = { [weak self] in
            flags.forEach { self?.undo(box: $0) }
            if let done { self?.undo(box: done) }
        }
        let undoToken = offerUndo(named: TriageKind.readLater.toastText(count: targets.count), undo)
        show(Toast(message: TriageKind.readLater.toastText(count: targets.count), symbol: "book", undo: undoToken))
    }

    /// Off the pile; the mail itself stays where it's filed.
    func finishReading(_ targets: [ThreadSummary]) {
        let boxes = targets.map { performQuietly(.clearReadLater, threadID: $0.threadID, accountID: $0.latest.accountID) }
        let undo: @MainActor () -> Void = { [weak self] in boxes.forEach { self?.undo(box: $0) } }
        let undoToken = offerUndo(named: String(localized: "Finished Reading"), undo)
        show(Toast(message: String(localized: "Finished reading"), symbol: "book.closed", undo: undoToken))
    }

    func toggleReplyLater() {
        guard let thread = targetThreads.first else { return }
        perform(thread.isReplyLater ? .clearReplyLater : .replyLater)
    }

    /// The conversation to select after the current one leaves the list: the next one after
    /// everything that leaves with it (a ⌘A block), else the one before.
    private func neighbour(after removedIDs: [String]) -> String? {
        let ids = visibleThreadIDs
        let removed = Set(removedIDs)
        let remaining = ids.enumerated().filter { !removed.contains($0.element) }
        // iPhone, in the list: nothing is open, and selecting would open the next conversation.
        if selectedThreadID == nil, Platform.isPhone { return nil }
        guard let current = selectedThreadID, let index = ids.firstIndex(of: current) else {
            // The selection isn't in the list (it left it, or it's a search result): carry on
            // from where it was in the list, if it was there at all.
            guard !isSearching, let hint = selectionIndexHint, !remaining.isEmpty else { return selectedThreadID }
            return remaining.first { $0.offset >= hint }?.element ?? remaining.last?.element
        }
        // Acting on another row (a swipe, a context menu) leaves the selection where it is.
        guard removed.contains(current) else { return current }
        let end = ids.indices.last(where: { removed.contains(ids[$0]) }) ?? index
        return remaining.first { $0.offset > end }?.element ?? remaining.last { $0.offset < end }?.element
    }

    func togglePin() {
        guard let thread = targetThreads.first else { return }
        perform(thread.isPinned ? .unpin : .pin)
    }

    func toggleRead() {
        guard let thread = targetThreads.first else { return }
        perform(thread.unreadCount > 0 ? .markRead : .markUnread)
    }

    func snooze(_ preset: SnoozePreset) {
        isSnoozePickerShown = false
        perform(.snooze(until: preset.date), on: takeSnoozeTarget())
    }

    func snooze(until date: Date) {
        isSnoozePickerShown = false
        perform(.snooze(until: date), on: takeSnoozeTarget())
    }

    /// The swiped conversation, if the picker was opened by a swipe (then forgotten).
    private func takeSnoozeTarget() -> [ThreadSummary]? {
        defer { snoozeTarget = nil }
        guard let id = snoozeTarget else { return nil }
        return threads.filter { $0.threadID == id }
    }

    /// Inbox conversations a sweep would mark done.
    var sweepableCount: Int { isInInbox ? threads.filter { !$0.isPinned }.count : 0 }

    // MARK: Sweep

    /// Done for everything in the Inbox that isn't pinned (or for one bundle).
    func requestSweep(bundle: MailCategory? = nil) {
        let candidates = threads.filter { !$0.isPinned && (bundle == nil || displayCategory($0) == bundle) }
        guard !candidates.isEmpty else { return }
        let tabCategory: MailCategory? = if case .category(let c) = selection { c } else { nil }
        let title = (bundle ?? tabCategory).map { String(localized: "Mark all \($0.title) done?") }
            ?? String(localized: "Sweep the Inbox?")
        sweepCandidate = SweepRequest(threadIDs: candidates.map(\.threadID), title: title)
    }

    func confirmSweep(_ request: SweepRequest) {
        sweepCandidate = nil
        let targets = threads.filter { request.threadIDs.contains($0.threadID) }
        perform(.done, on: targets)
    }

    // MARK: Undo

    /// Puts a change on the undo manager (registered inside the click or key press, so AppKit's
    /// grouping sees it) and returns its token for the toast.
    @discardableResult
    func offerUndo(named name: String, _ undo: @escaping @MainActor () -> Void) -> UndoToken {
        let token = UndoToken(undo)
        // The handler holds the token: the manager keeps only an unowned reference to a target.
        undoManager?.registerUndo(withTarget: token) { _ in MainActor.assumeIsolated { token.run() } }
        undoManager?.setActionName(name)
        return token
    }

    /// Undo from the toast: exactly this change, taken off the undo stack so ⌘Z won't repeat it.
    /// (Asking the undo manager to undo takes whatever is on top: in the reader that can be
    /// something of the message view's own, and then the toast's change stayed done.)
    func undoFromToast(_ token: UndoToken) {
        undoManager?.removeAllActions(withTarget: token)
        token.run()
    }

    func undo(box: ChangeBox) {
        guard !box.undone else { return }
        box.undone = true
        toast = nil
        Task { await undo(box) }
    }

    private func undo(_ box: ChangeBox) async {
        for change in box.changes {
            try? await syncs[change.accountID]?.undo(change)
        }
        box.changes = []
        reload()
    }

    // MARK: Toast

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Read on open

    /// Opening an unread conversation marks it read after a short dwell, so j/k skimming
    /// doesn't mark everything read.
    func scheduleMarkRead() {
        markReadTask?.cancel()
        guard let thread = targetThreads.first, thread.unreadCount > 0 else { return }
        markReadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.selectedThreadID == thread.threadID else { return }
            self.perform(.markRead, on: [thread], toast: false)
        }
    }
}

extension AppModel {
    // MARK: Folders

    /// Where a conversation can be moved (V): Inbox and Archive first, then your own folders.
    /// Not the folder it's in, and not Sent, Drafts or Snoozed (snoozing has its own key).
    func folderTargets(for thread: ThreadSummary?) -> [MailboxState] {
        guard let accountID = thread?.latest.accountID ?? accounts.first?.id else { return [] }
        let source = sourceMailbox
        func rank(_ box: MailboxState) -> Int {
            switch box.role {
            case .inbox: 0
            case .archive: 1
            case .junk: 3
            case .trash: 4
            default: 2
            }
        }
        return mailboxes
            .filter { $0.accountID == accountID && $0.path != source && $0.path != AccountSync.snoozedMailbox
                && $0.role != .sent && $0.role != .drafts }
            .sorted { rank($0) == rank($1) ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : rank($0) < rank($1) }
    }

    /// Moves conversations to a folder, using the matching triage action for the special ones
    /// (so moving to Archive is Done, and back to Inbox clears snooze keywords).
    func move(_ threads: [ThreadSummary]? = nil, toFolder box: MailboxState) {
        let kind: TriageKind = switch box.role {
        case .inbox: selection == .snoozed ? .unsnooze : .moveToInbox
        case .archive: .done
        case .trash: .trash
        case .junk: .junk
        default: .move(toMailbox: box.path)
        }
        // A folder belongs to one account; the others don't get a folder of that name.
        if case .move = kind { perform(kind, on: threads, inAccount: box.accountID) } else { perform(kind, on: threads) }
    }
}

extension MailboxState {
    /// A folder's name as shown: the role's title for special folders, else the last path part.
    var displayName: String { role?.title ?? Self.displayName(path) }

    static func displayName(_ path: String) -> String {
        if path.uppercased() == "INBOX" { return String(localized: "Inbox") }
        return path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path
    }
}

extension TriageKind {
    var removesFromView: Bool {
        switch self {
        case .done, .trash, .junk, .moveToInbox, .move, .snooze, .unsnooze: true
        // Leaves the stream for the Reply Later row at the top.
        case .replyLater: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .done: "checkmark.circle"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .moveToInbox: "tray.and.arrow.down"
        case .move: "folder"
        case .snooze: "clock"
        case .unsnooze: "clock.arrow.circlepath"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .markRead: "envelope.open"
        case .markUnread: "envelope.badge"
        case .replyLater: "arrowshape.turn.up.left.circle"
        case .clearReplyLater: "checkmark.circle"
        case .readLater: "book"
        case .clearReadLater: "book.closed"
        }
    }

    func toastText(count: Int) -> String {
        switch self {
        case .done: count == 1 ? String(localized: "Marked done") : String(localized: "\(count) conversations done")
        case .trash: count == 1 ? String(localized: "Moved to Trash") : String(localized: "\(count) moved to \(MailboxRole.trash.title)")
        case .junk: count == 1 ? String(localized: "Moved to Junk") : String(localized: "\(count) moved to \(MailboxRole.junk.title)")
        case .moveToInbox: count == 1 ? String(localized: "Moved to Inbox") : String(localized: "\(count) moved to \(MailboxRole.inbox.title)")
        case .move(let path):
            count == 1 ? String(localized: "Moved to \(MailboxState.displayName(path))")
                       : String(localized: "\(count) moved to \(MailboxState.displayName(path))")
        case .snooze(let until):
            if let when = until?.formatted(.dateTime.weekday(.wide).hour().minute()) {
                count == 1 ? String(localized: "Snoozed until \(when)") : String(localized: "\(count) snoozed until \(when)")
            } else {
                count == 1 ? String(localized: "Snoozed for someday") : String(localized: "\(count) snoozed for someday")
            }
        case .unsnooze: count == 1 ? String(localized: "Back in the Inbox") : String(localized: "\(count) back in the Inbox")
        case .pin: count == 1 ? String(localized: "Pinned") : String(localized: "\(count) pinned")
        case .unpin: count == 1 ? String(localized: "Unpinned") : String(localized: "\(count) unpinned")
        case .markRead: count == 1 ? String(localized: "Marked read") : String(localized: "\(count) marked read")
        case .markUnread: count == 1 ? String(localized: "Marked unread") : String(localized: "\(count) marked unread")
        case .replyLater: count == 1 ? String(localized: "Set aside to reply later") : String(localized: "\(count) set aside to reply later")
        case .clearReplyLater: count == 1 ? String(localized: "Removed from Reply Later") : String(localized: "\(count) removed from Reply Later")
        case .readLater: count == 1 ? String(localized: "Saved to Read Later") : String(localized: "\(count) saved to Read Later")
        case .clearReadLater: count == 1 ? String(localized: "Removed from Read Later") : String(localized: "\(count) removed from Read Later")
        }
    }
}
