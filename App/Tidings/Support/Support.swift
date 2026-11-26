import Foundation
import MailEngine
import Security
import SwiftUI

// MARK: - Keychain

enum Keychain {
    /// "Tidings", or "Tidings-Dev" for the dev copy (set at launch) so it never reads or
    /// removes the real app's passwords.
    nonisolated(unsafe) static var service = "Tidings"
    /// Passwords go to iCloud Keychain, so your other devices can sign in to the account too
    /// (set while iCloud sync runs; never in an agent's test run).
    nonisolated(unsafe) static var synchronizes = false

    /// An account's password: saved under its login; older iCloud accounts under the username
    /// (the same thing for them).
    static func password(for account: AccountConfig) -> String? {
        password(account: account.login) ?? password(account: account.endpoint.username)
    }

    /// iCloud Keychain or this device's keychain, then (Mac) the login keychain older versions used.
    static func password(account: String) -> String? {
        var query = item(account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        if let found = read(query) { return found }
        #if os(macOS)
        return read(legacyItem(account))
        #else
        return nil
        #endif
    }

    static func save(password: String, account: String) throws {
        if synchronizes {
            if write(password, to: item(account, synchronizable: true)) == errSecSuccess {
                // One copy: the device-only one (if any) goes. Never the other way round, which
                // would delete it on every device.
                SecItemDelete(item(account, synchronizable: false) as CFDictionary)
                return
            }
            // iCloud Keychain isn't available here: keep it on this device.
        }
        var status = write(password, to: item(account, synchronizable: false))
        #if os(macOS)
        // A build without an application identifier can't use the data-protection keychain.
        if status == errSecMissingEntitlement { status = write(password, to: legacyItem(account)) }
        #endif
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// `everywhere`: also the iCloud Keychain copy, which removes it on your other devices.
    static func delete(account: String, everywhere: Bool) {
        SecItemDelete(item(account, synchronizable: false) as CFDictionary)
        if everywhere { SecItemDelete(item(account, synchronizable: true) as CFDictionary) }
        #if os(macOS)
        SecItemDelete(legacyItem(account) as CFDictionary)
        #endif
    }

    /// Passwords saved before they synced go to iCloud Keychain once, so a new device gets them.
    static func moveToICloud(_ accounts: [AccountConfig]) {
        guard synchronizes else { return }
        for account in accounts {
            let key = account.login
            guard read(item(key, synchronizable: true)) == nil, let password = password(for: account) else { continue }
            try? save(password: password, account: key)
        }
    }

    // MARK: Other secrets

    /// A secret kept on this device only, never in iCloud Keychain (say the push server's token
    /// for this device). nil removes it.
    static func setDeviceSecret(_ value: String?, account: String) {
        SecItemDelete(item(account, synchronizable: false) as CFDictionary)
        if let value { _ = write(value, to: item(account, synchronizable: false)) }
    }

    /// A secret your devices share through iCloud Keychain when sync is on (say the push
    /// server's address and pairing secret). nil removes it everywhere.
    static func setSharedSecret(_ value: String?, account: String) {
        delete(account: account, everywhere: true)
        if let value { try? save(password: value, account: account) }
    }

    static func secret(account: String) -> String? { password(account: account) }

    // MARK: Items

    private static func item(_ account: String, synchronizable: Bool? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // iCloud Keychain lives in the data-protection keychain, as on iPhone.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
        return query
    }

    #if os(macOS)
    /// The login keychain (before 0.3, and `security add-generic-password` for the probe).
    private static func legacyItem(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    #endif

    private static func read(_ query: [String: Any]) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update first: an item may already exist (deleting another tool's item can fail).
    private static func write(_ password: String, to query: [String: Any]) -> OSStatus {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }
}

// MARK: - Categories

extension MailCategory {
    var title: String {
        switch self {
        case .primary: String(localized: "Primary")
        case .transactions: String(localized: "Transactions")
        case .updates: String(localized: "Updates")
        case .newsletters: String(localized: "Newsletters")
        case .advertising: String(localized: "Advertising")
        case .social: String(localized: "Social")
        }
    }

    /// Each category has its own symbol so color never carries meaning alone (ADR 0005).
    var symbol: String {
        switch self {
        case .primary: "person.crop.circle"
        case .transactions: "creditcard"
        case .updates: "bell"
        case .newsletters: "newspaper"
        case .advertising: "tag"
        case .social: "person.2"
        }
    }

    var tint: Color {
        switch self {
        case .primary: .accentColor
        case .transactions: .teal
        case .updates: .blue
        case .newsletters: .purple
        case .advertising: .orange
        case .social: .green
        }
    }
}

extension MailboxRole {
    var title: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .sent: String(localized: "Sent")
        case .drafts: String(localized: "Drafts")
        case .trash: String(localized: "Trash")
        case .junk: String(localized: "Junk")
        case .archive: String(localized: "Archive")
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .archive: "archivebox"
        }
    }
}

// MARK: - Formatting

enum MailDate {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// "22. nov. 13.17" this year, "22. nov. 2025 13.17" otherwise.
    static func long(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension StoredMessage {
    var senderDisplay: String { fromName?.isEmpty == false ? fromName! : fromAddress }
    var isUnread: Bool { !flags.contains("\\Seen") }
    var isFlagged: Bool { flags.contains("\\Flagged") }
}

/// A neutral monogram, like Contacts. Colour is reserved for categories and status.
/// (Contacts photos and sender logos arrive in M6.)
struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
