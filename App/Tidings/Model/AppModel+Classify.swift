import Foundation
import MailEngine

extension ClassificationReason {
    /// "Why is this here?" in the user's language.
    var localized: String {
        switch self {
        case .sentByYou: String(localized: "You sent it")
        case .youMovedThisSender(let c): String(localized: "You moved this sender to \(c.title)")
        case .youMovedThisConversation(let c): String(localized: "You moved this conversation to \(c.title)")
        case .socialNetwork(let domain): String(localized: "Notification from \(domain)")
        case .transactional: String(localized: "Automated message about an order, payment or booking")
        case .promotional: String(localized: "Bulk mail with a promotional subject")
        case .mailingListUnsubscribe: String(localized: "Mailing list with an unsubscribe link")
        case .mailingList: String(localized: "Sent to a mailing list")
        case .automatedSender(let local): String(localized: "Automated sender (\(local)@)")
        case .person: String(localized: "From a person")
        case .calendarInvite: String(localized: "A meeting invitation for you")
        case .calendarReply: String(localized: "An answer to your invitation")
        case .learned(let p): String(localized: "Learned from your choices (\(p)% sure)")
        case .onDevice(let summary): String(localized: "On-device AI: \(summary)")
        case .rule(let name): String(localized: "Your rule “\(name)”")
        }
    }
}

extension StoredMessage {
    var reasonText: String? {
        guard let raw = classificationReason else { return nil }
        return ClassificationReason(encoded: raw)?.localized ?? raw
    }
}

extension AppModel {
    func allowsRemoteImages(from sender: String) -> Bool {
        (try? store.allowsRemoteImages(from: sender, ownAddresses: ownAddresses)) ?? false
    }

    func trustImages(from senderOrDomain: String) {
        try? store.trustImages(from: senderOrDomain)
    }

    /// Moves conversations to a category: "this one" (teaches the classifier; two consistent
    /// moves of a sender become a rule). Local and instant; undoable from the toast or ⌘Z.
    func moveConversations(_ threads: [ThreadSummary], to category: MailCategory) {
        isCategoryPickerShown = false
        guard !threads.isEmpty,
              let result = try? store.moveConversations(threads.map(\.threadID), to: category, ownAddresses: ownAddresses)
        else { return }
        // Moved on purpose: these leave the bundle or category they're held in, and your categories.
        releaseHolds(threads.map(\.threadID))
        let left = leaveCustomCategories(threads.map(\.threadID), sender: result.promotedSender)
        // A moved ⌘A block is done with; back to one row.
        multiSelection = []
        let undo: @MainActor () -> Void = { [weak self] in
            self?.releaseHolds(threads.map(\.threadID))
            self?.restore(left)
            try? self?.store.restoreCategories(result.previous)
            if let sender = result.promotedSender { try? self?.store.forgetSenderRule(sender) }
            self?.toast = nil
            self?.reload()
        }
        let undoToken = registerCategoryUndo(undo)
        reload()
        let message: String
        if let sender = result.promotedSender {
            let name = threads.first(where: { $0.latest.fromAddress.lowercased() == sender })?.latest.senderDisplay ?? sender
            message = String(localized: "Got it: mail from \(name) goes to \(category.title) from now on")
        } else {
            message = threads.count == 1 ? String(localized: "Moved to \(category.title)") : String(localized: "\(threads.count) moved to \(category.title)")
        }
        show(Toast(message: message, symbol: category.symbol, undo: undoToken))
    }

    /// "Mail from this sender belongs in X": now and for future mail; undoable.
    func moveSender(to category: MailCategory, thread: ThreadSummary? = nil) {
        isCategoryPickerShown = false
        guard let thread = thread ?? targetThreads.first else { return }
        moveSender(to: category, address: thread.latest.fromAddress, name: thread.latest.senderDisplay)
    }

    /// "Always for this sender", by address (the Senders screen).
    func moveSender(to category: MailCategory, address sender: String, name: String) {
        let previous = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, category, classificationReason FROM message WHERE lower(fromAddress) = ?",
                             arguments: [sender.lowercased()])
        })?.map { MailStore.CategorySnapshot(id: $0["id"], category: MailCategory(rawValue: $0["category"]) ?? .primary,
                                            reason: $0["classificationReason"]) } ?? []
        guard (try? store.remember(category: category, forSender: sender)) != nil else { return }
        let fromSender = { [weak self] in
            self?.threads.filter { $0.latest.fromAddress.lowercased() == sender.lowercased() }.map(\.threadID) ?? []
        }
        releaseHolds(fromSender())
        let left = leaveCustomCategories((try? store.threadIDs(fromSender: sender.lowercased())) ?? [], sender: sender)
        let undo: @MainActor () -> Void = { [weak self] in
            self?.releaseHolds(fromSender())
            self?.restore(left)
            try? self?.store.forgetSenderRule(sender)
            try? self?.store.restoreCategories(previous)
            self?.toast = nil
            self?.reload()
        }
        let undoToken = registerCategoryUndo(undo)
        reload()
        show(Toast(message: String(localized: "\(name) → \(category.title), now and in future"),
                   symbol: category.symbol, undo: undoToken))
    }

    /// Registered synchronously (inside the click/key event) so AppKit's undo grouping sees it.
    private func registerCategoryUndo(_ undo: @escaping @MainActor () -> Void) -> UndoToken {
        offerUndo(named: String(localized: "Move"), undo)
    }
}

import GRDB

extension RiskReason {
    var localized: String {
        switch self {
        case .dmarcFailed: String(localized: "The sender's domain did not vouch for this message (DMARC failed).")
        case .dkimFailed: String(localized: "The message's signature didn't check out (DKIM failed).")
        case .spfFailed: String(localized: "It came from a server the sender's domain doesn't use (SPF failed).")
        case .brandInDisplayName(let brand, let domain): String(localized: "It claims to be \(brand.capitalized), but comes from \(domain).")
        case .addressInDisplayName(let shown): String(localized: "The name shows \(shown), which isn't the real sender.")
        case .lookalikeDomain(let domain, let resembles): String(localized: "\(domain) looks like \(resembles), but isn't.")
        case .punycodeDomain(let domain): String(localized: "\(domain) uses look-alike characters.")
        case .linkMismatch(let shown, let actual): String(localized: "A link shows \(shown) but goes to \(actual).")
        case .replyToElsewhere(let domain): String(localized: "Replies would go to \(domain).")
        }
    }
}

extension AppModel {
    func markSafe(_ message: StoredMessage) {
        try? store.markSafe(sender: message.fromAddress)
        reload()
    }
}
