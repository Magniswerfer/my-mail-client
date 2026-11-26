import Foundation
import GRDB

/// Why a folder change was refused. The app words these; the engine only says which.
public enum FolderError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Empty, only spaces, or a character the server can't have in a name.
    case invalidName
    /// The name holds the server's hierarchy separator ("." on Dovecot with `INBOX.`).
    case containsSeparator(Character)
    case alreadyExists(String)
    case notFound(String)
    /// INBOX can't be renamed, moved or deleted.
    case inbox
    /// Sent, Drafts, Trash, Junk, Archive or Snoozed (or a folder holding one): the caller must
    /// pass `allowSpecial` after warning. The string is the special folder's path.
    case specialFolder(String)
    /// Moving a folder into itself or one of its own subfolders.
    case intoItself
    /// The server keeps no hierarchy (no separator) or the parent can't hold folders.
    case noSubfolders

    public var description: String {
        switch self {
        case .invalidName: "invalid folder name"
        case .containsSeparator(let c): "folder name contains the separator \"\(c)\""
        case .alreadyExists(let path): "\(path) already exists"
        case .notFound(let path): "\(path) doesn't exist"
        case .inbox: "INBOX can't be changed"
        case .specialFolder(let path): "\(path) is a special folder"
        case .intoItself: "a folder can't go inside itself"
        case .noSubfolders: "that folder can't hold folders"
        }
    }
}

/// Folder paths as the server spells them, and the names people see.
///
/// On servers whose folders all live under a personal namespace (Dovecot's `INBOX.`), `prefix`
/// is `INBOX.`: `INBOX.Clients.Acme` shows as "Acme" inside "Clients", and a new top-level
/// folder "Receipts" is created as `INBOX.Receipts`.
public enum FolderPath {
    /// The last component: what the sidebar shows.
    public static func name(of path: String, separator: Character?) -> String {
        guard let separator, let last = path.split(separator: separator, omittingEmptySubsequences: false).last else { return path }
        return String(last)
    }

    /// The folder holding `path`, or nil for a top-level folder (directly under the prefix).
    public static func parent(of path: String, separator: Character?, prefix: String) -> String? {
        guard let separator else { return nil }
        let below = stripped(path, prefix: prefix)
        guard let cut = below.lastIndex(of: separator) else { return nil }
        return String(path.prefix(path.count - below.count)) + below[..<cut]
    }

    /// How many folders up to the top: 0 for a top-level folder.
    public static func depth(of path: String, separator: Character?, prefix: String) -> Int {
        guard let separator else { return 0 }
        return stripped(path, prefix: prefix).filter { $0 == separator }.count
    }

    /// The path for a folder named `name` inside `parent` (nil: at the top, under the prefix).
    public static func child(named name: String, of parent: String?, separator: Character?, prefix: String) -> String {
        if let parent, let separator { return parent + String(separator) + name }
        return prefix + name
    }

    /// `path` is `ancestor` itself or somewhere inside it.
    public static func isWithin(_ path: String, _ ancestor: String, separator: Character?) -> Bool {
        if path == ancestor { return true }
        guard let separator else { return false }
        return path.hasPrefix(ancestor + String(separator))
    }

    /// Where `path` ends up when `from` becomes `to` (it or anything inside it); nil if unaffected.
    public static func renamed(_ path: String, from: String, to: String, separator: Character?) -> String? {
        guard isWithin(path, from, separator: separator) else { return nil }
        return to + path.dropFirst(from.count)
    }

    /// Checks a name typed for a new or renamed folder; returns it trimmed.
    public static func validated(_ name: String, separator: Character?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.contains(where: { $0 == "*" || $0 == "%" || $0.isNewline || $0 == "\"" || $0 == "\\" }),
              trimmed.uppercased() != "INBOX" else { throw FolderError.invalidName }
        if let separator, trimmed.contains(separator) { throw FolderError.containsSeparator(separator) }
        return trimmed
    }

    static func stripped(_ path: String, prefix: String) -> Substring {
        guard !prefix.isEmpty, path.uppercased().hasPrefix(prefix.uppercased()) else { return Substring(path) }
        return path.dropFirst(prefix.count)
    }
}

extension AccountSync {
    static let separatorKey = "hierarchySeparator"
    /// Folders chosen by hand for a role ("Use as Archive"), per account: `role.archive` → path.
    static func roleChoiceKey(_ role: MailboxRole) -> String { "role.\(role.rawValue)" }
    /// The roles a folder can be chosen for. Trash and Junk aren't synced or shown, so not offered.
    public static let choosableRoles: [MailboxRole] = [.archive, .sent, .drafts]

    /// INBOX's separator from LIST (else the first folder's).
    static func hierarchySeparator(in listing: [MailboxListing]) -> Character? {
        listing.first { $0.path.uppercased() == "INBOX" }?.separator ?? listing.first { $0.separator != nil }?.separator
    }

    /// How this account's folders are spelled, from the last sync: the separator and the
    /// personal namespace prefix (`INBOX.` on Dovecot set up that way, else empty).
    public nonisolated static func folderLayout(store: MailStore, accountID: String) -> (separator: Character?, prefix: String) {
        let separator = (try? store.setting(separatorKey, accountID: accountID))?.first
        let prefix = (try? store.setting(personalPrefixKey, accountID: accountID)) ?? ""
        return (separator, prefix)
    }

    // MARK: Roles chosen by hand

    /// The folder chosen for a role, if any.
    public func chosenFolder(for role: MailboxRole) -> String? {
        (try? store.setting(Self.roleChoiceKey(role), accountID: account.id)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Uses `path` for `role` from now on (nil: back to what the server says). Applied locally at
    /// once; the next sync keeps it. Stays on this device.
    public func chooseFolder(_ path: String?, for role: MailboxRole) throws {
        guard Self.choosableRoles.contains(role) else { return }
        try store.setSetting(Self.roleChoiceKey(role), path ?? "", accountID: account.id)
        guard let path else { checkNow(); return }
        try store.db.write { db in
            try db.execute(sql: "UPDATE mailboxState SET role = NULL WHERE accountID = ? AND role = ?",
                           arguments: [account.id, role.rawValue])
            try db.execute(sql: "UPDATE mailboxState SET role = ? WHERE accountID = ? AND path = ?",
                           arguments: [role.rawValue, account.id, path])
        }
    }

    /// Hand-picked roles win over SPECIAL-USE and names, while the folder exists.
    func applyRoleChoices(_ roles: inout [MailboxRole: String], listing: [MailboxListing]) throws {
        for role in Self.choosableRoles {
            guard let path = chosenFolder(for: role), listing.contains(where: { $0.path == path }) else { continue }
            for (other, otherPath) in roles where otherPath == path { roles[other] = nil }
            roles[role] = path
        }
    }

    // MARK: Folder changes

    /// Creates a folder named `name` at the top (under the personal prefix) or inside `parent`.
    /// Returns its path. It's synced (empty) before this returns, so it shows at once.
    @discardableResult
    public func createFolder(named name: String, in parent: String? = nil) async throws -> String {
        try await withFolderSession { session, listing in
            let separator = Self.hierarchySeparator(in: listing)
            let prefix = Self.personalPrefix(in: listing)
            let clean = try FolderPath.validated(name, separator: separator)
            if let parent {
                guard separator != nil else { throw FolderError.noSubfolders }
                guard let box = listing.first(where: { $0.path == parent }) else { throw FolderError.notFound(parent) }
                if box.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noinferiors") == .orderedSame }) {
                    throw FolderError.noSubfolders
                }
            }
            let path = FolderPath.child(named: clean, of: parent, separator: separator, prefix: prefix)
            if listing.contains(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
                throw FolderError.alreadyExists(path)
            }
            try await session.create(path)
            await session.subscribe(path)
            self.bumpFolderGeneration()
            try await self.syncMailbox(session, path: path, role: nil)
            return path
        }
    }

    /// Renames a folder in place (same parent). Its subfolders follow. Returns the new path.
    @discardableResult
    public func renameFolder(_ path: String, to name: String, allowSpecial: Bool = false) async throws -> String {
        try await withFolderSession { session, listing in
            let separator = Self.hierarchySeparator(in: listing)
            let prefix = Self.personalPrefix(in: listing)
            try self.checkChangeable(path, listing: listing, allowSpecial: allowSpecial)
            let clean = try FolderPath.validated(name, separator: separator)
            let parent = FolderPath.parent(of: path, separator: separator, prefix: prefix)
            let target = FolderPath.child(named: clean, of: parent, separator: separator, prefix: prefix)
            guard target != path else { return path }
            // A change of case only ("receipts" → "Receipts") is fine; another folder isn't.
            if target.caseInsensitiveCompare(path) != .orderedSame,
               listing.contains(where: { $0.path.caseInsensitiveCompare(target) == .orderedSame }) {
                throw FolderError.alreadyExists(target)
            }
            try await self.renameOnServer(session, from: path, to: target, listing: listing, separator: separator)
            return target
        }
    }

    /// Moves a folder (and its subfolders) inside `parent`, or to the top when nil. Returns the new path.
    @discardableResult
    public func moveFolder(_ path: String, into parent: String?, allowSpecial: Bool = false) async throws -> String {
        try await withFolderSession { session, listing in
            let separator = Self.hierarchySeparator(in: listing)
            let prefix = Self.personalPrefix(in: listing)
            try self.checkChangeable(path, listing: listing, allowSpecial: allowSpecial)
            if let parent {
                guard separator != nil else { throw FolderError.noSubfolders }
                guard !FolderPath.isWithin(parent, path, separator: separator) else { throw FolderError.intoItself }
                guard let box = listing.first(where: { $0.path == parent }) else { throw FolderError.notFound(parent) }
                if box.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noinferiors") == .orderedSame }) {
                    throw FolderError.noSubfolders
                }
            }
            let target = FolderPath.child(named: FolderPath.name(of: path, separator: separator), of: parent,
                                          separator: separator, prefix: prefix)
            guard target != path else { return path }
            if listing.contains(where: { $0.path.caseInsensitiveCompare(target) == .orderedSame }) {
                throw FolderError.alreadyExists(target)
            }
            try await self.renameOnServer(session, from: path, to: target, listing: listing, separator: separator)
            return target
        }
    }

    /// Deletes a folder, its subfolders and all their mail, on the server and here. Returns the
    /// paths deleted (deepest first).
    @discardableResult
    public func deleteFolder(_ path: String, allowSpecial: Bool = false) async throws -> [String] {
        try await withFolderSession { session, listing in
            let separator = Self.hierarchySeparator(in: listing)
            try self.checkChangeable(path, listing: listing, allowSpecial: allowSpecial)
            let doomed = listing.map(\.path).filter { FolderPath.isWithin($0, path, separator: separator) }
                .sorted { $0.count > $1.count }
            self.bumpFolderGeneration()
            for box in doomed {
                try await session.delete(box)
                await session.subscribe(box, false)
            }
            self.bumpFolderGeneration()
            for box in doomed {
                try self.store.deleteMailbox(accountID: self.account.id, mailbox: box)
                self.cache.removeMailbox(box, account: self.account.id)
                try self.store.dropPending(accountID: self.account.id, inside: box, separator: separator)
            }
            for role in Self.choosableRoles where self.chosenFolder(for: role).map({ doomed.contains($0) }) == true {
                try self.store.setSetting(Self.roleChoiceKey(role), "", accountID: self.account.id)
            }
            return doomed
        }
    }

    /// Paths inside `path` (it included) that are INBOX or special. Used by the app to warn.
    public func specialFolders(within path: String) -> [String] {
        let states = (try? store.mailboxStates(accountID: account.id)) ?? []
        let separator = Self.folderLayout(store: store, accountID: account.id).separator
        return states.filter { state in
            FolderPath.isWithin(state.path, path, separator: separator)
                && ((state.role != nil) || Self.isSnoozedMailbox(state.path))
        }.map(\.path)
    }

    // MARK: Helpers

    func bumpFolderGeneration() { folderGeneration += 1 }

    /// One connection, the queue drained first (so queued moves land before a folder changes)
    /// and a fresh LIST to check names against. Errors reach the caller; nothing is queued.
    func withFolderSession<T: Sendable>(
        _ body: (MailSession, [MailboxListing]) async throws -> T
    ) async throws -> T {
        await acquireServer()
        defer { releaseServer() }
        return try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.drainLocked(session)
            let listing = try await session.listMailboxes()
            // Nothing selected: a server may not like renaming or deleting the open mailbox.
            _ = try await session.select("INBOX", readOnly: true)
            return try await body(session, listing)
        }
    }

    /// Refuses INBOX always, and special folders (or a folder holding one) unless allowed.
    func checkChangeable(_ path: String, listing: [MailboxListing], allowSpecial: Bool) throws {
        guard path.uppercased() != "INBOX" else { throw FolderError.inbox }
        guard let box = listing.first(where: { $0.path == path }) else { throw FolderError.notFound(path) }
        let separator = box.separator ?? Self.hierarchySeparator(in: listing)
        var roles = MailboxRoleResolver.resolve(listing)
        try applyRoleChoices(&roles, listing: listing)
        let states = try store.mailboxStates(accountID: account.id)
        let special = Set(roles.values).union(states.filter { $0.role != nil }.map(\.path))
            .union(listing.map(\.path).filter(Self.isSnoozedMailbox))
        let inside = listing.map(\.path).filter { FolderPath.isWithin($0, path, separator: separator) }
        if inside.contains(where: { $0.uppercased() == "INBOX" }) { throw FolderError.inbox }
        if !allowSpecial, let hit = inside.first(where: special.contains) { throw FolderError.specialFolder(hit) }
    }

    /// RENAME on the server, then the same rename here: messages, sync state, queued actions,
    /// hand-picked roles and cached bodies, for the folder and everything inside it.
    func renameOnServer(_ session: MailSession, from: String, to: String, listing: [MailboxListing],
                        separator: Character?) async throws {
        let affected = listing.map(\.path).filter { FolderPath.isWithin($0, from, separator: separator) }
        bumpFolderGeneration()
        try await session.rename(from, to: to)
        bumpFolderGeneration()
        for old in affected {
            guard let new = FolderPath.renamed(old, from: from, to: to, separator: separator) else { continue }
            await session.subscribe(old, false)
            await session.subscribe(new)
            cache.renameMailbox(old, to: new, account: account.id)
        }
        try store.renameMailbox(accountID: account.id, from: from, to: to, separator: separator)
        for role in Self.choosableRoles {
            if let chosen = chosenFolder(for: role),
               let moved = FolderPath.renamed(chosen, from: from, to: to, separator: separator) {
                try store.setSetting(Self.roleChoiceKey(role), moved, accountID: account.id)
            }
        }
        // Check the renamed folders against the server (UIDs normally survive a RENAME).
        let roles = Dictionary(try store.mailboxStates(accountID: account.id).compactMap { s in s.role.map { (s.path, $0) } },
                               uniquingKeysWith: { a, _ in a })
        for old in affected {
            guard let new = FolderPath.renamed(old, from: from, to: to, separator: separator),
                  let box = listing.first(where: { $0.path == old }),
                  !box.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }) else { continue }
            try await syncMailbox(session, path: new, role: roles[new])
        }
    }
}

extension MailStore {
    /// Local side of a RENAME: `from` and everything inside it become `to…`.
    func renameMailbox(accountID: String, from: String, to: String, separator: Character?) throws {
        let sep = separator.map(String.init) ?? ""
        // Leftovers under the new name (from an earlier folder there) would clash.
        for stale in try mailboxStates(accountID: accountID) where FolderPath.isWithin(stale.path, to, separator: separator) {
            try deleteMailbox(accountID: accountID, mailbox: stale.path)
        }
        func within(_ column: String) -> String {
            "(\(column) = :from OR (:sep <> '' AND substr(\(column), 1, length(:from) + length(:sep)) = :from || :sep))"
        }
        let args: StatementArguments = ["from": from, "to": to, "sep": sep, "account": accountID]
        try db.write { db in
            try db.execute(sql: "UPDATE message SET mailbox = :to || substr(mailbox, length(:from) + 1) WHERE accountID = :account AND \(within("mailbox"))",
                           arguments: args)
            try db.execute(sql: "UPDATE mailboxState SET path = :to || substr(path, length(:from) + 1) WHERE accountID = :account AND \(within("path"))",
                           arguments: args)
            // Queued actions that still name the old folder (queued while the rename ran).
            try rewritePending(db, accountID: accountID) { path in
                FolderPath.renamed(path, from: from, to: to, separator: separator) ?? path
            }
        }
    }

    /// Queued actions moving mail out of or into a deleted folder can't run any more.
    func dropPending(accountID: String, inside path: String, separator: Character?) throws {
        try db.write { db in
            for pending in try PendingAction.filter(Column("accountID") == accountID).fetchAll(db) {
                guard case .move(let items, let target, _, _, _)? = pending.action else { continue }
                if FolderPath.isWithin(target, path, separator: separator)
                    || items.contains(where: { FolderPath.isWithin($0.fromMailbox, path, separator: separator) }) {
                    _ = try pending.delete(db)
                }
            }
        }
    }

    private func rewritePending(_ db: Database, accountID: String, _ map: (String) -> String) throws {
        for var pending in try PendingAction.filter(Column("accountID") == accountID).fetchAll(db) {
            guard case .move(let items, let target, let add, let remove, let create)? = pending.action else { continue }
            let newItems = items.map { QueuedAction.MoveItem(localID: $0.localID, fromMailbox: map($0.fromMailbox), fromUID: $0.fromUID) }
            let rewritten = QueuedAction.move(items: newItems, to: map(target), addFlags: add, removeFlags: remove, createTarget: create)
            guard rewritten != pending.action else { continue }
            pending.payload = try JSONEncoder().encode(rewritten)
            try pending.update(db)
        }
    }
}

extension MessageCache {
    func renameMailbox(_ old: String, to new: String, account: String) {
        let from = url(account: account, mailbox: old, validity: 0, uid: 0).deletingLastPathComponent()
        let to = url(account: account, mailbox: new, validity: 0, uid: 0).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    func removeMailbox(_ mailbox: String, account: String) {
        guard !account.isEmpty, !account.contains("/") else { return }
        try? FileManager.default.removeItem(at: url(account: account, mailbox: mailbox, validity: 0, uid: 0).deletingLastPathComponent())
    }
}
