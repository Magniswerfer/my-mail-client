import Foundation
import GRDB

/// The Inbox-style actions (SPEC §4).
public enum TriageKind: Sendable, Hashable, Codable {
    case done
    case trash
    case junk
    case moveToInbox
    case move(toMailbox: String)   // any folder ("Move to Folder…")
    case snooze(until: Date?)   // nil = "someday"
    case unsnooze
    case pin
    case unpin
    case markRead
    case markUnread
    /// "Reply Later" (HEY): a keyword on the newest message, so it survives reinstalls and other devices see it.
    case replyLater
    case clearReplyLater
    /// Read Later: a keyword on every message of the conversation (syncs via IMAP).
    case readLater
    case clearReadLater
}

/// Read Later: set aside to read in reader mode, out of the Inbox (SPEC §11).
public let readLaterKeyword = "$TidingsReadLater"

/// The IMAP keyword for Reply Later. Plain keywords are fine on iCloud (verified in M0).
public let replyLaterKeyword = "$TidingsReplyLater"

/// One applied triage action: enough to show "Done · Undo" and to reverse it.
public struct TriageChange: Sendable, Identifiable, Hashable {
    public let id: String
    public let accountID: String
    public let kind: TriageKind
    public let threadCount: Int
    let snapshots: [MessageSnapshot]
    let addedFlags: [String]
    let removedFlags: [String]
    /// The junk filter moved it (undoing it teaches "not junk").
    public internal(set) var byFilter = false
}

extension AccountSync {
    /// The snoozed folder's name. On servers whose folders all live under the personal
    /// namespace (Dovecot's `INBOX.`), it's `INBOX.Snoozed`: see `snoozedPath()`.
    public static let snoozedMailbox = "Snoozed"
    static let personalPrefixKey = "personalNamespacePrefix"

    /// The snoozed folder on any account: `Snoozed` at the top, or right under `INBOX.`/`INBOX/`.
    public static func isSnoozedMailbox(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower == "snoozed" || lower == "inbox.snoozed" || lower == "inbox/snoozed"
    }

    /// Where this account's snoozed mail goes: the folder it already has, else a new one named
    /// the way the server wants (`INBOX.Snoozed` when every folder sits under `INBOX.`).
    func snoozedPath() throws -> String {
        if let existing = try store.mailboxStates(accountID: account.id).first(where: { Self.isSnoozedMailbox($0.path) }) {
            return existing.path
        }
        let prefix = try store.setting(Self.personalPrefixKey, accountID: account.id) ?? ""
        return prefix + Self.snoozedMailbox
    }

    /// The account's personal prefix, as the server announces it (NAMESPACE), else guessed from
    /// the listing; remembered for moves and new folders.
    func personalPrefix(_ session: MailSession, listing: [MailboxListing]) async throws -> String {
        let announced = (try? await session.personalNamespacePrefix()) ?? nil
        let prefix = announced ?? Self.personalPrefix(in: listing)
        try store.setSetting(Self.personalPrefixKey, prefix, accountID: account.id)
        return prefix
    }

    /// `INBOX.` (or `INBOX/`) when every folder but the Inbox lives under it, as on Dovecot with
    /// an `INBOX.` namespace; there a new top-level folder is refused ("nonexistent namespace").
    static func personalPrefix(in listing: [MailboxListing]) -> String {
        let others = listing.filter { $0.path.uppercased() != "INBOX" }
        guard let separator = listing.first(where: { $0.path.uppercased() == "INBOX" })?.separator ?? others.first?.separator,
              !others.isEmpty else { return "" }
        let prefix = "INBOX\(separator)"
        return others.allSatisfy { $0.path.uppercased().hasPrefix(prefix.uppercased()) } ? prefix : ""
    }
    static let maxAttempts = 3

    /// The setting that remembers a special folder Tidings doesn't sync (Trash).
    static func roleKey(_ role: MailboxRole) -> String { "rolePath.\(role.rawValue)" }

    /// The account's folder for a role: a synced one, else the one the last listing named.
    func path(for role: MailboxRole) throws -> String? {
        if let synced = try store.mailboxStates(accountID: account.id).first(where: { $0.role == role })?.path {
            return synced
        }
        return try store.setting(Self.roleKey(role), accountID: account.id).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A folder to create when the server has none for the role, named the way it wants
    /// (`INBOX.Archive` where every folder sits under `INBOX.`).
    func fallbackPath(_ name: String) throws -> String {
        (try store.setting(Self.personalPrefixKey, accountID: account.id) ?? "") + name
    }

    // MARK: Performing

    /// Applies an action locally right away and queues it for the server. Returns nil when
    /// nothing matched (e.g. Done on a thread that has already left the Inbox).
    /// `learn`: whether a move into or out of Junk teaches the junk filter (not for its own moves).
    @discardableResult
    public func perform(_ kind: TriageKind, threadIDs: [String], from mailbox: String = "INBOX", learn: Bool = true) throws -> TriageChange? {
        let changeID = UUID().uuidString
        var localIDs: [Int64]
        var add: [String] = []
        var remove: [String] = []

        switch kind {
        case .done, .trash, .junk, .moveToInbox, .move, .snooze, .unsnooze:
            let source: String = kind == .unsnooze ? try snoozedPath() : mailbox
            localIDs = try store.localIDs(threadIDs: threadIDs, mailbox: source, accountID: account.id)
            guard !localIDs.isEmpty else { return nil }
            let snapshots = try store.snapshots(localIDs: localIDs)
            var target: String
            var createTarget = false
            var surfaced: Date?? = nil
            var snooze: (Bool, Date?)? = nil
            switch kind {
            case .done:
                if let archive = try path(for: .archive) { target = archive } else { target = try fallbackPath("Archive"); createTarget = true }
            case .trash:
                if let trash = try path(for: .trash) { target = trash } else { target = try fallbackPath("Deleted Messages"); createTarget = true }
            case .junk:
                if let junk = try path(for: .junk) { target = junk } else { target = try fallbackPath("Junk"); createTarget = true }
            case .move(let path):
                guard path != mailbox else { return nil }
                target = path
            case .moveToInbox:
                target = "INBOX"
                remove = Array(Set(snapshots.flatMap { SnoozeKeywords.all(in: $0.flags.split(separator: " ").map(String.init)) }))
                snooze = (false, nil)
            case .snooze(let until):
                target = try snoozedPath()
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
            // Already there (Done on archived mail, e.g. from a smart folder): nothing to move,
            // and moving a mailbox onto itself would only make a copy on iCloud.
            guard target.caseInsensitiveCompare(source) != .orderedSame else { return nil }
            let items = snapshots.map { QueuedAction.MoveItem(localID: $0.localID, fromMailbox: $0.mailbox, fromUID: $0.uid) }
            try store.db.write { db in
                try store.applyLocalMove(localIDs: localIDs, to: target, flagsAdd: add, flagsRemove: remove,
                                         surfacedAt: surfaced, snooze: snooze, in: db)
                try store.enqueue(.move(items: items, to: target, addFlags: add, removeFlags: remove, createTarget: createTarget),
                                  accountID: account.id, changeID: changeID, in: db)
            }
            if learn { try learnFromMove(kind, localIDs: localIDs, from: source, to: target) }
            if case .snooze = kind { try store.noteMessageState(localIDs: localIDs, login: account.login) }
            if kind == .unsnooze { try store.noteMessageState(localIDs: localIDs, login: account.login) }
            signalWork()
            return TriageChange(id: changeID, accountID: account.id, kind: kind, threadCount: threadIDs.count,
                                snapshots: snapshots, addedFlags: add, removedFlags: remove)

        case .pin, .unpin, .markRead, .markUnread, .replyLater, .clearReplyLater, .readLater, .clearReadLater:
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
            case .replyLater:
                localIDs = try threadIDs.compactMap { thread in
                    try store.messages(inThread: thread).filter { $0.accountID == account.id }.last?.id
                }
                add = [replyLaterKeyword]
            case .clearReplyLater:
                localIDs = snapshotsAll.filter { $0.flags.contains(replyLaterKeyword) }.map(\.localID)
                remove = [replyLaterKeyword]
            case .readLater:
                localIDs = snapshotsAll.map(\.localID)
                add = [readLaterKeyword]
            case .clearReadLater:
                localIDs = snapshotsAll.filter { $0.flags.contains(readLaterKeyword) }.map(\.localID)
                remove = [readLaterKeyword]
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
            if [.replyLater, .clearReplyLater, .readLater, .clearReadLater].contains(kind) {
                try store.noteMessageState(localIDs: localIDs, login: account.login)
            }
            signalWork()
            return TriageChange(id: changeID, accountID: account.id, kind: kind, threadCount: threadIDs.count,
                                snapshots: snapshots, addedFlags: add, removedFlags: remove)
        }
    }

    // MARK: Corrections

    /// "This sender belongs in X": recategorizes the sender's mail now and remembers it for
    /// future mail (layer 0 of the classifier). Local only; categories aren't on the server yet.
    @discardableResult
    public func moveSender(of threadIDs: [String], to category: MailCategory) throws -> Int {
        var changed = 0
        for thread in threadIDs {
            guard let sender = try store.messages(inThread: thread).last(where: { !account.addresses.contains($0.fromAddress.lowercased()) })?.fromAddress
                    ?? store.messages(inThread: thread).last?.fromAddress else { continue }
            changed += try store.remember(category: category, forSender: sender).count
        }
        return changed
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
            case .pin, .unpin, .markRead, .markUnread, .replyLater, .clearReplyLater, .readLater, .clearReadLater:
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
        // An undone move into or out of Junk takes back what it taught the filter.
        if let junk = try path(for: .junk),
           change.byFilter || change.kind == .junk || change.kind == .move(toMailbox: junk)
            || change.snapshots.contains(where: { $0.mailbox.caseInsensitiveCompare(junk) == .orderedSame }) {
            try unlearnUndone(change)
        }
        // Undone Reply Later / Read Later / snooze: the recorded state follows (or the next
        // re-apply would put it back).
        switch change.kind {
        case .replyLater, .clearReplyLater, .readLater, .clearReadLater, .snooze, .unsnooze:
            try store.noteMessageState(localIDs: change.snapshots.map(\.localID), login: account.login)
        default: break
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
        emit(.snoozesWoke(messageIDs: due))
    }

    // MARK: Our keywords on servers that drop them

    /// Some servers (iCloud, on ordinary Inbox mail) answer OK to a custom keyword but never
    /// store it. We learn that from reading flags back after a STORE (`execute`), and from
    /// then on a sync keeps our keywords locally instead of taking server truth for them.
    /// Reply Later and snooze wake times then live on this device only, not across devices.
    static let keepsKeywordsKey = "serverKeepsKeywords"

    /// Our own keywords: Reply Later and the snooze keywords.
    static func isOwnKeyword(_ flag: String) -> Bool { flag.hasPrefix("$Tidings") }

    /// False once the server was seen dropping our keywords; nil until a STORE has shown either way.
    public func serverKeepsKeywords() -> Bool? {
        (try? store.setting(Self.keepsKeywordsKey, accountID: account.id)).map { $0 == "true" }
    }

    // MARK: Draining the queue

    /// Applies queued actions in order. Stops at the first connection-level failure so later
    /// actions never overtake earlier ones; command failures are retried, then dropped.
    func drain(_ session: MailSession) async throws {
        await acquireServer()
        defer { releaseServer() }
        try await drainLocked(session)
    }

    /// `drain` for a caller that already holds the server turn (a folder change).
    /// A change the server refused waits for the next pass (after the next IDLE wake), and so do
    /// later changes to the same messages (their order matters); changes to other messages go
    /// ahead, and so does the sync. A connection error still stops the whole pass, so one dropped
    /// connection doesn't use up every change's tries.
    func drainLocked(_ session: MailSession) async throws {
        hasPendingWork = false
        var held = Set<Int64>()
        var refused: [String] = []
        for var pending in try store.pendingActions(accountID: account.id) {
            guard let id = pending.id else { continue }
            guard let action = pending.action else {
                try store.deletePending(id: id)
                continue
            }
            guard action.localIDs.isDisjoint(with: held) else { continue }
            do {
                try await execute(action, session)
                try store.deletePending(id: id)
            } catch let error as MailSessionError {
                SyncLog.info("queued action failed (attempt \(pending.attempts + 1)): \(error.description)")
                pending.attempts += 1
                pending.lastError = error.description
                if pending.attempts >= Self.maxAttempts {
                    // Give up: forget local placeholders; the next sync restores server truth.
                    try abandon(action)
                    try store.deletePending(id: id)
                    emit(.changeRefused(error.description))
                } else {
                    try store.savePending(pending)
                    held.formUnion(action.localIDs)
                    refused.append(error.description)
                }
            }
        }
        if !refused.isEmpty {
            SyncLog.info("queue: \(refused.count) change(s) refused, retried on the next pass")
            emit(.changeRefused(refused.joined(separator: "; ")))
        }
    }

    /// Moves each source mailbox's share of `items` to `target`, flag edits first.
    private func moveGroups(_ items: [QueuedAction.MoveItem], to target: String, add: [String], remove: [String],
                            _ session: MailSession) async throws {
        for (mailbox, group) in Dictionary(grouping: items, by: \.fromMailbox) {
            _ = try await session.select(mailbox)
            let uids = group.map(\.fromUID).filter { $0 < provisionalUIDBase }
            if !add.isEmpty { try await session.store(uids: uids, .add, flags: add) }
            if !remove.isEmpty { try await session.store(uids: uids, .remove, flags: remove) }
            let mapping = try await session.move(uids: uids, to: target)
            try store.applyMoveResult(accountID: account.id, target: target, items: group, mapping: mapping)
        }
    }

    /// `path` under the account's personal prefix (`INBOX.`): unchanged when it's already there,
    /// is the Inbox itself, or the server has no prefix.
    static func underPrefix(_ path: String, _ prefix: String) -> String {
        guard !prefix.isEmpty, path.uppercased() != "INBOX",
              !path.uppercased().hasPrefix(prefix.uppercased()) else { return path }
        return prefix + path
    }

    /// The prefix a server's refusal asks for: Dovecot's "Mailbox name should probably be
    /// prefixed with: INBOX." gives `INBOX.`.
    static func namespaceHint(in message: String) -> String? {
        guard let range = message.range(of: "prefixed with: ") else { return nil }
        let rest = message[range.upperBound...]
        let prefix = rest.prefix { !$0.isWhitespace && $0 != ")" }
        return prefix.isEmpty ? nil : String(prefix)
    }

    func execute(_ action: QueuedAction, _ session: MailSession) async throws {
        switch action {
        case .move(let items, let queuedTarget, let add, let remove, let createTarget):
            // Snoozes queued before the folder followed the server's namespace said "Snoozed";
            // send them where this server wants it ("INBOX.Snoozed").
            let target: String
            if Self.isSnoozedMailbox(queuedTarget), let path = try? snoozedPath() {
                target = path
            } else {
                // Any other folder named without the server's `INBOX.` (queued before the account's
                // prefix was known, or a rule's folder from another account): where the server wants it.
                target = Self.underPrefix(queuedTarget, try store.setting(Self.personalPrefixKey, accountID: account.id) ?? "")
            }
            if target != queuedTarget {
                try await store.db.write { db in
                    try db.execute(sql: "UPDATE message SET mailbox = ? WHERE accountID = ? AND mailbox = ?",
                                   arguments: [target, account.id, queuedTarget])
                }
            }
            do {
                if createTarget { try await session.ensureMailbox(target) }
                try await moveGroups(items, to: target, add: add, remove: remove, session)
            } catch let error as MailSessionError {
                // Dovecot names the prefix it wants ("should probably be prefixed with: INBOX."):
                // remember it, so the next attempt goes there.
                if let prefix = Self.namespaceHint(in: error.description), !prefix.isEmpty {
                    try store.setSetting(Self.personalPrefixKey, prefix, accountID: account.id)
                }
                throw MailSessionError.commandFailed(command: "Move to \(target)", detail: error.description)
            }
        case .flags(let localIDs, let add, let remove):
            let byMailbox = Dictionary(grouping: try store.locations(localIDs: localIDs), by: \.mailbox)
            for (mailbox, group) in byMailbox {
                let uids = group.map(\.uid).filter { $0 < provisionalUIDBase }
                guard !uids.isEmpty else {
                    SyncLog.info("flags: skipped \(mailbox), only provisional UIDs \(group.map(\.uid))")
                    continue
                }
                _ = try await session.select(mailbox)
                if !add.isEmpty { try await session.store(uids: uids, .add, flags: add) }
                if !remove.isEmpty { try await session.store(uids: uids, .remove, flags: remove) }
                SyncLog.info("flags: \(mailbox) uids \(uids) +\(add) -\(remove)")
                // Read the flags back on the same connection: do our keywords stick on this server?
                if let check = try? await session.fetchFlags(uids: uids) {
                    for (uid, state) in check.sorted(by: { $0.key < $1.key }) {
                        SyncLog.info("flags: \(mailbox) uid \(uid) now [\(state.flags.sorted().joined(separator: " "))] modseq \(state.modSeq.map(String.init) ?? "-")")
                    }
                    let ours = add.filter(Self.isOwnKeyword)
                    if !ours.isEmpty, !check.isEmpty {
                        let kept = check.values.allSatisfy { state in ours.allSatisfy(state.flags.contains) }
                        try? store.setSetting(Self.keepsKeywordsKey, kept ? "true" : "false", accountID: account.id)
                        if !kept { SyncLog.info("server accepted but didn't keep \(ours): keeping our keywords locally") }
                    }
                }
            }
        }
    }

    func abandon(_ action: QueuedAction) throws {
        // The server never saw this change, and its MODSEQ won't tell an incremental sync to put
        // things back: the next sync of the mailboxes involved reads them in full.
        switch action {
        case .move(let items, let target, _, _, _):
            try store.forgetModSeq(accountID: account.id, mailboxes: Set(items.map(\.fromMailbox)).union([target]))
            try store.delete(ids: items.map(\.localID))
        case .flags(let localIDs, _, _):
            try store.forgetModSeq(accountID: account.id, mailboxes: Set(try store.locations(localIDs: localIDs).map(\.mailbox)))
        }
    }

    /// Applies queued actions on a fresh connection (when the sync loop isn't running, e.g. tests).
    public func processPendingActions() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.drain(session)
        }
    }
}

extension QueuedAction {
    /// The messages this change touches.
    var localIDs: Set<Int64> {
        switch self {
        case .move(let items, _, _, _, _): Set(items.map(\.localID))
        case .flags(let ids, _, _): Set(ids)
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
