import Foundation
import MailEngine
import UserNotifications

/// Local notifications (SPEC §10): new mail worth interrupting for, and — on iPhone, where the
/// app can't wake itself at an exact time — reminders when a snooze ends or a scheduled message
/// is due. Push from the server replaces the latter later.
@MainActor final class Notifier {
    static let shared = Notifier()

    /// Identifiers of reminders this app schedules for itself (replaced on every reschedule).
    private static let schedulePrefix = "tidings.schedule."
    static let messageCategory = "tidings.message"

    private var authorized: Bool?

    /// Asks once, the first time something would be shown.
    func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            authorized = false
        }
        return authorized ?? false
    }

    /// New mail: sender as title, subject and preview as body; tapping opens it (tidings:// link).
    func notify(message: StoredMessage, reason: String? = nil) async {
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = message.senderDisplay
        content.subtitle = message.subject
        content.body = reason.map { "\($0) · \(message.preview)" } ?? message.preview
        content.sound = .default
        content.threadIdentifier = message.threadID ?? ""
        content.categoryIdentifier = Self.messageCategory
        if let link = message.messageID.flatMap(MessageLink.url) { content.userInfo = ["link": link.absoluteString] }
        let request = UNNotificationRequest(identifier: "tidings.mail.\(message.id ?? 0)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// iPhone: one notification per upcoming snooze wake and send-later time, so they happen on
    /// time even while iOS keeps the app suspended. Opening the app does the actual work.
    func scheduleWakeReminders(snoozes: [StoredMessage], scheduledSends: [OutboxItem]) async {
        let center = UNUserNotificationCenter.current()
        await cancelWakeReminders()
        guard !snoozes.isEmpty || !scheduledSends.isEmpty, await ensureAuthorized() else { return }
        for message in snoozes {
            guard let wake = message.snoozedUntil else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Back in your Inbox")
            content.body = "\(message.senderDisplay): \(message.subject)"
            content.sound = .default
            if let link = message.messageID.flatMap(MessageLink.url) { content.userInfo = ["link": link.absoluteString] }
            try? await center.add(UNNotificationRequest(identifier: "\(Self.schedulePrefix)snooze.\(message.id ?? 0)", content: content,
                                                        trigger: Self.trigger(at: wake)))
        }
        for item in scheduledSends {
            guard let sendAt = item.sendAt, let message = item.message else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Ready to send")
            content.body = String(localized: "Open Tidings to send “\(message.subject)”.")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "\(Self.schedulePrefix)send.\(item.id ?? 0)", content: content,
                                                        trigger: Self.trigger(at: sendAt)))
        }
    }

    func cancelWakeReminders() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.schedulePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
    }
}

/// Routes taps on notifications to the message (both platforms).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { _ = AppModel.shared?.open(url: url) }
    }

    /// Show banners while the app is open too (but not for the conversation you're reading).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let thread = notification.request.content.threadIdentifier
        let reading = await MainActor.run { AppModel.shared?.readerThreadID }
        return thread.isEmpty || thread != reading ? [.banner, .sound, .list] : []
    }
}
