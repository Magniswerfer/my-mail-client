import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Incoming and outgoing servers for a generic IMAP/SMTP account (what the setup form fills in).
public struct MailServerSettings: Sendable, Hashable {
    public var imap: IMAPEndpoint
    public var smtp: SMTPEndpoint
    /// Where the settings came from, for the form ("Gmail", "autoconfig.example.com").
    public var source: String
    /// Something to tell the user before they try (an app password is needed, …), in English;
    /// the app shows its own localized text for `MailProvider.Note`.
    public var note: MailProvider.Note?

    public init(imap: IMAPEndpoint, smtp: SMTPEndpoint, source: String, note: MailProvider.Note? = nil) {
        self.imap = imap
        self.smtp = smtp
        self.source = source
        self.note = note
    }
}

/// Server settings for common providers, built in (no network), and Thunderbird's autoconfig
/// for everything else.
public enum MailProvider {
    public enum Note: String, Sendable, Hashable {
        /// Sign-in with the account password is off; make an app password in the provider's security settings.
        case appPassword
        /// The provider only lets other mail apps in through its own sign-in (OAuth), which Tidings doesn't do yet.
        case oauthOnly
        /// This is iCloud: use the iCloud setup instead (it explains app-specific passwords).
        case iCloud
    }

    /// IMAP over implicit TLS: the only kind Tidings connects to (no STARTTLS on IMAP yet).
    static let imapsPort: UInt16 = 993
    static let smtpsPort = 465
    static let submissionPort = 587

    struct Known {
        var name: String
        var domains: [String]
        var imapHost: String
        var smtpHost: String
        var smtpPort: Int = MailProvider.smtpsPort
        var smtpSecurity: SMTPEndpoint.Security = .tls
        var note: Note? = nil
    }

    static let known: [Known] = [
        Known(name: "iCloud", domains: ["icloud.com", "me.com", "mac.com"], imapHost: "imap.mail.me.com",
              smtpHost: "smtp.mail.me.com", smtpPort: submissionPort, smtpSecurity: .startTLS, note: .iCloud),
        Known(name: "Gmail", domains: ["gmail.com", "googlemail.com"], imapHost: "imap.gmail.com",
              smtpHost: "smtp.gmail.com", note: .appPassword),
        Known(name: "Outlook.com", domains: ["outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.dk", "hotmail.dk", "live.dk"],
              imapHost: "outlook.office365.com", smtpHost: "smtp-mail.outlook.com", smtpPort: submissionPort, smtpSecurity: .startTLS,
              note: .oauthOnly),
        Known(name: "Yahoo", domains: ["yahoo.com", "yahoo.dk", "yahoo.co.uk", "ymail.com", "rocketmail.com"],
              imapHost: "imap.mail.yahoo.com", smtpHost: "smtp.mail.yahoo.com", note: .appPassword),
        Known(name: "AOL", domains: ["aol.com"], imapHost: "imap.aol.com", smtpHost: "smtp.aol.com", note: .appPassword),
        Known(name: "Fastmail", domains: ["fastmail.com", "fastmail.fm"], imapHost: "imap.fastmail.com",
              smtpHost: "smtp.fastmail.com", note: .appPassword),
        Known(name: "GMX", domains: ["gmx.net", "gmx.de", "gmx.at", "gmx.ch"], imapHost: "imap.gmx.net",
              smtpHost: "mail.gmx.net", smtpPort: submissionPort, smtpSecurity: .startTLS),
        Known(name: "GMX", domains: ["gmx.com"], imapHost: "imap.gmx.com", smtpHost: "mail.gmx.com", smtpPort: submissionPort, smtpSecurity: .startTLS),
        Known(name: "WEB.DE", domains: ["web.de"], imapHost: "imap.web.de", smtpHost: "smtp.web.de", smtpPort: submissionPort, smtpSecurity: .startTLS),
        Known(name: "Zoho Mail", domains: ["zoho.com", "zohomail.com"], imapHost: "imap.zoho.com", smtpHost: "smtp.zoho.com"),
        Known(name: "mailbox.org", domains: ["mailbox.org"], imapHost: "imap.mailbox.org", smtpHost: "smtp.mailbox.org"),
        Known(name: "Posteo", domains: ["posteo.de", "posteo.net"], imapHost: "posteo.de", smtpHost: "posteo.de"),
    ]

    /// The domain of an address, lowercased ("anna@Example.dk" → "example.dk").
    public static func domain(of address: String) -> String? {
        let parts = address.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return nil }
        return String(parts[1])
    }

    /// The full address, as most providers want it for the login.
    static func login(for address: String) -> String {
        address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Built-in settings for a well-known provider, without asking the network.
    public static func builtIn(for address: String) -> MailServerSettings? {
        guard let domain = domain(of: address), let p = known.first(where: { $0.domains.contains(domain) }) else { return nil }
        let login = Self.login(for: address)
        return MailServerSettings(
            imap: IMAPEndpoint(host: p.imapHost, port: imapsPort, useTLS: true, username: login),
            smtp: SMTPEndpoint(host: p.smtpHost, port: p.smtpPort, security: p.smtpSecurity, username: login),
            source: p.name, note: p.note)
    }

    /// A guess when nothing else is known: imap.<domain> and smtp.<domain>, the full address as login.
    public static func guess(for address: String) -> MailServerSettings? {
        guard let domain = domain(of: address) else { return nil }
        let login = Self.login(for: address)
        return MailServerSettings(
            imap: IMAPEndpoint(host: "imap.\(domain)", port: imapsPort, useTLS: true, username: login),
            smtp: SMTPEndpoint(host: "smtp.\(domain)", port: submissionPort, security: .startTLS, username: login),
            source: domain)
    }

    // MARK: Autoconfig

    /// Fetches a URL's body; injectable so tests never touch the network.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// Autoconfig is a nicety: the form must not wait long for it.
    static let autoconfigTimeout: TimeInterval = 8

    public static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: MailProvider.autoconfigTimeout)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Where to look, in order: the domain's own autoconfig (only the domain is sent, never the
    /// address), then Thunderbird's public database (ISPDB). HTTPS only.
    public static func autoconfigURLs(for domain: String) -> [URL] {
        [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml",
            "https://autoconfig.thunderbird.net/v1.1/\(domain)",
        ].compactMap(URL.init(string:))
    }

    /// Settings for any address: built in, else autoconfig, else nil (the form keeps its guess).
    public static func lookUp(_ address: String, fetch: Fetch = urlSessionFetch) async -> MailServerSettings? {
        if let builtIn = builtIn(for: address) { return builtIn }
        guard let domain = domain(of: address) else { return nil }
        for url in autoconfigURLs(for: domain) {
            guard !Task.isCancelled else { return nil }
            if let data = try? await fetch(url), let settings = parseAutoconfig(data, address: address) {
                var found = settings
                found.source = url.host ?? domain
                return found
            }
        }
        return nil
    }

    /// Reads a Thunderbird `clientConfig` document (config-v1.1.xml). Takes the first IMAP server
    /// with implicit TLS (Tidings can't do STARTTLS on IMAP yet) and the first SMTP server with
    /// TLS or STARTTLS; never a plain-text one.
    public static func parseAutoconfig(_ data: Data, address: String) -> MailServerSettings? {
        let reader = AutoconfigReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let login = Self.login(for: address)
        let localPart = login.split(separator: "@").first.map(String.init) ?? login
        let domain = domain(of: login) ?? ""
        func expand(_ s: String) -> String {
            s.replacingOccurrences(of: "%EMAILADDRESS%", with: login)
                .replacingOccurrences(of: "%EMAILLOCALPART%", with: localPart)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
        }
        guard let imap = reader.servers.first(where: { $0.kind == "incoming" && $0.type == "imap" && $0.socketType == "SSL" }),
              let smtp = reader.servers.first(where: { $0.kind == "outgoing" && $0.type == "smtp" && ($0.socketType == "SSL" || $0.socketType == "STARTTLS") }),
              let imapPort = UInt16(imap.port), let smtpPort = Int(smtp.port), !imap.hostname.isEmpty, !smtp.hostname.isEmpty
        else { return nil }
        return MailServerSettings(
            imap: IMAPEndpoint(host: expand(imap.hostname).lowercased(), port: imapPort, useTLS: true,
                               username: imap.username.isEmpty ? login : expand(imap.username)),
            smtp: SMTPEndpoint(host: expand(smtp.hostname).lowercased(), port: smtpPort,
                               security: smtp.socketType == "SSL" ? .tls : .startTLS,
                               username: smtp.username.isEmpty ? login : expand(smtp.username)),
            source: reader.displayName ?? domain)
    }
}

private final class AutoconfigReader: NSObject, XMLParserDelegate {
    struct Server {
        var kind: String
        var type: String
        var hostname = ""
        var port = ""
        var socketType = ""
        var username = ""
    }

    var servers: [Server] = []
    var displayName: String?
    private var current: Server?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "incomingServer": current = Server(kind: "incoming", type: attributes["type"]?.lowercased() ?? "")
        case "outgoingServer": current = Server(kind: "outgoing", type: attributes["type"]?.lowercased() ?? "")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "hostname": current?.hostname = value
        case "port": current?.port = value
        case "socketType": current?.socketType = value.uppercased()
        case "username": current?.username = value
        case "displayName" where current == nil && displayName == nil: displayName = value.isEmpty ? nil : value
        case "incomingServer", "outgoingServer":
            if let current { servers.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}

extension AccountConfig {
    /// iCloud Mail (app-specific password, iCloud quirks).
    public var isICloud: Bool { endpoint.host.hasSuffix("mail.me.com") }

    /// How the account is known across devices (CloudKit keys, Keychain): the login, plus the
    /// server for logins that aren't an address, so "magnus" on two servers stays two accounts.
    public var login: String {
        let user = endpoint.username.lowercased()
        return user.contains("@") ? user : "\(user)@\(endpoint.host.lowercased())"
    }

    /// For `account:` in search: the id, the name, an address, its domain or the domain's
    /// first label ("work" for magnus@work.test), the server's host.
    public func matches(searchValue raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return false }
        if id.lowercased() == value || displayName.lowercased() == value { return true }
        if displayName.lowercased().split(separator: " ").contains(where: { $0 == value }) { return true }
        let addresses = Set((addresses + [endpoint.username]).map { $0.lowercased() })
        if addresses.contains(value) { return true }
        let domains = addresses.compactMap { MailProvider.domain(of: $0) }
        if domains.contains(value) || domains.contains(where: { $0.split(separator: ".").first.map(String.init) == value }) { return true }
        return endpoint.host.lowercased() == value
    }
}
