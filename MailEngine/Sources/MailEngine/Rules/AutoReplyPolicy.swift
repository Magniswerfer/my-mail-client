import Foundation

/// Who a rule's automatic reply may go to (RFC 3834), or nobody.
///
/// An auto-reply sends mail as the user without anyone looking, so a sender mustn't be able
/// to steer it: not to a list of their choosing (mail forged "from you" would otherwise reply
/// to its To: list), not to a third party through Reply-To, and never into a loop with another
/// robot.
public enum AutoReplyPolicy {
    /// The one address to answer, or nil when this message mustn't get an automatic reply.
    public static func recipient(for parsed: ParsedMessage, ownAddresses: Set<String>) -> MailAddress? {
        let mine = Set(ownAddresses.map { $0.lowercased() })
        guard parsed.from.count == 1, let from = parsed.from.first else { return nil }
        let address = from.address.lowercased()
        // Mail "from you" is either yours or forged: never answer it.
        guard HeaderText.isSafeAddress(address), !mine.contains(address) else { return nil }
        // RFC 3834 §2: don't answer automatic mail, lists or bounces.
        if let auto = parsed.header("Auto-Submitted")?.trimmingCharacters(in: .whitespaces).lowercased(), auto != "no" { return nil }
        if let precedence = parsed.header("Precedence")?.lowercased(), ["bulk", "list", "junk", "auto_reply"].contains(where: precedence.contains) {
            return nil
        }
        for header in ["List-Id", "List-Unsubscribe", "List-Post", "X-Auto-Response-Suppress", "X-Autoreply", "X-Autorespond", "Feedback-ID"]
        where parsed.header(header) != nil { return nil }
        if let returnPath = parsed.header("Return-Path")?.trimmingCharacters(in: .whitespaces), returnPath == "<>" { return nil }
        let local = address.split(separator: "@").first.map(String.init) ?? ""
        if ["mailer-daemon", "postmaster", "noreply", "no-reply", "donotreply", "do-not-reply", "bounce", "bounces"]
            .contains(where: { local == $0 || local.hasPrefix($0 + "-") || local.hasPrefix($0 + "+") }) { return nil }
        // A sender whose own domain disowns the message is probably someone else.
        if let auth = parsed.header("Authentication-Results")?.lowercased(), auth.contains("dmarc=fail") || auth.contains("spf=fail") {
            return nil
        }
        // The author, not Reply-To: Reply-To can name anyone.
        return MailAddress(name: from.name, address: from.address)
    }
}
