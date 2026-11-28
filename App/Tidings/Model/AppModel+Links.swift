import EventKit
import Foundation
import MailEngine
import SwiftUI

/// `tidings://message/<Message-ID>`: a stable link to a message that works on every device with
/// the account (the Message-ID travels with the mail), for Reminders, Things, Notes and Shortcuts.
enum MessageLink {
    static let scheme = "tidings"
    static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!$&'()*+,;=:@"))

    static func url(for messageID: String) -> URL? {
        let clean = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !clean.isEmpty, let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://message/\(encoded)")
    }

    static func messageID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "message" else { return nil }
        let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let id = raw.removingPercentEncoding ?? raw
        return id.isEmpty ? nil : id
    }
}

extension AppModel {
    /// The newest message of the open conversation (what links and tasks point at).
    var currentMessage: StoredMessage? {
        guard let threadID = readerThreadID ?? selectedThreadID else { return nil }
        return messages(inThread: threadID).last
    }

    func link(for message: StoredMessage) -> URL? {
        message.messageID.flatMap(MessageLink.url)
    }

    /// Opens a tidings:// link: shows the conversation where the message lives.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let id = MessageLink.messageID(from: url) else { return false }
        guard let message = try? store.message(messageID: id), let threadID = message.threadID else {
            show(Toast(message: String(localized: "That message isn't on this device (yet)."), symbol: "envelope.badge"))
            return false
        }
        let place: SidebarItem = message.mailbox == "INBOX" ? .inbox
            : AccountSync.isSnoozedMailbox(message.mailbox) ? .snoozed
            : .mailbox(accountID: message.accountID, path: message.mailbox)
        if selection != place { selection = place }
        endSearch()
        selectedThreadID = threadID
        return true
    }

    func copyLink(thread: ThreadSummary? = nil) {
        guard let message = thread.map({ messages(inThread: $0.threadID).last ?? $0.latest }) ?? currentMessage,
              let url = link(for: message) else { return }
        Platform.copy(url.absoluteString)
        show(Toast(message: String(localized: "Link to the message copied"), symbol: "link"))
    }

    // MARK: Tasks

    enum ReminderDue: CaseIterable {
        case none, today, tomorrow, nextWeek

        var title: String {
            switch self {
            case .none: String(localized: "No Date")
            case .today: String(localized: "This Afternoon")
            case .tomorrow: String(localized: "Tomorrow Morning")
            case .nextWeek: String(localized: "Next Week")
            }
        }

        var date: Date? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .none: return nil
            case .today:
                let five = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now)!
                return five > now ? five : now.addingTimeInterval(3_600)
            case .tomorrow:
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now)!)
            case .nextWeek:
                let monday = calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: monday)
            }
        }
    }

    /// A reminder titled with the subject, linking back to the message.
    func addToReminders(thread: ThreadSummary? = nil, due: ReminderDue = .none) {
        guard let message = thread.map({ messages(inThread: $0.threadID).last ?? $0.latest }) ?? currentMessage else { return }
        let url = link(for: message)
        Task {
            do {
                try await CalendarBridge.shared.addReminder(
                    title: message.subject, notes: String(localized: "From \(message.senderDisplay)"), url: url, due: due.date)
                show(Toast(message: due == .none ? String(localized: "Added to Reminders")
                                                 : String(localized: "Added to Reminders for \(due.title.lowercased())"),
                           symbol: "checklist"))
            } catch CalendarBridge.Failure.noAccess {
                show(Toast(message: Platform.remindersSettingsHint, symbol: "checklist"))
            } catch {
                lastError = String(localized: "Couldn't add the reminder: \(error.localizedDescription)")
            }
        }
    }

    static let thingsAdd = URL(string: "things:///add")!

    /// Asked at most once a minute: context menus build this for every row.
    var canAddToThings: Bool {
        if let check = thingsCheck, Date().timeIntervalSince(check.at) < 60 { return check.installed }
        let installed = Platform.canOpen(URL(string: "things:///")!)
        thingsCheck = (Date(), installed)
        return installed
    }

    /// Things' URL scheme: title, the sender and the link back in the notes.
    func addToThings(thread: ThreadSummary? = nil) {
        guard let message = thread.map({ messages(inThread: $0.threadID).last ?? $0.latest }) ?? currentMessage,
              var components = URLComponents(url: Self.thingsAdd, resolvingAgainstBaseURL: false) else { return }
        let notes = [String(localized: "From \(message.senderDisplay)"), link(for: message)?.absoluteString]
            .compactMap { $0 }.joined(separator: "\n")
        components.queryItems = [URLQueryItem(name: "title", value: message.subject), URLQueryItem(name: "notes", value: notes)]
        if let url = components.url { Platform.openExternally(url) }
    }
}
