import Foundation

/// "Alice, meet Bob": reply to everyone the introducer brought in, and move the introducer to
/// Bcc so they see you followed up but drop out of the rest of the thread.
public enum IntroReply {
    public struct Plan: Sendable, Hashable {
        public var introducer: MailAddress
        public var to: [MailAddress]
        public var cc: [MailAddress]
        public var bcc: [MailAddress]
    }

    /// Nil when there's nobody to reply to besides the introducer.
    public static func plan(for message: ParsedMessage, ownAddresses: Set<String>) -> Plan? {
        let own = Set(ownAddresses.map { $0.lowercased() })
        guard let introducer = (message.replyTo.first ?? message.from.first),
              !own.contains(introducer.address.lowercased()) else { return nil }
        var seen: Set<String> = own.union([introducer.address.lowercased()])
        message.from.forEach { seen.insert($0.address.lowercased()) }
        let to = message.to.filter { seen.insert($0.address.lowercased()).inserted }
        let cc = message.cc.filter { seen.insert($0.address.lowercased()).inserted }
        guard !to.isEmpty || !cc.isEmpty else { return nil }
        // Everyone introduced goes on To; the introducer's own Cc'd colleagues stay on Cc.
        return to.isEmpty ? Plan(introducer: introducer, to: cc, cc: [], bcc: [introducer])
                          : Plan(introducer: introducer, to: to, cc: cc, bcc: [introducer])
    }

    /// "Anna" from "Anna Holm", "anna.holm@firma.dk" → "Anna".
    public static func firstName(_ address: MailAddress) -> String {
        if let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // "Holm, Anna" → "Anna"
            if let comma = name.firstIndex(of: ",") {
                return name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? name
            }
            return name.split(separator: " ").first.map(String.init) ?? name
        }
        let local = address.address.split(separator: "@").first.map(String.init) ?? address.address
        let first = local.split(whereSeparator: { ".-_".contains($0) }).first.map(String.init) ?? local
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}
