import Foundation
import MailEngine

/// iCloud sync of app state (ADR 0006): what the model hands to `CloudSync` and does with
/// what comes back.
extension AppModel {
    static let cloudEnabledKey = "cloudSync.enabled"

    /// On unless turned off in Settings. Never for an agent's test run (-TidingsNoCloud).
    var isCloudSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.cloudEnabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.cloudEnabledKey)
            if newValue { startCloudSync() } else { stopCloudSync() }
        }
    }

    /// Accounts are known across devices by their login (an iCloud address stays what it was).
    var cloudAccounts: CloudAccounts { CloudAccounts(accounts.map { ($0.id, $0.login) }) }

    /// Preferences that sync (not per-device ones like the Focus filter or window state).
    static let syncedSettingKeys = [BundleScheduleStorage.key, NotificationPolicyStorage.key, SnippetStore.key]

    var cloudSettings: [String: Data] {
        var settings: [String: Data] = [:]
        for key in Self.syncedSettingKeys {
            if let data = UserDefaults.standard.data(forKey: key) { settings[key] = data }
        }
        return settings
    }

    func startCloudSync() {
        guard cloudSync == nil, isCloudSyncEnabled,
              !ProcessInfo.processInfo.arguments.contains("-TidingsNoCloud"),
              let container = CloudSync.containerIdentifier else {
            if cloudSync == nil { cloudStatus = .off }
            return
        }
        let sync = CloudSync(store: store, containerIdentifier: container,
                             onApplied: { [weak self] report in self?.cloudApplied(report) },
                             onStatus: { [weak self] status in self?.cloudStatus = status })
        cloudSync = sync
        let accounts = cloudAccounts
        Task {
            await sync.start(accounts: accounts)
            sync.push(settings: cloudSettings)
        }
    }

    /// Turned off: stop, and forget what we knew about the cloud (turning it on again offers
    /// this device's state and takes the cloud's where it has some).
    func stopCloudSync() {
        cloudSync?.stop()
        cloudSync = nil
        try? store.resetCloudState()
        cloudStatus = .off
    }

    /// A moment after local changes settle, send them.
    func scheduleCloudPush() {
        guard let cloudSync else { return }
        cloudPushTask?.cancel()
        cloudPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            cloudSync.setAccounts(self.cloudAccounts)
            cloudSync.push(settings: self.cloudSettings)
        }
    }

    /// After each mail sync: state that waited for this mail lands, message state goes back
    /// onto flags a keyword-dropping server took off, and we check the cloud for news.
    func cloudAfterMailSync() {
        let accounts = cloudAccounts
        let pending = (try? store.applyPendingCloudChanges(accounts: accounts))?.applied ?? 0
        let reasserted = (try? store.reassertMessageStates(accounts: accounts)) ?? 0
        if pending + reasserted > 0 { reload() }
        if let cloudSync { Task { await cloudSync.fetch() } }
    }

    /// What another device changed arrived.
    func cloudApplied(_ report: CloudApplyReport) {
        let types = report.changedTypes
        if types.contains(StateRecordType.rule.rawValue) { loadRules() }
        if types.contains(StateRecordType.smartFolder.rawValue) { loadSmartFolders() }
        if types.contains(StateRecordType.aiCategory.rawValue) || types.contains(StateRecordType.aiChoice.rawValue) { loadAICategories() }
        for (key, data) in report.settings where Self.syncedSettingKeys.contains(key) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if !report.settings.isEmpty {
            bundleSchedules = BundleScheduleStorage.load()
            notificationPolicy = NotificationPolicyStorage.load()
        }
        if report.applied > 0 { reload() }
    }

    var cloudStatusText: String {
        switch cloudStatus {
        case .off: String(localized: "Off")
        case .starting: String(localized: "Starting…")
        case .syncing: String(localized: "Syncing…")
        case .upToDate(let date): String(localized: "Up to date (\(date.formatted(date: .omitted, time: .shortened)))")
        case .unavailable(let reason): reason
        }
    }
}
