import Foundation
import MailEngine
import UserNotifications

/// iPhone: iOS can't wake the app at an exact time, so snooze wake-ups and send-later times
/// become local notifications (opening the app does the work). Push from the server replaces
/// this later. Taps go through `MailNotifier` like any mail notification.
@MainActor enum WakeReminders {
    static let prefix = "tidings.wake."

    static func schedule(snoozes: [StoredMessage], sends: [OutboxItem]) async {
        let center = UNUserNotificationCenter.current()
        await cancel()
        guard !snoozes.isEmpty || !sends.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for message in snoozes {
            guard let wake = message.snoozedUntil, let thread = message.threadID else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Back in your Inbox")
            content.body = "\(message.fromName ?? message.fromAddress): \(message.subject)"
            content.sound = .default
            content.threadIdentifier = thread
            var info = ["threadID": thread, "accountID": message.accountID]
            if let link = message.messageID.flatMap(MessageLink.url) { info["link"] = link.absoluteString }
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: "\(prefix)snooze.\(message.id ?? 0)", content: content,
                                                        trigger: trigger(at: wake)))
        }
        for item in sends {
            guard let at = item.sendAt, let message = item.message else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Ready to send")
            content.body = String(localized: "Open Tidings to send “\(message.subject)”.")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "\(prefix)send.\(item.id ?? 0)", content: content,
                                                        trigger: trigger(at: at)))
        }
    }

    static func cancel() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                                      repeats: false)
    }
}

extension AppModel {
    /// Scheduled sends more than a minute away (the undo window is flushed before suspending).
    var scheduledSends: [OutboxItem] {
        ((try? store.outbox()) ?? []).filter { $0.state == .queued && ($0.sendAt ?? .distantPast) > Date().addingTimeInterval(60) }
    }

    /// The next snooze wake or scheduled send.
    var nextDueDate: Date? {
        let snooze = (try? store.upcomingSnoozes(limit: 1))?.first?.snoozedUntil
        let send = scheduledSends.compactMap(\.sendAt).min()
        return [snooze, send].compactMap { $0 }.min()
    }

    func scheduleWakeReminders() async {
        await WakeReminders.schedule(snoozes: (try? store.upcomingSnoozes(limit: 30)) ?? [], sends: scheduledSends)
    }
}
