import Foundation
import MailEngine

/// The local junk filter (SPEC §8) as the app sees it: Not Junk, "It's fine", the setting, and
/// telling you when it moved something.
extension AppModel {
    static let filterJunkKey = "filterJunk"

    /// Settings › General › Junk. On unless you turn it off; it keeps learning either way.
    var filterJunk: Bool {
        UserDefaults.standard.object(forKey: Self.filterJunkKey) as? Bool ?? true
    }

    /// Whether a folder is an account's Junk.
    func isJunkMailbox(_ path: String, accountID: String) -> Bool {
        mailboxes.contains { $0.accountID == accountID && $0.path == path && $0.role == .junk }
    }

    /// You're looking at a Junk folder.
    var isInJunk: Bool {
        if case .mailbox(let account, let path) = selection { return isJunkMailbox(path, accountID: account) }
        return false
    }

    func isInJunk(_ message: StoredMessage) -> Bool {
        isJunkMailbox(message.mailbox, accountID: message.accountID)
    }

    /// "!": Move to Junk, or Not Junk when you're in Junk.
    func toggleJunk() {
        if isInJunk { notJunk() } else { perform(.junk) }
    }

    /// Back to the Inbox; the filter learns it was fine.
    func notJunk(_ threads: [ThreadSummary]? = nil) {
        perform(.moveToInbox, on: threads)
    }

    /// "It's fine": the warning goes, the filter learns the conversation as fine, it stays put.
    func markNotJunk(_ thread: ThreadSummary) {
        Task {
            for sync in syncs.values { try? await sync.markNotJunk(threadIDs: [thread.threadID]) }
            reload()
        }
    }

    /// After a pass that moved mail to Junk: say so, with Undo (which teaches it the opposite).
    func reportJunk(_ changes: [TriageChange]) {
        guard !changes.isEmpty else { return }
        let count = changes.reduce(0) { $0 + $1.threadCount }
        let box = ChangeBox()
        box.changes = changes
        let text = count == 1 ? String(localized: "Moved 1 message to Junk") : String(localized: "Moved \(count) messages to Junk")
        let undoToken = offerUndo(named: text) { [weak self] in self?.undo(box: box) }
        show(Toast(message: text, symbol: "xmark.bin", undo: undoToken))
    }
}
