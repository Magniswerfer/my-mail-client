import Foundation

/// The special mailboxes the app cares about.
public enum MailboxRole: String, Sendable, CaseIterable, Codable {
    case inbox, sent, drafts, trash, junk, archive
}

/// Maps server mailboxes to roles.
///
/// iCloud has no SPECIAL-USE, so roles are matched by name (case-insensitively, against
/// the last path component), with localized names included. SPECIAL-USE attributes win
/// when a server does send them.
public enum MailboxRoleResolver {
    static let namesByRole: [MailboxRole: Set<String>] = [
        .sent: ["sent messages", "sent", "sent items", "sent mail", "sendt", "sendte beskeder",
                "sendte elementer", "gesendet", "gesendete objekte", "envoyés", "enviados", "verzonden"],
        .drafts: ["drafts", "draft", "kladder", "udkast", "entwürfe", "brouillons", "borradores", "concepten"],
        .trash: ["deleted messages", "trash", "deleted items", "bin", "papirkurv", "slettede beskeder",
                 "slettede elementer", "papierkorb", "corbeille", "papelera", "prullenbak"],
        .junk: ["junk", "spam", "junk e-mail", "junk email", "uønsket", "uønsket post", "uønsket e-mail",
                "werbung", "indésirables", "correo no deseado", "ongewenst"],
        .archive: ["archive", "archives", "arkiv", "archiv", "archivo", "archief"],
    ]

    static let specialUse: [String: MailboxRole] = [
        "\\sent": .sent, "\\drafts": .drafts, "\\trash": .trash, "\\junk": .junk, "\\archive": .archive,
    ]

    /// Resolves the role of a single mailbox, or nil if it is an ordinary folder.
    public static func role(path: String, separator: Character?, attributes: [String]) -> MailboxRole? {
        if path.uppercased() == "INBOX" { return .inbox }
        for attribute in attributes {
            if let role = specialUse[attribute.lowercased()] { return role }
        }
        // Only top-level folders are treated as special: "Clients/Archive" is just a folder.
        // Right under INBOX counts as top level (Dovecot's `INBOX.` namespace: "INBOX.Trash").
        var name = path.lowercased()
        if let separator {
            let inboxPrefix = "inbox\(separator)"
            if name.hasPrefix(inboxPrefix) { name.removeFirst(inboxPrefix.count) }
            if name.contains(separator) { return nil }
        }
        return namesByRole.first { $0.value.contains(name) }?.key
    }

    /// Resolves roles for a whole mailbox list. When several mailboxes match one role, a
    /// SPECIAL-USE attribute beats a name, then the first in list order wins.
    public static func resolve(_ mailboxes: [MailboxListing]) -> [MailboxRole: String] {
        var result: [MailboxRole: String] = [:]
        for box in mailboxes {
            for attribute in box.attributes {
                if let role = specialUse[attribute.lowercased()], result[role] == nil {
                    result[role] = box.path
                }
            }
        }
        for box in mailboxes {
            if let role = role(path: box.path, separator: box.separator, attributes: []), result[role] == nil {
                result[role] = box.path
            }
        }
        return result
    }
}
