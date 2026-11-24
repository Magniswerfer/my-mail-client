import Foundation

/// Layer 1 of the classification pipeline (ADR 0004): header signals only, no ML.
/// Fast and explainable; the trained classifier and Foundation Models refine it in M4.
public enum SignalClassifier {
    public struct Decision: Sendable, Hashable {
        public var category: MailCategory
        public var reason: ClassificationReason
    }

    static let socialDomains = [
        "facebookmail.com", "linkedin.com", "instagram.com", "twitter.com", "x.com", "tiktok.com",
        "pinterest.com", "reddit.com", "discord.com", "strava.com", "meetup.com", "nextdoor.com",
    ]
    static let transactionalWords = [
        "receipt", "kvittering", "invoice", "faktura", "order", "ordre", "booking", "reservation",
        "payment", "betaling", "shipped", "afsendt", "levering", "delivery", "tracking", "pakke",
        "package", "confirmation", "bekræftelse", "billet", "ticket", "refund", "refusion",
    ]
    static let promoWords = [
        "sale", "udsalg", "tilbud", "rabat", "discount", "% off", "-%", "black friday", "cyber monday",
        "offer", "deal", "gratis fragt", "free shipping", "kun i dag", "only today", "last chance",
        "sidste chance", "nyhed", "new arrivals",
    ]
    static let automatedLocalParts = [
        "noreply", "no-reply", "donotreply", "do-not-reply", "notification", "notifications",
        "notifikation", "alert", "alerts", "mailer-daemon", "info", "news", "nyhedsbrev", "newsletter",
        "kvittering", "receipts", "orders", "booking", "support", "service", "updates",
    ]

    public static func classify(_ message: ParsedMessage, userAddresses: Set<String> = []) -> Decision {
        let from = message.from.first?.address.lowercased() ?? ""
        let domain = from.split(separator: "@").last.map(String.init) ?? ""
        // "no_reply" and "no.reply" are as common as "no-reply".
        let local = (from.split(separator: "@").first.map(String.init) ?? "")
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        let subject = message.subject.lowercased()
        let isBulk = message.header("List-Unsubscribe") != nil || message.header("List-Id") != nil
            || message.header("Precedence").map { ["bulk", "list", "junk"].contains($0.lowercased()) } == true
        let isAutomated = automatedLocalParts.contains { local == $0 || local.hasPrefix($0 + "-") || local.hasPrefix($0 + ".") || local.hasPrefix($0 + "+") }
            || message.header("Auto-Submitted").map { $0.lowercased() != "no" } == true

        if userAddresses.contains(from) {
            return Decision(category: .primary, reason: .sentByYou)
        }
        if socialDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return Decision(category: .social, reason: .socialNetwork(domain: domain))
        }
        if transactionalWords.contains(where: subject.contains), isAutomated || isBulk {
            return Decision(category: .transactions, reason: .transactional)
        }
        if isBulk {
            if promoWords.contains(where: subject.contains) {
                return Decision(category: .advertising, reason: .promotional)
            }
            return isAutomated
                ? Decision(category: .newsletters, reason: .mailingListUnsubscribe)
                : Decision(category: .newsletters, reason: .mailingList)
        }
        if isAutomated {
            return Decision(category: .updates, reason: .automatedSender(local: local))
        }
        return Decision(category: .primary, reason: .person)
    }
}
