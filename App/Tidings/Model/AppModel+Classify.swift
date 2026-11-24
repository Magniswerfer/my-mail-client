import Foundation
import MailEngine

extension ClassificationReason {
    /// "Why is this here?" in the user's language.
    var localized: String {
        switch self {
        case .sentByYou: String(localized: "You sent it")
        case .youMovedThisSender(let c): String(localized: "You moved this sender to \(c.title)")
        case .socialNetwork(let domain): String(localized: "Notification from \(domain)")
        case .transactional: String(localized: "Automated message about an order, payment or booking")
        case .promotional: String(localized: "Bulk mail with a promotional subject")
        case .mailingListUnsubscribe: String(localized: "Mailing list with an unsubscribe link")
        case .mailingList: String(localized: "Sent to a mailing list")
        case .automatedSender(let local): String(localized: "Automated sender (\(local)@)")
        case .person: String(localized: "From a person")
        case .learned(let p): String(localized: "Learned from your choices (\(p)% sure)")
        case .onDevice(let summary): String(localized: "On-device AI: \(summary)")
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

    /// "Mail from this sender belongs in X" — applies now and to future mail; undoable.
    func moveSender(to category: MailCategory, thread: ThreadSummary? = nil) {
        isCategoryPickerShown = false
        guard let thread = thread ?? targetThreads.first, let sync = syncs[thread.latest.accountID] else { return }
        let sender = thread.latest.fromAddress
        let before = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, category, classificationReason FROM message WHERE lower(fromAddress) = ?",
                             arguments: [sender.lowercased()])
        }) ?? []
        let previous = before.map { (id: $0["id"] as Int64, category: MailCategory(rawValue: $0["category"]) ?? .primary,
                                     reason: ($0["classificationReason"] as String?) ?? "") }
        Task {
            do {
                try await sync.moveSender(of: [thread.threadID], to: category)
                reload()
                let name = thread.latest.senderDisplay
                let box = ChangeBox()
                undoManager?.registerUndo(withTarget: self) { model in
                    MainActor.assumeIsolated { model.restoreCategories(previous, forgetting: sender) }
                }
                show(Toast(message: String(localized: "\(name) → \(category.title), now and in future"),
                           symbol: category.symbol, undo: box))
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func restoreCategories(_ previous: [(id: Int64, category: MailCategory, reason: String)], forgetting sender: String) {
        try? store.forgetSenderRule(sender)
        for (category, group) in Dictionary(grouping: previous, by: \.category) {
            for item in group {
                try? store.setCategory(category, reason: ClassificationReason(encoded: item.reason) ?? .person, ids: [item.id])
            }
        }
        toast = nil
        reload()
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
