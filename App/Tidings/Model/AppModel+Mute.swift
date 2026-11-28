import Foundation
import MailEngine

/// Mute (SPEC §11): the conversation leaves the Inbox now, and new messages in it go straight
/// to the Archive without a notification. Kept on this device.
extension AppModel {
    /// From memory (`mutedThreadIDs`, read with each reload): menus ask this for every row.
    func isMuted(_ threadID: String) -> Bool {
        mutedThreadIDs.contains(threadID)
    }

    /// ⇧M: mute (and mark done) the selected conversations, or unmute them if they all are.
    func toggleMute(_ threads: [ThreadSummary]? = nil) {
        let targets = threads ?? targetThreads
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.threadID)
        if ids.allSatisfy(isMuted) {
            for id in ids { try? store.unmute(threadID: id) }
            mutedThreadIDs.subtract(ids)
            revision &+= 1
            show(Toast(message: String(localized: "Unmuted"), symbol: "bell"))
            return
        }
        for id in ids { try? store.mute(threadID: id) }
        mutedThreadIDs.formUnion(ids)
        // Muting in the Inbox also takes it out of the Inbox; elsewhere it only mutes.
        let box = sourceMailbox == "INBOX" ? perform(.done, on: targets, toast: false) : nil
        let undo: @MainActor () -> Void = { [weak self] in
            for id in ids { try? self?.store.unmute(threadID: id) }
            self?.mutedThreadIDs.subtract(ids)
            if let box { self?.undo(box: box) }
            self?.revision &+= 1
        }
        let undoToken = offerUndo(named: String(localized: "Mute"), undo)
        show(Toast(message: ids.count == 1 ? String(localized: "Muted. New replies skip the Inbox.")
                                          : String(localized: "\(ids.count) conversations muted"),
                   symbol: "bell.slash", undo: undoToken))
    }

    func unmute(threadID: String) {
        try? store.unmute(threadID: threadID)
        mutedThreadIDs.remove(threadID)
        revision &+= 1
    }
}
