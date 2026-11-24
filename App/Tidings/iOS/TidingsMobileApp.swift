#if os(iOS)
import BackgroundTasks
import MailEngine
import SwiftUI
import UIKit

/// The iPhone (and iPad) app. Same model and views as the Mac; what differs is navigation
/// (a collapsing split view), touch (swipes, long-press menus) and life cycle: iOS suspends apps
/// in the background, so connections close there and reopen on return, with a periodic
/// background refresh in between. Push for new mail comes from the server (step 3).
@main
struct TidingsMobileApp: App {
    /// One model for the process, so background refresh (which may run with no UI) shares it.
    static let model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskID = "hk.gnus.tidings.refresh"

    private var model: AppModel { Self.model }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.start()
                model.checkForNewMail()
            case .background:
                Self.scheduleRefresh()
                suspendGracefully()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await Self.scheduleRefresh()
            await Self.model.backgroundCatchUp()
        }
    }

    /// Asks for a little time so mail in its undo window goes out and queued actions reach the
    /// server before iOS suspends us.
    private func suspendGracefully() {
        let model = model
        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "Finish sending") {
            MainActor.assumeIsolated {
                model.stopSync()
                task.end()
            }
        }
        Task { @MainActor in
            await model.finishWorkBeforeSuspending()
            task.end()
        }
    }

    @MainActor final class BackgroundTaskBox {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// iOS decides when this actually runs (typically every 15–60 minutes, based on use).
    @MainActor static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
