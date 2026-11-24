import Foundation
import MailEngine
import Security
import SwiftUI

// MARK: - Keychain

enum Keychain {
    static let service = "Tidings"

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update first: an item made with `security add-generic-password` (M0 probe) may already
        // exist, and deleting another tool's item can fail. macOS may ask once to allow access.
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data(password.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
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

    static func long(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension StoredMessage {
    var senderDisplay: String { fromName?.isEmpty == false ? fromName! : fromAddress }
    var isUnread: Bool { !flags.contains("\\Seen") }
    var isFlagged: Bool { flags.contains("\\Flagged") }
}

/// A monogram avatar tinted by category. (Contacts photos and BIMI logos arrive in M6.)
struct Avatar: View {
    let name: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Circle()
            .fill(tint.gradient.opacity(0.85))
            .frame(width: size, height: size)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
