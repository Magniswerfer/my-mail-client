import Foundation
import MailEngine
#if os(iOS)
import UIKit
#endif

/// The push server (ADR 0007): pairing, this device's push token, and keeping the server's
/// copy of your accounts, state and send-later mail current. The server is optional: without
/// it everything works as before (BGAppRefresh and local reminders on the iPhone).
extension AppModel {
    /// Shared by your devices through iCloud Keychain: `url \n secret`.
    static let pushServerKeychainKey = "push.server"
    /// This device's own token from pairing (never synced).
    static let pushDeviceTokenKey = "push.deviceToken"
    static let pushDeviceIDKey = "pushServer.deviceID"

    struct PushServerPairing: Equatable {
        var url: URL
        var secret: String
    }

    /// The server your devices pair with, if one is set up.
    var pushServerPairing: PushServerPairing? {
        guard let stored = Keychain.secret(account: Self.pushServerKeychainKey) else { return nil }
        let parts = stored.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: parts[0]) else { return nil }
        return PushServerPairing(url: url, secret: parts[1])
    }

    /// The API client, once this device is paired.
    var pushServer: PushServerClient? {
        guard !ProcessInfo.processInfo.arguments.contains("-TidingsNoPushServer"),
              let pairing = pushServerPairing,
              let token = Keychain.secret(account: Self.pushDeviceTokenKey) else { return nil }
        return PushServerClient(baseURL: pairing.url, token: token)
    }

    var isPushServerPaired: Bool { pushServer != nil }

    // MARK: Pairing

    /// Pairs this device with a server, then hands it everything it needs except the
    /// accounts' passwords (Settings › Notifications › Push Server asks for those).
    func pairPushServer(url: URL, secret: String) async throws {
        let response = try await PushServerClient(baseURL: url).pair(secret: secret, deviceName: Self.deviceName)
        Keychain.setSharedSecret("\(url.absoluteString)\n\(secret)", account: Self.pushServerKeychainKey)
        Keychain.setDeviceSecret(response.token, account: Self.pushDeviceTokenKey)
        UserDefaults.standard.set(response.deviceID, forKey: Self.pushDeviceIDKey)
        registerForPush()
        await uploadAccountsToPushServer()
        await uploadPushState()
        await refreshPushServerStatus()
    }

    /// `everywhere`: also forget the server on your other devices (they unpair on next launch).
    func unpairPushServer(everywhere: Bool) async {
        // Mail sent later goes back to being this device's job (what the server can still let go of).
        for item in (try? store.outbox()) ?? [] where item.state == .remote {
            guard let id = item.id, await takeBackFromPushServer(id), var local = try? store.outboxItem(id: id) else { continue }
            local.state = .queued
            _ = try? store.save(local)
        }
        try? await pushServer?.unpair()
        Keychain.setDeviceSecret(nil, account: Self.pushDeviceTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.pushDeviceIDKey)
        if everywhere { Keychain.setSharedSecret(nil, account: Self.pushServerKeychainKey) }
        pushServerStatus = nil
        reloadOutbox()
    }

    /// A device whose other half paired already (the secret came through iCloud Keychain)
    /// pairs itself at launch.
    func pairWithSharedPushServerIfNeeded() {
        guard !isPushServerPaired, let pairing = pushServerPairing,
              !ProcessInfo.processInfo.arguments.contains("-TidingsNoPushServer") else { return }
        Task { try? await pairPushServer(url: pairing.url, secret: pairing.secret) }
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    // MARK: Push token

    /// Asks iOS for this device's push token (the app delegate hands it to `pushTokenReceived`).
    /// Macs don't get pushes from the server; their own helper notifies.
    func registerForPush() {
        #if os(iOS)
        guard isPushServerPaired else { return }
        Task {
            guard await notifier.authorize() else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    func pushTokenReceived(_ token: Data) {
        guard let server = pushServer else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let environment = Self.pushEnvironment
        Task {
            do { try await server.updateDevice(PushAPI.DeviceUpdate(apnsToken: hex, environment: environment)) }
            catch { pushServerError = Self.describe(error) }
        }
    }

    // MARK: Keeping the server current

    /// The server's own app-specific password for one account, sent to the server only.
    func setPushServerPassword(_ password: String, for account: AccountConfig) async throws {
        guard let server = pushServer else { return }
        try await server.putAccount(login: account.login.lowercased(),
                                    PushAPI.AccountUpload(record: CloudAccountRecord(account), password: password))
        await refreshPushServerStatus()
    }

    /// Account settings (not passwords) for accounts the server already has.
    func uploadAccountsToPushServer() async {
        guard let server = pushServer else { return }
        let known = Set((try? await server.status())?.accounts.filter(\.hasPassword).map(\.login) ?? [])
        for account in accounts where account.id != "dev" && known.contains(account.login.lowercased()) {
            do {
                try await server.putAccount(login: account.login.lowercased(),
                                            PushAPI.AccountUpload(record: CloudAccountRecord(account), password: nil))
            } catch PushServerClient.ClientError.http(409, _) {
                // The server keeps its stored password only for the servers it was given for.
                pushServerError = String(localized: "\(account.login)'s server settings changed. Enter its app-specific password for the push server again.")
            } catch {
                pushServerError = Self.describe(error)
            }
        }
    }

    func removeAccountFromPushServer(login: String) {
        guard let server = pushServer else { return }
        Task { try? await server.deleteAccount(login: login.lowercased()) }
    }

    /// A moment after state settles (a rule, a mute, a snooze, the notification policy),
    /// the server gets the whole of it again. It's small, and whole is simple and self-healing.
    func schedulePushStateUpload() {
        guard isPushServerPaired else { return }
        pushUploadTask?.cancel()
        pushUploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.uploadPushState()
        }
    }

    func uploadPushState() async {
        guard let server = pushServer,
              let records = try? store.stateSnapshot(accounts: cloudAccounts, settings: cloudSettings) else { return }
        do {
            try await server.putState(PushAPI.StateUpload(records: records))
            pushServerError = nil
        } catch {
            pushServerError = Self.describe(error)
        }
    }

    func refreshPushServerStatus() async {
        guard let server = pushServer else { pushServerStatus = nil; return }
        do {
            pushServerStatus = try await server.status()
            pushServerError = nil
        } catch {
            pushServerError = Self.describe(error)
        }
    }

    /// On launch and on return: state, accounts and the send-later list.
    func syncWithPushServer() {
        guard isPushServerPaired else { pairWithSharedPushServerIfNeeded(); return }
        registerForPush()
        Task {
            await refreshPushServerStatus()
            await uploadAccountsToPushServer()
            await uploadPushState()
            await reconcileHandedOffSends()
        }
    }

    // MARK: Send later

    /// Mail scheduled at least this far out is handed to the server.
    static let handOffMargin: TimeInterval = 5 * 60

    func scheduledSendID(_ outboxID: Int64) -> String {
        "\(UserDefaults.standard.string(forKey: Self.pushDeviceIDKey) ?? "device")-\(outboxID)"
    }

    /// Hands a send-later message to the server, so it goes out with no device awake. Until
    /// the server confirms, it stays this device's job.
    func handOffToPushServer(_ item: OutboxItem) {
        guard let server = pushServer, let id = item.id, let sendAt = item.sendAt, let message = item.message,
              sendAt.timeIntervalSinceNow > Self.handOffMargin,
              let account = accounts.first(where: { $0.id == item.accountID }),
              pushServerStatus?.accounts.contains(where: { $0.login == account.login.lowercased() && $0.hasPassword }) == true,
              let sync = syncs[item.accountID] else { return }
        let send = PushAPI.ScheduledSend(account: account.login.lowercased(), sendAt: sendAt, kind: item.kind, message: message)
        Task {
            do {
                try await server.schedule(id: scheduledSendID(id), send)
                try await sync.markHandedOff(id: id)
                reloadOutbox()
            } catch {
                pushServerError = Self.describe(error)
            }
        }
    }

    /// Takes a handed-off message back from the server (to edit or cancel it). False when it's
    /// too late: the server is sending it or has sent it.
    func takeBackFromPushServer(_ outboxID: Int64) async -> Bool {
        guard let server = pushServer else { return true }
        do {
            try await server.cancelScheduled(id: scheduledSendID(outboxID))
            return true
        } catch PushServerClient.ClientError.http(404, _) {
            return true
        } catch {
            return false
        }
    }

    /// Handed-off mail the server no longer holds has gone out: drop it here.
    func reconcileHandedOffSends() async {
        guard let server = pushServer, let waiting = try? await server.scheduledIDs() else { return }
        let pending = Set(waiting)
        var changed = false
        for item in (try? store.outbox()) ?? [] where item.state == .remote {
            guard let id = item.id, !pending.contains(scheduledSendID(id)) else { continue }
            try? store.deleteOutboxItem(id: id)
            changed = true
        }
        if changed { reloadOutbox() }
    }

    // MARK: Pushed notifications

    /// A tapped or answered push names its message by Message-ID and account login (local ids
    /// differ per device): the conversation here, if the mail has arrived.
    func localConversation(messageID: String, login: String) -> (threadID: String, accountID: String)? {
        guard let account = accounts.first(where: { $0.login.lowercased() == login.lowercased() }),
              let message = try? store.message(messageID: messageID),
              let threadID = message.threadID else { return nil }
        return (threadID, account.id)
    }

    /// On the iPhone the server notifies about new mail once paired; posting our own as well
    /// would show everything twice.
    var serverNotifiesNewMail: Bool {
        #if os(iOS)
        isPushServerPaired && pushServerStatus?.pushConfigured != false
        #else
        false
        #endif
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case PushServerClient.ClientError.http(401, _): String(localized: "The push server doesn't know this device. Pair again.")
        case PushServerClient.ClientError.http(let status, let body): "HTTP \(status): \(body)"
        default: error.localizedDescription
        }
    }
}

extension AppModel {
    /// Which APNs endpoint this build's push tokens belong to: what its provisioning profile
    /// says (`aps-environment`), not Debug vs Release. A Release build installed from Xcode is
    /// still development-signed and gets sandbox tokens; App Store and TestFlight builds carry no
    /// development profile and get production ones.
    static let pushEnvironment: PushAPI.PushEnvironment = {
        #if os(macOS)
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        #endif
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1) else { return .production }
        // The profile is a signed plist; its entitlements sit in it as plain XML.
        for key in ["<key>aps-environment</key>", "<key>com.apple.developer.aps-environment</key>"] {
            guard let found = text.range(of: key),
                  let open = text.range(of: "<string>", range: found.upperBound..<text.endIndex),
                  let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { continue }
            return text[open.upperBound..<close.lowerBound] == "development" ? .sandbox : .production
        }
        return .production
    }()
}
