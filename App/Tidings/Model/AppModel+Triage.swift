import Foundation
import MailEngine
import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String
    var undo: ChangeBox? = nil
    /// Outbox id of a message in its undo-send window.
    var undoSend: Int64? = nil
    /// Any other undoable change (category moves).
    var undoAction: (@MainActor () -> Void)? = nil

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
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

    /// What an action applies to: the selected conversation.
    var targetThreads: [ThreadSummary] {
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.threadID == id }) else { return [] }
        return [thread]
    }

    /// The mailbox the current view shows (where moves start from).
    var sourceMailbox: String {
        switch selection {
        case .inbox, .category, .outbox: "INBOX"
        case .snoozed: AccountSync.snoozedMailbox
        case .mailbox(_, let path): path
        }
    }

    // MARK: Performing

    @discardableResult
    func perform(_ kind: TriageKind, on threads: [ThreadSummary]? = nil, toast showToast: Bool = true) -> ChangeBox? {
        let targets = threads ?? targetThreads
        guard !targets.isEmpty else { return nil }
        let nextSelection = neighbour(after: targets.map(\.threadID))
        let box = ChangeBox()
        if showToast {
            registerUndo(box, kind: kind, count: targets.count)
            show(Toast(message: kind.toastText(count: targets.count), symbol: kind.symbol, undo: box))
        }
        let ids = Set(targets.map(\.threadID))
        if kind.removesFromView {
            // One motion: the row leaves and the selection moves on together, before the engine
            // has written anything (it catches up a moment later; see `pendingRemovals`).
            pendingRemovals.formUnion(ids)
            withAnimation(.snappy(duration: 0.22)) {
                self.threads.removeAll { ids.contains($0.threadID) }
                selectedThreadID = nextSelection
            }
        }
        let source = sourceMailbox
        Task {
            for (accountID, group) in Dictionary(grouping: targets, by: \.latest.accountID) {
                guard let sync = syncs[accountID] else { continue }
                do {
                    if let change = try await sync.perform(kind, threadIDs: group.map(\.threadID), from: source) {
                        box.changes.append(change)
                    }
                } catch {
                    lastError = String(describing: error)
                }
            }
            // Undo was pressed before the engine finished: reverse right away.
            if box.undone { await undo(box) }
            pendingRemovals.subtract(ids)
            reload()
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
            if let change = try? await syncs[accountID]?.perform(kind, threadIDs: [threadID], from: mailbox) {
                box.changes.append(change)
            }
            if box.undone { await undo(box) }
            reload()
        }
        return box
    }

    func toggleReplyLater() {
        guard let thread = targetThreads.first else { return }
        perform(thread.isReplyLater ? .clearReplyLater : .replyLater)
    }

    /// The conversation to select after the current one leaves the list (next, else previous).
    private func neighbour(after removed: [String]) -> String? {
        let ids = visibleThreadIDs
        guard let current = selectedThreadID, let index = ids.firstIndex(of: current) else { return selectedThreadID }
        let remaining = ids.enumerated().filter { !removed.contains($0.element) }
        return remaining.first { $0.offset > index }?.element ?? remaining.last { $0.offset < index }?.element
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
    var sweepableCount: Int { selection == .inbox ? threads.filter { !$0.isPinned }.count : 0 }

    // MARK: Sweep

    /// Done for everything in the Inbox that isn't pinned (or for one bundle).
    func requestSweep(bundle: MailCategory? = nil) {
        let candidates = threads.filter { !$0.isPinned && (bundle == nil || $0.latest.category == bundle) }
        guard !candidates.isEmpty else { return }
        let title = bundle.map { String(localized: "Mark all \($0.title) done?") } ?? String(localized: "Sweep the Inbox?")
        sweepCandidate = SweepRequest(threadIDs: candidates.map(\.threadID), title: title)
    }

    func confirmSweep(_ request: SweepRequest) {
        sweepCandidate = nil
        let targets = threads.filter { request.threadIDs.contains($0.threadID) }
        perform(.done, on: targets)
    }

    // MARK: Undo

    private func registerUndo(_ box: ChangeBox, kind: TriageKind, count: Int) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undo(box: box) }
        }
        undoManager.setActionName(kind.toastText(count: count))
    }

    /// Undo from the toast: through the window's undo manager when it has our action on top
    /// (so ⌘Z and the menu stay in step), otherwise directly.
    func undoFromToast(_ box: ChangeBox) {
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            undo(box: box)
        }
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

extension TriageKind {
    var removesFromView: Bool {
        switch self {
        case .done, .trash, .junk, .moveToInbox, .snooze, .unsnooze: true
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
        case .snooze: "clock"
        case .unsnooze: "clock.arrow.circlepath"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .markRead: "envelope.open"
        case .markUnread: "envelope.badge"
        case .replyLater: "arrowshape.turn.up.left.circle"
        case .clearReplyLater: "checkmark.circle"
        }
    }

    func toastText(count: Int) -> String {
        switch self {
        case .done: count == 1 ? String(localized: "Marked done") : String(localized: "\(count) conversations done")
        case .trash: String(localized: "Moved to Trash")
        case .junk: String(localized: "Moved to Junk")
        case .moveToInbox: String(localized: "Moved to Inbox")
        case .snooze(let until):
            until.map { String(localized: "Snoozed until \($0.formatted(.dateTime.weekday(.wide).hour().minute()))") }
                ?? String(localized: "Snoozed for someday")
        case .unsnooze: String(localized: "Back in the Inbox")
        case .pin: String(localized: "Pinned")
        case .unpin: String(localized: "Unpinned")
        case .markRead: String(localized: "Marked read")
        case .markUnread: String(localized: "Marked unread")
        case .replyLater: count == 1 ? String(localized: "Set aside to reply later") : String(localized: "\(count) set aside to reply later")
        case .clearReplyLater: String(localized: "Removed from Reply Later")
        }
    }
}
