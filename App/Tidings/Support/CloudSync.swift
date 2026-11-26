import CloudKit
import CryptoKit
import Foundation
import MailEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Moves app state between this device and your private CloudKit database (ADR 0006).
/// The engine decides what changed and how to apply what arrives; this only carries
/// records, with CKSyncEngine doing batching, change tokens, pushes and retries.
final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    static let zoneID = CKRecordZone.ID(zoneName: "TidingsState", ownerName: CKCurrentUserDefaultName)
    static let recordType = "State"

    let store: MailStore
    let container: CKContainer
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    /// Called on the main actor with what arrived (the app reloads and writes settings).
    private let onApplied: @MainActor (CloudApplyReport) -> Void
    private let onStatus: @MainActor (CloudStatus) -> Void
    /// The latest accounts and settings, for applying records and collecting changes.
    private var accounts = CloudAccounts([])

    enum CloudStatus: Equatable { case starting, upToDate(Date), syncing, unavailable(String), off }

    /// The container named in Info.plist (`TidingsCloudContainer`), or nil when this build
    /// can't use it (unsigned CI builds, or a signature without the iCloud entitlement, where
    /// touching CloudKit would crash).
    static var containerIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "TidingsCloudContainer") as? String,
              id.hasPrefix("iCloud."), !id.contains("$(") else { return nil }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(id) else { return nil }
        #endif
        return id
    }

    init(store: MailStore, containerIdentifier: String,
         onApplied: @escaping @MainActor (CloudApplyReport) -> Void,
         onStatus: @escaping @MainActor (CloudStatus) -> Void) {
        self.store = store
        self.container = CKContainer(identifier: containerIdentifier)
        self.onApplied = onApplied
        self.onStatus = onStatus
    }

    // MARK: Life cycle

    @MainActor
    func start(accounts: CloudAccounts) async {
        setAccounts(accounts)
        onStatus(.starting)
        do {
            guard try await container.accountStatus() == .available else {
                onStatus(.unavailable(String(localized: "Sign in to iCloud to sync")))
                return
            }
        } catch {
            onStatus(.unavailable(String(describing: error)))
            return
        }
        let saved = (try? store.cloudMeta("engineState")).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        let engine = CKSyncEngine(configuration)
        lock.withLock { self.engine = engine }
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        try? await engine.fetchChanges()
    }

    func stop() {
        lock.withLock { engine = nil }
    }

    func setAccounts(_ accounts: CloudAccounts) {
        lock.withLock { self.accounts = accounts }
    }

    private var currentAccounts: CloudAccounts { lock.withLock { accounts } }
    private var currentEngine: CKSyncEngine? { lock.withLock { engine } }

    // MARK: Sending

    /// Finds local changes and hands them to CKSyncEngine, which sends them shortly.
    func push(settings: [String: Data]) {
        guard let engine = currentEngine else { return }
        do {
            try store.collectCloudChanges(accounts: currentAccounts, settings: settings)
            let changes = try store.pendingCloudChanges()
            guard !changes.isEmpty else { return }
            var pending: [CKSyncEngine.PendingRecordZoneChange] = []
            for change in changes {
                let id = Self.recordID(type: change.type, key: change.key)
                try rememberName(id.recordName, type: change.type, key: change.key)
                switch change {
                case .save: pending.append(.saveRecord(id))
                case .delete: pending.append(.deleteRecord(id))
                }
            }
            engine.state.add(pendingRecordZoneChanges: pending)
        } catch {
            SyncLog.cloud("collect failed: \(error)")
        }
    }

    /// Fetches now (after a mail sync or when the app comes forward), in case a push was missed.
    func fetch() async {
        try? await currentEngine?.fetchChanges()
    }

    // MARK: CKSyncEngineDelegate

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            self.record(for: recordID)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) { try? store.setCloudMeta("engineState", data) }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                await MainActor.run { onStatus(.syncing) }
            case .signOut, .switchAccounts:
                // Another person's (or no) iCloud: forget what we knew about the cloud.
                try? store.resetCloudState()
                await MainActor.run { onStatus(.unavailable(String(localized: "Sign in to iCloud to sync"))) }
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                // The synced data was deleted (Settings › iCloud): start over from this device.
                try? store.resetCloudState()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            }

        case .fetchedRecordZoneChanges(let changes):
            var saves: [StateRecord] = []
            for modification in changes.modifications {
                let record = modification.record
                guard let state = Self.state(from: record) else { continue }
                try? rememberName(record.recordID.recordName, type: state.type, key: state.key)
                try? rememberSystemFields(of: record)
                saves.append(state)
            }
            let deletions = changes.deletions.compactMap { deletion -> (type: String, key: String)? in
                try? forgetSystemFields(deletion.recordID.recordName)
                return try? name(deletion.recordID.recordName)
            }
            guard !saves.isEmpty || !deletions.isEmpty else { return }
            do {
                let report = try store.applyCloudChanges(saves: saves, deletions: deletions, accounts: currentAccounts)
                SyncLog.cloud("fetched \(saves.count) saves, \(deletions.count) deletions: applied \(report.applied), waiting \(report.deferred), kept local \(report.skipped)")
                await MainActor.run { onApplied(report) }
            } catch {
                SyncLog.cloud("apply failed: \(error)")
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                try? rememberSystemFields(of: record)
                if let state = Self.state(from: record) { try? store.cloudSaved(state) }
            }
            for id in sent.deletedRecordIDs {
                try? forgetSystemFields(id.recordName)
                if let (type, key) = try? name(id.recordName) { try? store.cloudDeleted(type: type, key: key) }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var newerOnServer: [StateRecord] = []
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Someone else saved it first: the newer one wins (the engine decides).
                    if let server = failure.error.serverRecord {
                        try? rememberSystemFields(of: server)
                        if let state = Self.state(from: server) { newerOnServer.append(state) }
                    }
                    retry.append(.saveRecord(id))
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    try? forgetSystemFields(id.recordName)
                    retry.append(.saveRecord(id))
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated:
                    break   // CKSyncEngine retries these itself
                default:
                    SyncLog.cloud("save failed for \(id.recordName): \(failure.error)")
                }
            }
            if !newerOnServer.isEmpty, let report = try? store.applyCloudChanges(saves: newerOnServer, deletions: [], accounts: currentAccounts) {
                await MainActor.run { onApplied(report) }
            }
            // Whatever's still ours to send goes again (nextRecordZoneChangeBatch skips the rest).
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            await MainActor.run { onStatus(.upToDate(Date())) }

        case .didFetchChanges:
            await MainActor.run { onStatus(.upToDate(Date())) }

        case .willFetchChanges, .willSendChanges:
            await MainActor.run { onStatus(.syncing) }

        default:
            break
        }
    }

    // MARK: Records

    /// Record names are a hash of type and key (keys can be long or contain any character).
    static func recordID(type: String, key: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data("\(type)/\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: digest, zoneID: zoneID)
    }

    static func state(from record: CKRecord) -> StateRecord? {
        guard let type = record["type"] as? String, let key = record["key"] as? String,
              let payload = record["payload"] as? Data, let modifiedAt = record["modifiedAt"] as? Date else { return nil }
        return StateRecord(type: type, key: key, payload: payload, modifiedAt: modifiedAt)
    }

    /// The record to send for a pending save, on top of the last known server copy (so its
    /// change tag is current), or nil when the change is no longer pending.
    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let (type, key) = try? name(id.recordName),
              case .save(let state)? = try? store.pendingCloudRecord(type: type, key: key) else { return nil }
        let record = (try? systemFields(id.recordName)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["type"] = state.type
        record["key"] = state.key
        record["payload"] = state.payload
        record["modifiedAt"] = state.modifiedAt
        return record
    }

    private func rememberName(_ name: String, type: String, key: String) throws {
        try store.setCloudMeta("name:\(name)", Data("\(type)\n\(key)".utf8))
    }

    private func name(_ name: String) throws -> (type: String, key: String)? {
        guard let data = try store.cloudMeta("name:\(name)"), let text = String(data: data, encoding: .utf8),
              let newline = text.firstIndex(of: "\n") else { return nil }
        return (String(text[..<newline]), String(text[text.index(after: newline)...]))
    }

    private func rememberSystemFields(of record: CKRecord) throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        try store.setCloudMeta("sys:\(record.recordID.recordName)", coder.encodedData)
    }

    private func systemFields(_ name: String) throws -> CKRecord? {
        guard let data = try store.cloudMeta("sys:\(name)") else { return nil }
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private func forgetSystemFields(_ name: String) throws {
        try store.setCloudMeta("sys:\(name)", nil)
    }
}
