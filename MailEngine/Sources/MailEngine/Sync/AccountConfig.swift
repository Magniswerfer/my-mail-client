import Foundation

/// One configured mail account.
public struct AccountConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var endpoint: IMAPEndpoint
    /// Addresses that belong to the user (login + custom-domain identities), used to spot "sent by me".
    public var addresses: [String]
    /// Outgoing server; nil means the provider default (iCloud: smtp.mail.me.com:587).
    /// Optional (like `identities`) so accounts saved before M3 still decode.
    public var smtp: SMTPEndpoint?
    public var identities: [Identity]?

    public init(id: String = UUID().uuidString, displayName: String, endpoint: IMAPEndpoint, addresses: [String],
                smtp: SMTPEndpoint? = nil, identities: [Identity]? = nil) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.addresses = addresses
        self.smtp = smtp
        self.identities = identities
    }

    /// Identities to send from; falls back to the account's addresses.
    public var sendingIdentities: [Identity] {
        if let identities, !identities.isEmpty { return identities }
        return addresses.map { Identity(address: $0, name: "") }
    }

    /// The identity a reply should come from: whichever of mine the original was sent to (SPEC §9).
    public func identity(replyingTo parsed: ParsedMessage) -> Identity {
        let received = Set((parsed.to + parsed.cc).map { $0.address.lowercased() })
        return sendingIdentities.first { received.contains($0.address.lowercased()) } ?? sendingIdentities.first
            ?? Identity(address: endpoint.username, name: "")
    }
}
