import AppIntents
import Foundation
import MailEngine

/// Shortcuts actions: get the open message (subject, sender, link) and open a message by link.
/// Combine them in Shortcuts with Reminders, Things, Notes, OmniFocus, …

struct NoOpenMessage: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "No conversation is open in Tidings." }
}

struct GetOpenMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Open Message"
    static let description = IntentDescription("The newest message of the conversation open in Tidings, as a link back to it.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        guard let model = AppModel.shared, let message = model.currentMessage, let url = model.link(for: message) else {
            throw NoOpenMessage()
        }
        return .result(value: url, dialog: "\(message.subject) — \(message.senderDisplay)")
    }
}

struct OpenMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Message"
    static let description = IntentDescription("Opens a message in Tidings from a tidings:// link.")
    static let openAppWhenRun = true

    @Parameter(title: "Link")
    var link: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.open(url: link)
        return .result()
    }
}

struct AddOpenMessageToRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Open Message to Reminders"
    static let description = IntentDescription("Creates a reminder for the open conversation, linking back to it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared, model.currentMessage != nil else { throw NoOpenMessage() }
        model.addToReminders()
        return .result()
    }
}

struct TidingsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetOpenMessageIntent(),
                    phrases: ["Get the open message in \(.applicationName)"],
                    shortTitle: "Open Message Link", systemImageName: "link")
        AppShortcut(intent: AddOpenMessageToRemindersIntent(),
                    phrases: ["Remind me about this email in \(.applicationName)"],
                    shortTitle: "Add to Reminders", systemImageName: "checklist")
    }
}
