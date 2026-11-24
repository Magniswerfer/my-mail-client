import Foundation
import GRDB

/// The Inbox-style actions (SPEC §4).
public enum TriageKind: Sendable, Hashable, Codable {
    case done
    case trash
    case junk
    case moveToInbox
    case snooze(until: Date?)   // nil = "someday"
    case unsnooze
    case pin
    case unpin
    case markRead
    case markUnread
}

/// One applied triage action: enough to show "Done · Undo" and to reverse it.
public struct TriageChange: Sendable, Identifiable, Hashable {
    public let id: String
    public let accountID: String
    public let kind: TriageKind
    public let threadCount: Int
    let snapshots: [MessageSnapshot]
    let addedFlags: [String]
    let removedFlags: [String]
}

extension AccountSync {
    public static let snoozedMailbox = "Snoozed"
    static let maxAttempts = 3

    func path(for role: MailboxRole) throws -> String? {
        try store.mailboxStates(accountID: account.id).first { $0.role == role }?.path
    }

    // MARK: Performing

    /// Applies an action locally right away and queues it for the server. Returns nil when
    /// nothing matched (e.g. Done on a thread that has already left the Inbox).
    @discardableResult
    public func perform(_ kind: TriageKind, threadIDs: [String], from mailbox: String = "INBOX") throws -> TriageChange? {
        let changeID = UUID().uuidString
        var localIDs: [Int64]
        var add: [String] = []
        var remove: [String] = []

        switch kind {
        case .done, .trash, .junk, .moveToInbox, .snooze, .unsnooze:
            let source: String = kind == .unsnooze ? Self.snoozedMailbox : mailbox
            localIDs = try store.localIDs(threadIDs: threadIDs, mailbox: source, accountID: account.id)
            guard !localIDs.isEmpty else { return nil }
            let snapshots = try store.snapshots(localIDs: localIDs)
            var target: String
            var createTarget = false
            var surfaced: Date?? = nil
            var snooze: (Bool, Date?)? = nil
            switch kind {
            case .done:
                if let archive = try path(for: .archive) { target = archive } else { target = "Archive"; createTarget = true }
            case .trash:
                target = try path(for: .trash) ?? "Deleted Messages"
            case .junk:
                target = try path(for: .junk) ?? "Junk"
            case .moveToInbox:
                target = "INBOX"
                remove = Array(Set(snapshots.flatMap { SnoozeKeywords.all(in: $0.flags.split(separator: " ").map(String.init)) }))
                snooze = (false, nil)
            case .snooze(let until):
                target = Self.snoozedMailbox
                createTarget = true
                add = SnoozeKeywords.keywords(until: until)
                snooze = (true, until)
            case .unsnooze:
                target = "INBOX"
                remove = Array(Set(snapshots.flatMap { SnoozeKeywords.all(in: $0.flags.split(separator: " ").map(String.init)) }))
                surfaced = .some(Date())   // back on top of the stream, like new mail
                snooze = (false, nil)
            default:
                fatalError("unreachable")
            }
            let items = snapshots.map { QueuedAction.MoveItem(localID: $0.localID, fromMailbox: $0.mailbox, fromUID: $0.uid) }
            try store.db.write { db in
                try store.applyLocalMove(localIDs: localIDs, to: target, flagsAdd: add, flagsRemove: remove,
                                         surfacedAt: surfaced, snooze: snooze, in: db)
                try store.enqueue(.move(items: items, to: target, addFlags: add, removeFlags: remove, createTarget: createTarget),
                                  accountID: account.id, changeID: changeID, in: db)
            }
            signalWork()
            return TriageChange(id: changeID, accountID: account.id, kind: kind, threadCount: threadIDs.count,
                                snapshots: snapshots, addedFlags: add, removedFlags: remove)

        case .pin, .unpin, .markRead, .markUnread:
            let all = try store.localIDs(threadIDs: threadIDs, mailbox: nil, accountID: account.id)
            let snapshotsAll = try store.snapshots(localIDs: all)
            switch kind {
            case .pin:
                // Pin = \Flagged on the newest message, so Apple Mail shows it flagged too.
                localIDs = try threadIDs.compactMap { thread in
                    try store.messages(inThread: thread).filter { $0.accountID == account.id }.last?.id
                }
                add = ["\\Flagged"]
            case .unpin:
                localIDs = snapshotsAll.filter { $0.flags.contains("\\Flagged") }.map(\.localID)
                remove = ["\\Flagged"]
            case .markRead:
                localIDs = snapshotsAll.filter { !$0.flags.contains("\\Seen") }.map(\.localID)
                add = ["\\Seen"]
            default: // markUnread: only the newest message, like Apple Mail
                localIDs = try threadIDs.compactMap { thread in
                    try store.messages(inThread: thread).filter { $0.accountID == account.id }.last?.id
                }
                remove = ["\\Seen"]
            }
            guard !localIDs.isEmpty else { return nil }
            let snapshots = snapshotsAll.filter { localIDs.contains($0.localID) }
            try store.db.write { db in
                try store.applyLocalFlags(localIDs: localIDs, add: add, remove: remove, in: db)
                try store.enqueue(.flags(localIDs: localIDs, add: add, remove: remove),
                                  accountID: account.id, changeID: changeID, in: db)
            }
            signalWork()
            return TriageChange(id: changeID, accountID: account.id, kind: kind, threadCount: threadIDs.count,
                                snapshots: snapshots, addedFlags: add, removedFlags: remove)
        }
    }

    // MARK: Undo

    /// Reverses a change. If it hasn't reached the server yet it is simply cancelled;
    /// otherwise the inverse action is queued.
    public func undo(_ change: TriageChange) throws {
        try store.db.write { db in
            let pending = try PendingAction.filter(Column("changeID") == change.id).fetchAll(db)
            if !pending.isEmpty {
                for p in pending { _ = try p.delete(db) }
                for snapshot in change.snapshots { try store.restore(snapshot, in: db) }
                return
            }
            let undoID = UUID().uuidString
            let current = try store.snapshotsIn(db, localIDs: change.snapshots.map(\.localID))
            switch change.kind {
            case .pin, .unpin, .markRead, .markUnread:
                let ids = current.map(\.localID)
                try store.applyLocalFlags(localIDs: ids, add: change.removedFlags, remove: change.addedFlags, in: db)
                try store.enqueue(.flags(localIDs: ids, add: change.removedFlags, remove: change.addedFlags),
                                  accountID: account.id, changeID: undoID, in: db)
            default:
                // Move each message back to where it was, reversing the flag edits on the way.
                let byOrigin = Dictionary(grouping: change.snapshots, by: \.mailbox)
                for (origin, originals) in byOrigin {
                    let ids = originals.map(\.localID)
                    let items = current.filter { ids.contains($0.localID) && $0.uid < provisionalUIDBase }
                        .map { QueuedAction.MoveItem(localID: $0.localID, fromMailbox: $0.mailbox, fromUID: $0.uid) }
                    guard !items.isEmpty else { continue }
                    try store.applyLocalMove(localIDs: items.map(\.localID), to: origin,
                                             flagsAdd: change.removedFlags, flagsRemove: change.addedFlags, in: db)
                    for snapshot in originals {
                        try db.execute(sql: "UPDATE message SET surfacedAt = ?, snoozedUntil = ?, isSnoozed = ? WHERE id = ?",
                                       arguments: [snapshot.surfacedAt, snapshot.snoozedUntil,
                                                   snapshot.flags.contains(SnoozeKeywords.marker), snapshot.localID])
                    }
                    try store.enqueue(.move(items: items, to: origin, addFlags: change.removedFlags,
                                            removeFlags: change.addedFlags, createTarget: false),
                                      accountID: account.id, changeID: undoID, in: db)
                }
            }
        }
        signalWork()
    }

    // MARK: Snoozes

    /// Moves every snooze whose time has come back to the Inbox.
    func wakeDueSnoozes() throws {
        let due = try store.dueSnoozes(accountID: account.id)
        guard !due.isEmpty else { return }
        let threads = try store.db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT threadID FROM message WHERE id IN (\(due.map { _ in "?" }.joined(separator: ",")))",
                                arguments: StatementArguments(due))
        }
        try perform(.unsnooze, threadIDs: threads)
    }

    // MARK: Draining the queue

    /// Applies queued actions in order. Stops at the first connection-level failure so later
    /// actions never overtake earlier ones; command failures are retried, then dropped.
    func drain(_ session: MailSession) async throws {
        hasPendingWork = false
        for var pending in try store.pendingActions(accountID: account.id) {
            guard let id = pending.id else { continue }
            guard let action = pending.action else {
                try store.deletePending(id: id)
                continue
            }
            do {
                try await execute(action, session)
                try store.deletePending(id: id)
            } catch let error as MailSessionError {
                pending.attempts += 1
                pending.lastError = error.description
                if pending.attempts >= Self.maxAttempts {
                    // Give up: forget local placeholders; the next sync restores server truth.
                    try abandon(action)
                    try store.deletePending(id: id)
                    emit(.failed("Couldn't apply a change on the server: \(error.description)"))
                } else {
                    try store.savePending(pending)
                    throw error
                }
            }
        }
    }

    func execute(_ action: QueuedAction, _ session: MailSession) async throws {
        switch action {
        case .move(let items, let target, let add, let remove, let createTarget):
            if createTarget { try await session.ensureMailbox(target) }
            for (mailbox, group) in Dictionary(grouping: items, by: \.fromMailbox) {
                _ = try await session.select(mailbox)
                let uids = group.map(\.fromUID).filter { $0 < provisionalUIDBase }
                if !add.isEmpty { try await session.store(uids: uids, .add, flags: add) }
                if !remove.isEmpty { try await session.store(uids: uids, .remove, flags: remove) }
                let mapping = try await session.move(uids: uids, to: target)
                try store.applyMoveResult(accountID: account.id, target: target, items: group, mapping: mapping)
            }
        case .flags(let localIDs, let add, let remove):
            let byMailbox = Dictionary(grouping: try store.locations(localIDs: localIDs), by: \.mailbox)
            for (mailbox, group) in byMailbox {
                let uids = group.map(\.uid).filter { $0 < provisionalUIDBase }
                guard !uids.isEmpty else { continue }
                _ = try await session.select(mailbox)
                if !add.isEmpty { try await session.store(uids: uids, .add, flags: add) }
                if !remove.isEmpty { try await session.store(uids: uids, .remove, flags: remove) }
            }
        }
    }

    func abandon(_ action: QueuedAction) throws {
        if case .move(let items, _, _, _, _) = action {
            try store.delete(ids: items.map(\.localID))
        }
    }

    /// Applies queued actions on a fresh connection (when the sync loop isn't running, e.g. tests).
    public func processPendingActions() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.drain(session)
        }
    }
}

extension MailStore {
    func deletePending(id: Int64) throws {
        _ = try db.write { try PendingAction.deleteOne($0, key: id) }
    }

    func savePending(_ pending: PendingAction) throws {
        try db.write { try pending.update($0) }
    }

    func locations(localIDs: [Int64]) throws -> [(mailbox: String, uid: UInt32)] {
        guard !localIDs.isEmpty else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: "SELECT mailbox, uid FROM message WHERE id IN (\(localIDs.map { _ in "?" }.joined(separator: ",")))",
                             arguments: StatementArguments(localIDs)).map { ($0["mailbox"], $0["uid"]) }
        }
    }

    /// Replaces provisional UIDs with the server's (from COPYUID). Without a mapping, or if sync
    /// already stored the destination copy, the placeholder row is dropped and sync refetches it.
    func applyMoveResult(accountID: String, target: String, items: [QueuedAction.MoveItem], mapping: [UInt32: UInt32]) throws {
        try db.write { db in
            for item in items {
                if let newUID = mapping[item.fromUID],
                   try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountID = ? AND mailbox = ? AND uid = ?",
                                      arguments: [accountID, target, newUID]) == nil {
                    try db.execute(sql: "UPDATE message SET uid = ? WHERE id = ?", arguments: [newUID, item.localID])
                } else {
                    try deleteRowsIn(db, ids: [item.localID])
                }
            }
        }
    }

    func snapshotsIn(_ db: Database, localIDs: [Int64]) throws -> [MessageSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT id, mailbox, uid, flags, surfacedAt, snoozedUntil FROM message
            WHERE id IN (\(localIDs.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(localIDs)).map {
            MessageSnapshot(localID: $0["id"], mailbox: $0["mailbox"], uid: $0["uid"], flags: $0["flags"],
                            surfacedAt: $0["surfacedAt"], snoozedUntil: $0["snoozedUntil"])
        }
    }

    func deleteRowsIn(_ db: Database, ids: [Int64]) throws {
        for id in ids {
            if let key = try Int64.fetchOne(db, sql: "SELECT sortKey FROM message WHERE id = ?", arguments: [id]) {
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [key])
            }
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
        }
    }
}
