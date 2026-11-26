#if os(macOS)
import AppKit
import MailEngine
import ServiceManagement
import SwiftUI

/// Tidings in the background (SPEC §4): sync, rules, snooze wake-ups, send-later and sorting run
/// with the app, not its window, so closing the window keeps them going. This adds opening at
/// login without a window, catching up after sleep, staying out of App Nap, the unread count on
/// the Dock icon and an optional menu bar item. ⌘Q still quits.
@MainActor enum BackgroundMode {
    static let menuBarKey = "showInMenuBar"

    /// Registered to open at login (System Settings › General › Login Items).
    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Waiting for you to allow it in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Started by macOS at login (or `-TidingsLaunchHidden`, to try it): no window then.
    static func launchedAtLogin() -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-TidingsLaunchHidden") { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static func setDockBadge(_ count: Int) {
        // The first reload runs while the app is still starting, before NSApp exists.
        guard let app = NSApp as NSApplication? else { return }
        let label = count > 0 ? "\(count)" : nil
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }
}

/// App lifecycle: a login launch stays windowless, waking from sleep checks mail at once, and
/// App Nap doesn't slow the sync loops down while no window is open.
@MainActor final class TidingsAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by TidingsApp once the model exists.
    static var checkForNewMail: (() -> Void)?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Timers (snooze wake-ups, send-later) must fire on time with no window on screen.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Checking mail and waking snoozed mail")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SyncLog.info("woke from sleep: checking for new mail")
                Self.checkForNewMail?()
            }
        }
        if BackgroundMode.launchedAtLogin() {
            // The window SwiftUI opens at launch shows up a moment later: close it then.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
                NSApp.hide(nil)
            }
        }
    }

    /// Closing the last window keeps Tidings running (that's the point).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

/// The menu bar item (Settings › General › Show in Menu Bar): the unread count, and the way back
/// in when the window is closed.
struct TidingsMenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.inboxUnreadCount == 0 ? String(localized: "No unread mail")
                                         : String(localized: "\(model.inboxUnreadCount) unread in the Inbox"))
        Divider()
        Button("Open Tidings") { openMain() }
            .keyboardShortcut("o")
        Button("Check for New Mail") { model.checkForNewMail() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("New Message") {
            openMain()
            model.composeNew()
        }
        .keyboardShortcut("n")
        Divider()
        Button("Quit Tidings") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow(id: "main") }
    }
}
#endif
