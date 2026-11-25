import Foundation
import MailEngine
import UserNotifications

/// System notifications for new mail (SPEC §10). What deserves one is decided by the engine's
/// `NotificationPolicy`; this posts them, groups them by conversation, and handles their
/// buttons (Done, Mark as Read) and taps (open the conversation).
@MainActor
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    static let category = "mail"
    static let doneAction = "done"
    static let readAction = "read"
    /// More than this in one sync pass become one summary ("6 new messages").
    static let burstLimit = 4

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.doneAction, title: String(localized: "Done"), options: []),
                UNNotificationAction(identifier: Self.readAction, title: String(localized: "Mark as Read"), options: []),
            ], intentIdentifiers: [], options: []),
        ])
    }

    /// Asks once; later calls return the answer you gave.
    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    func post(_ notifications: [MailNotification], link: (MailNotification) -> URL?) async {
        guard !notifications.isEmpty, await authorize() else { return }
        if notifications.count > Self.burstLimit {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(notifications.count) new messages")
            content.body = Array(Set(notifications.map(\.sender))).sorted().prefix(4).joined(separator: ", ")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "burst-\(UUID().uuidString)", content: content, trigger: nil))
            return
        }
        for n in notifications {
            let content = UNMutableNotificationContent()
            content.title = n.sender
            content.subtitle = n.subject
            content.body = n.preview
            content.threadIdentifier = n.threadID
            content.categoryIdentifier = Self.category
            content.sound = .default
            var info: [String: String] = ["threadID": n.threadID, "accountID": n.accountID]
            if let url = link(n) { info["link"] = url.absoluteString }
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: "mail-\(n.localID)", content: content, trigger: nil))
        }
    }

    /// Clears a conversation's notifications once you've dealt with it.
    func clear(threadID: String) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == threadID }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let threadID = info["threadID"] as? String
        let accountID = info["accountID"] as? String
        let link = (info["link"] as? String).flatMap(URL.init(string:))
        await MainActor.run {
            guard let model = self.model else { return }
            switch action {
            case Self.doneAction:
                if let threadID, let accountID { model.performQuietly(.done, threadID: threadID, accountID: accountID) }
            case Self.readAction:
                if let threadID, let accountID { model.performQuietly(.markRead, threadID: threadID, accountID: accountID) }
            default:
                Platform.activateApp()
                if let link { model.open(url: link) }
            }
        }
    }
}

/// Notification settings, kept with the app's preferences.
enum NotificationPolicyStorage {
    static let key = "notificationPolicy.v1"

    static func load() -> NotificationPolicy {
        guard let data = UserDefaults.standard.data(forKey: key),
              let policy = try? JSONDecoder().decode(NotificationPolicy.self, from: data) else { return NotificationPolicy() }
        return policy
    }

    static func save(_ policy: NotificationPolicy) {
        UserDefaults.standard.set(try? JSONEncoder().encode(policy), forKey: key)
    }
}
