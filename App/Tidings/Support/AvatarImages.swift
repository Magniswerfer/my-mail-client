import Contacts
import MailEngine
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pictures for avatars: the person's photo from Apple Contacts, else the icon of the website
/// their address is at (nytimes.com for nytdirect@nytimes.com), else none (initials). Not for
/// free mail domains (gmail.com, icloud.com…): a friend on Gmail shouldn't get Google's logo.
@MainActor @Observable
final class AvatarImages {
    static let shared = AvatarImages()

    enum Picture {
        case photo(PlatformImage)
        case icon(PlatformImage)
    }

    /// By lowercased address ("name:<name>" when there's no address); a missing entry is not
    /// looked up yet, `.none` found nothing.
    private(set) var pictures: [String: Picture?] = [:]
    @ObservationIgnored private var looking: Set<String> = []
    @ObservationIgnored private let contacts = CNContactStore()

    /// Settings › Reading: "Show Website Icons" (on unless turned off).
    static let websiteIconsKey = "avatars.websiteIcons"
    var showsWebsiteIcons: Bool {
        get { UserDefaults.standard.object(forKey: Self.websiteIconsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.websiteIconsKey)
            pictures = pictures.filter { if case .photo = $0.value { true } else { false } }
        }
    }

    func picture(address: String?, name: String) -> Picture? {
        let key = Self.key(address: address, name: name)
        if let found = pictures[key] { return found }
        guard !looking.contains(key), !ProcessInfo.processInfo.arguments.contains("-TidingsNoAvatarLookups") else { return nil }
        looking.insert(key)
        Task { await lookUp(key: key, address: address, name: name) }
        return nil
    }

    private static func key(address: String?, name: String) -> String {
        if let address, address.contains("@") { return address.lowercased() }
        return "name:" + name.lowercased()
    }

    private func lookUp(key: String, address: String?, name: String) async {
        defer { looking.remove(key) }
        if let photo = await contactPhoto(address: address, name: name) {
            pictures[key] = .photo(photo)
            return
        }
        if showsWebsiteIcons, let domain = address.flatMap(Self.domain), let icon = await WebsiteIcons.shared.icon(for: domain) {
            pictures[key] = .icon(icon)
            return
        }
        pictures[key] = .some(nil)
    }

    // MARK: Apple Contacts

    private func contactPhoto(address: String?, name: String) async -> PlatformImage? {
        guard await contactsAllowed() else { return nil }
        let data = await Task.detached(priority: .utility) { Self.contactPhotoData(address: address, name: name) }.value
        return data.flatMap(PlatformImage.init(data:))
    }

    /// The photo of the contact with this address, else of the one contact by this full name.
    nonisolated static func contactPhotoData(address: String?, name: String) -> Data? {
        let store = CNContactStore()
        let keys = [CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
                    CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        if let address, address.contains("@"),
           let match = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: address), keysToFetch: keys)
            .first(where: \.imageDataAvailable) {
            return match.thumbnailImageData
        }
        // By full name only when it's unambiguous: one contact with a photo by that name.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(" "), !trimmed.contains("@"),
              let byName = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: trimmed), keysToFetch: keys)
        else { return nil }
        let exact = byName.filter { "\($0.givenName) \($0.familyName)".caseInsensitiveCompare(trimmed) == .orderedSame && $0.imageDataAvailable }
        return exact.count == 1 ? exact[0].thumbnailImageData : nil
    }

    /// Asks once; "Don't Allow" means initials and icons only.
    private func contactsAllowed() async -> Bool {
        // Test runs (`-TidingsNoContacts`) never ask for or read your contacts.
        if ProcessInfo.processInfo.arguments.contains("-TidingsNoContacts") { return false }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined: return (try? await contacts.requestAccess(for: .contacts)) ?? false
        default: return false
        }
    }

    // MARK: Website icons

    /// The registrable domain after the @ ("news.example.com" → "example.com"), unless it's a
    /// free mail service, a test address, or a local or private-network host.
    ///
    /// Only the registrable domain is ever fetched: a sender could otherwise mail you from
    /// `x@<a-code-for-you>.their-site.com` and learn from the icon request that, and when, the
    /// message reached your screen.
    nonisolated static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let full = address[address.index(after: at)...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        guard full.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }), !NetworkTarget.isLocal(host: full) else { return nil }
        let labels = full.split(separator: ".")
        guard labels.count >= 2, !labels.last!.allSatisfy(\.isNumber) else { return nil }
        // "shop.co.uk" keeps three labels; otherwise two.
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "ac", "gov", "edu", "ltd", "plc", "or", "ne", "go"]
        let keep = labels.count >= 3 && labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        let domain = labels.suffix(keep).joined(separator: ".")
        guard !freeMail.contains(domain), !freeMail.contains(full), !domain.hasSuffix(".test"), !domain.hasSuffix(".example"),
              !domain.hasSuffix("example.com"), !domain.hasSuffix(".invalid"), !domain.hasSuffix(".local") else { return nil }
        return domain
    }

    nonisolated static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "hotmail.dk",
        "live.com", "live.dk", "msn.com", "yahoo.com", "yahoo.dk", "ymail.com", "aol.com", "proton.me", "protonmail.com",
        "pm.me", "gmx.com", "gmx.net", "gmx.de", "mail.com", "zoho.com", "fastmail.com", "hey.com", "tutanota.com",
        "tuta.io", "mail.dk", "jubii.dk", "ofir.dk", "stofanet.dk", "privat.dk", "webspeed.dk",
    ]
}

/// Fetches and caches website icons, on disk for 30 days (misses for 7). No cookies, nothing
/// but the site's own icon files: the apple-touch-icon, the page's <link rel="icon">, /favicon.ico.
actor WebsiteIcons {
    static let shared = WebsiteIcons()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("WebsiteIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func icon(for domain: String) async -> PlatformImage? {
        if let task = inFlight[domain] { return await task.value }
        let task = Task { await load(domain) }
        inFlight[domain] = task
        let image = await task.value
        inFlight[domain] = nil
        return image
    }

    private func load(_ domain: String) async -> PlatformImage? {
        let file = folder.appendingPathComponent(domain + ".img")
        let miss = folder.appendingPathComponent(domain + ".none")
        if let age = Self.age(of: file), age < 30 * 86_400, let data = try? Data(contentsOf: file) { return PlatformImage(data: data) }
        if let age = Self.age(of: miss), age < 7 * 86_400 { return nil }
        // Already the registrable domain (`AvatarImages.domain(of:)`): never a sender's subdomain.
        for host in [domain] {
            if let data = await fetchIcon(host: host), let image = PlatformImage(data: data), Self.isUsable(image) {
                try? data.write(to: file)
                try? FileManager.default.removeItem(at: miss)
                return image
            }
        }
        FileManager.default.createFile(atPath: miss.path, contents: nil)
        return nil
    }

    private func fetchIcon(host: String) async -> Data? {
        guard let base = URL(string: "https://\(host)/") else { return nil }
        if let data = await fetch(base.appendingPathComponent("apple-touch-icon.png"), image: true) { return data }
        if let page = await fetch(base, image: false), let html = String(data: page.prefix(200_000), encoding: .utf8) ?? String(data: page.prefix(200_000), encoding: .isoLatin1),
           let href = Self.iconLink(in: html), let url = URL(string: href, relativeTo: base)?.absoluteURL,
           url.scheme == "https", let data = await fetch(url, image: true) {
            return data
        }
        return await fetch(base.appendingPathComponent("favicon.ico"), image: true)
    }

    private func fetch(_ url: URL, image: Bool) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Tidings", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 0, data.count < 1_000_000 else { return nil }
        if image, let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.hasPrefix("text/") { return nil }
        return data
    }

    /// The best icon a page names: apple-touch-icon, else the largest "icon".
    static func iconLink(in html: String) -> String? {
        var best: (score: Int, href: String)?
        for match in html.matches(of: /(?is)<link\b[^<>]*>/) {
            let tag = String(match.output)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag), !href.hasPrefix("data:") else { continue }
            let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") } ?? 16
            let score = (rel.contains("apple-touch-icon") ? 1_000 : 0) + size - (href.hasSuffix(".svg") ? 2_000 : 0)
            if best == nil || score > best!.score { best = (score, href) }
        }
        return best?.href
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("(?i)\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"),
              let m = tag.firstMatch(of: regex), let value = m.output[1].substring else { return nil }
        return String(value).replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Big enough to show, and not a 1×1 placeholder.
    static func isUsable(_ image: PlatformImage) -> Bool { image.size.width >= 16 && image.size.height >= 16 }

    static func age(of url: URL) -> TimeInterval? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
