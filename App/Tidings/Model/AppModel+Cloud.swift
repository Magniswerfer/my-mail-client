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

    /// Accounts (and their passwords, in iCloud Keychain) travel to your other devices: iCloud
    /// sync is running, not just switched on.
    var syncsAccountsThroughICloud: Bool { cloudSync != nil && Keychain.synchronizes }

    /// Accounts are known across devices by their login (an iCloud address stays what it was).
    var cloudAccounts: CloudAccounts { CloudAccounts(accounts.map { ($0.id, $0.login) }) }

    /// Preferences that sync (not per-device ones like the Focus filter or window state).
    static let syncedSettingKeys = [BundleScheduleStorage.key, NotificationPolicyStorage.key, SnippetStore.key]

    /// Accounts as they sync, by login: the ones here and the ones still waiting for a password
    /// (left out, they'd look removed). Not the dev copy's built-in local account.
    var cloudAccountRecords: [String: Data] {
        var records: [String: Data] = [:]
        for account in accountsAwaitingPassword + accounts where account.id != "dev" {
            records[account.login.lowercased()] = CloudAccountRecord(account).payload
        }
        return records
    }

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
        // Passwords go to iCloud Keychain from now on, older ones too, so another device can sign in.
        Keychain.synchronizes = true
        Keychain.moveToICloud(accounts.filter { $0.id != "dev" })
        let accounts = cloudAccounts
        Task {
            await sync.start(accounts: accounts)
            sync.push(settings: cloudSettings, accountRecords: cloudAccountRecords)
        }
    }

    /// Turned off: stop, and forget what we knew about the cloud (turning it on again offers
    /// this device's state and takes the cloud's where it has some).
    func stopCloudSync() {
        Keychain.synchronizes = false
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
            cloudSync.push(settings: self.cloudSettings, accountRecords: self.cloudAccountRecords)
        }
    }

    /// After each mail sync: state that waited for this mail lands, message state goes back
    /// onto flags a keyword-dropping server took off, and we check the cloud for news.
    func cloudAfterMailSync() {
        let accounts = cloudAccounts
        let pending = (try? store.applyPendingCloudChanges(accounts: accounts))?.applied ?? 0
        let reasserted = (try? store.reassertMessageStates(accounts: accounts)) ?? 0
        if pending + reasserted > 0 { reload() }
        adoptAccountsWithPasswords()
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
        if !report.accounts.isEmpty || !report.removedAccounts.isEmpty { applyCloudAccounts(report) }
        if report.applied > 0 { reload() }
    }

    // MARK: Accounts from other devices

    /// Added or changed on another device: changes land on the account here (same login); a new
    /// one joins once its password is in this device's Keychain (iCloud Keychain brings it),
    /// and waits in Settings › Accounts until then. Removed there: removed here too.
    func applyCloudAccounts(_ report: CloudApplyReport) {
        for login in report.removedAccounts {
            accountsAwaitingPassword.removeAll { $0.login.lowercased() == login }
            if let account = accounts.first(where: { $0.login.lowercased() == login && $0.id != "dev" }) {
                removeAccount(account, everywhere: false)
            }
        }
        for (login, payload) in report.accounts {
            guard let record = try? CloudAccountRecord(payload: payload) else { continue }
            if let index = accounts.firstIndex(where: { $0.login.lowercased() == login }) {
                let updated = record.account(id: accounts[index].id)
                guard updated != accounts[index] else { continue }
                let reconnect = updated.endpoint != accounts[index].endpoint || updated.smtp != accounts[index].smtp
                accounts[index] = updated
                if reconnect {
                    stopSync(accountID: updated.id)
                    start()
                }
            } else {
                accountsAwaitingPassword.removeAll { $0.login.lowercased() == login }
                accountsAwaitingPassword.append(record.account())
            }
        }
        persistAccounts()
        adoptAccountsWithPasswords()
    }

    /// Accounts waiting for a password join as soon as this device's Keychain has one.
    func adoptAccountsWithPasswords() {
        let ready = accountsAwaitingPassword.filter { Keychain.password(for: $0) != nil }
        guard !ready.isEmpty else { return }
        accountsAwaitingPassword.removeAll { account in ready.contains { $0.login == account.login } }
        accounts += ready.filter { account in !accounts.contains { $0.login == account.login } }
        persistAccounts()
        cloudSync?.setAccounts(cloudAccounts)
        start()
        reload()
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
