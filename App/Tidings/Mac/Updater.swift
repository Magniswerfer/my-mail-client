#if os(macOS)
import Sparkle

/// Sparkle (SPEC §17): checks the appcast on the latest GitHub release and installs signed,
/// notarized updates. Only release builds of the real app update themselves; debug builds and
/// the dev copy (hk.gnus.tidings.dev) never check, so they're never replaced by a release.
@MainActor final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    private static let releaseBundleID = "hk.gnus.tidings"

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = Bundle.main.bundleIdentifier == Self.releaseBundleID
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        #endif
    }

    /// False in debug builds and the dev copy.
    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
#endif
