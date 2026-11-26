import Foundation
import MailEngine

/// A folder sheet: New Folder, Rename or Move To (SPEC §12: every action is in ⌘K too).
struct FolderEditing: Identifiable {
    enum Kind: Equatable {
        case create(parent: String?)
        case rename(String)
        case move(String)
    }
    let id = UUID()
    let accountID: String
    let kind: Kind
}

/// Waiting for "Delete Folder" to be confirmed.
struct FolderDeletion: Identifiable {
    var id: String { accountID + "\u{0}" + path }
    let accountID: String
    let path: String
    let name: String
    let subfolderCount: Int
    let messageCount: Int
    /// The folder is special (or holds one): the dialog says so.
    let specialName: String?
}

/// One folder row in the sidebar or a location picker.
struct FolderRow: Identifiable, Hashable {
    var id: String { box.path }
    let box: MailboxState
    /// What the row says: the role's title, else the folder's own name ("Acme", not "INBOX.Clients.Acme").
    let name: String
    /// Indentation under the folders shown above it.
    let depth: Int
}

extension AppModel {
    func folderLayout(accountID: String) -> (separator: Character?, prefix: String) {
        AccountSync.folderLayout(store: store, accountID: accountID)
    }

    /// The name a folder shows: its role's title, else its last path component.
    func folderName(_ box: MailboxState) -> String {
        if let role = box.role { return role.title }
        if box.path.uppercased() == "INBOX" { return String(localized: "Inbox") }
        return FolderPath.name(of: box.path, separator: folderLayout(accountID: box.accountID).separator)
    }

    /// An account's folders for the sidebar: Archive, Sent and Drafts first, then the others as
    /// a tree (each folder under its parent, indented), without INBOX and Snoozed.
    func folderRows(accountID: String) -> [FolderRow] {
        let (separator, prefix) = folderLayout(accountID: accountID)
        let boxes = mailboxes.filter { $0.accountID == accountID && $0.role != .inbox && !AccountSync.isSnoozedMailbox($0.path) }
        let order: [MailboxRole] = [.archive, .sent, .drafts]
        let special = boxes.filter { $0.role != nil }
            .sorted { (order.firstIndex(of: $0.role!) ?? order.count) < (order.firstIndex(of: $1.role!) ?? order.count) }
            .map { FolderRow(box: $0, name: folderName($0), depth: 0) }
        let plain = boxes.filter { $0.role == nil }
        let paths = Set(plain.map(\.path))
        func components(_ path: String) -> [String] {
            let below = path.uppercased().hasPrefix(prefix.uppercased()) && !prefix.isEmpty ? String(path.dropFirst(prefix.count)) : path
            return separator.map { below.split(separator: $0, omittingEmptySubsequences: false).map(String.init) } ?? [below]
        }
        let sorted = plain.sorted { a, b in
            let ca = components(a.path), cb = components(b.path)
            for (x, y) in zip(ca, cb) where x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            return ca.count < cb.count
        }
        let tree = sorted.map { box in
            // Depth counts the parents that are shown; a hidden one (\Noselect) shows in the name.
            var depth = 0
            var hidden: [String] = []
            var parent = FolderPath.parent(of: box.path, separator: separator, prefix: prefix)
            var nearestShown = false
            while let p = parent {
                if paths.contains(p) { depth += 1; nearestShown = true } else if !nearestShown, p.uppercased() != "INBOX" {
                    hidden.insert(FolderPath.name(of: p, separator: separator), at: 0)
                }
                parent = FolderPath.parent(of: p, separator: separator, prefix: prefix)
            }
            let own = FolderPath.name(of: box.path, separator: separator)
            let name = (hidden + [own]).joined(separator: " / ")
            return FolderRow(box: box, name: name, depth: depth)
        }
        return special + tree
    }

    /// Where a folder can go: the top, or inside an ordinary folder that isn't it or inside it
    /// (not INBOX, Snoozed, Sent, Drafts or Archive).
    func folderLocations(accountID: String, excluding path: String? = nil) -> [FolderRow] {
        let separator = folderLayout(accountID: accountID).separator
        return folderRows(accountID: accountID).filter { row in
            guard row.box.role == nil else { return false }
            guard let path else { return true }
            return !FolderPath.isWithin(row.box.path, path, separator: separator)
        }
    }

    func parentFolder(of path: String, accountID: String) -> String? {
        let (separator, prefix) = folderLayout(accountID: accountID)
        return FolderPath.parent(of: path, separator: separator, prefix: prefix)
    }

    /// The folder on screen, if a folder is on screen.
    var selectedFolder: MailboxState? {
        guard case .mailbox(let accountID, let path) = selection else { return nil }
        return mailboxes.first { $0.accountID == accountID && $0.path == path }
    }

    /// Special: has a role, is Snoozed, or holds one of those.
    func specialFolderName(within path: String, accountID: String) -> String? {
        let separator = folderLayout(accountID: accountID).separator
        let hit = mailboxes.first { box in
            box.accountID == accountID && FolderPath.isWithin(box.path, path, separator: separator)
                && (box.role != nil || AccountSync.isSnoozedMailbox(box.path))
        }
        guard let hit else { return nil }
        return AccountSync.isSnoozedMailbox(hit.path) ? String(localized: "Snoozed") : folderName(hit)
    }

    func canChangeFolder(_ box: MailboxState) -> Bool {
        box.role != .inbox && box.path.uppercased() != "INBOX"
    }

    // MARK: Starting

    func newFolder(accountID: String? = nil, in parent: String? = nil) {
        guard let id = accountID ?? (selectedFolder?.accountID) ?? inboxAccountID ?? accounts.first?.id else { return }
        folderEditing = FolderEditing(accountID: id, kind: .create(parent: parent))
    }

    func renameFolder(_ box: MailboxState) {
        guard canChangeFolder(box) else { return }
        folderEditing = FolderEditing(accountID: box.accountID, kind: .rename(box.path))
    }

    func moveFolder(_ box: MailboxState) {
        guard canChangeFolder(box) else { return }
        folderEditing = FolderEditing(accountID: box.accountID, kind: .move(box.path))
    }

    func requestDeleteFolder(_ box: MailboxState) {
        guard canChangeFolder(box) else { return }
        let separator = folderLayout(accountID: box.accountID).separator
        let inside = mailboxes.filter { $0.accountID == box.accountID && FolderPath.isWithin($0.path, box.path, separator: separator) }
        folderToDelete = FolderDeletion(
            accountID: box.accountID, path: box.path, name: folderName(box),
            subfolderCount: inside.count - 1, messageCount: inside.reduce(0) { $0 + $1.messageCount },
            specialName: specialFolderName(within: box.path, accountID: box.accountID))
    }

    // MARK: Doing

    /// Runs a folder change on the server. Throws a message to show in the sheet.
    func createFolder(named name: String, in parent: String?, accountID: String) async throws {
        guard let sync = syncs[accountID] else { throw FolderFailure(String(localized: "This account isn't connected.")) }
        do {
            let path = try await sync.createFolder(named: name, in: parent)
            reload()
            show(Toast(message: String(localized: "Created “\(FolderPath.name(of: path, separator: folderLayout(accountID: accountID).separator))”"),
                       symbol: "folder.badge.plus"))
        } catch { throw FolderFailure(folderErrorMessage(error)) }
    }

    func renameFolder(_ path: String, to name: String, accountID: String) async throws {
        guard let sync = syncs[accountID] else { throw FolderFailure(String(localized: "This account isn't connected.")) }
        do {
            let newPath = try await sync.renameFolder(path, to: name, allowSpecial: true)
            folderMoved(from: path, to: newPath, accountID: accountID)
            show(Toast(message: String(localized: "Renamed to “\(FolderPath.name(of: newPath, separator: folderLayout(accountID: accountID).separator))”"),
                       symbol: "pencil"))
        } catch { throw FolderFailure(folderErrorMessage(error)) }
    }

    func moveFolder(_ path: String, into parent: String?, accountID: String) async throws {
        guard let sync = syncs[accountID] else { throw FolderFailure(String(localized: "This account isn't connected.")) }
        do {
            let newPath = try await sync.moveFolder(path, into: parent, allowSpecial: true)
            folderMoved(from: path, to: newPath, accountID: accountID)
            let separator = folderLayout(accountID: accountID).separator
            let name = FolderPath.name(of: newPath, separator: separator)
            let message = parent.map { String(localized: "Moved “\(name)” into “\(FolderPath.name(of: $0, separator: separator))”") }
                ?? String(localized: "Moved “\(name)” to the top level")
            show(Toast(message: message, symbol: "folder"))
        } catch { throw FolderFailure(folderErrorMessage(error)) }
    }

    func deleteFolder(_ deletion: FolderDeletion) {
        folderToDelete = nil
        guard let sync = syncs[deletion.accountID] else { return }
        Task {
            do {
                let gone = try await sync.deleteFolder(deletion.path, allowSpecial: true)
                if case .mailbox(let id, let path) = selection, id == deletion.accountID, gone.contains(path) { goToInbox() }
                reload()
                show(Toast(message: String(localized: "Deleted “\(deletion.name)”"), symbol: "trash"))
            } catch {
                lastError = folderErrorMessage(error)
                show(Toast(message: String(localized: "Couldn't delete “\(deletion.name)”: \(folderErrorMessage(error))"),
                           symbol: "exclamationmark.triangle"))
            }
        }
    }

    /// "Use as Archive" (nil: back to what the server says).
    func useFolder(_ box: MailboxState?, as role: MailboxRole, accountID: String) {
        guard let sync = syncs[accountID] else { return }
        Task {
            do {
                try await sync.chooseFolder(box?.path, for: role)
                reload()
                if let box {
                    show(Toast(message: String(localized: "“\(FolderPath.name(of: box.path, separator: folderLayout(accountID: accountID).separator))” is now used as \(role.title)"),
                               symbol: role.symbol))
                }
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    /// After a rename or move: the folder on screen and rules that file mail there follow.
    private func folderMoved(from old: String, to new: String, accountID: String) {
        let separator = folderLayout(accountID: accountID).separator
        if case .mailbox(let id, let path) = selection, id == accountID,
           let moved = FolderPath.renamed(path, from: old, to: new, separator: separator) {
            selection = .mailbox(accountID: accountID, path: moved)
        }
        var changed = false
        for index in rules.indices {
            for (actionIndex, action) in rules[index].actions.enumerated() {
                if case .moveToFolder(let path) = action, let moved = FolderPath.renamed(path, from: old, to: new, separator: separator) {
                    rules[index].actions[actionIndex] = .moveToFolder(moved)
                    changed = true
                }
            }
        }
        if changed { saveRules() }
        reload()
    }

    func folderErrorMessage(_ error: any Error) -> String {
        switch error {
        case let failure as FolderFailure: return failure.message
        case let error as FolderError:
            switch error {
            case .invalidName: return String(localized: "That name can't be used for a folder.")
            case .containsSeparator(let c): return String(localized: "Folder names can't contain “\(String(c))” on this server.")
            case .alreadyExists: return String(localized: "There's already a folder with that name.")
            case .notFound: return String(localized: "That folder is no longer on the server.")
            case .inbox: return String(localized: "The Inbox can't be changed.")
            case .specialFolder: return String(localized: "That's a special folder.")
            case .intoItself: return String(localized: "A folder can't go inside itself.")
            case .noSubfolders: return String(localized: "That folder can't hold other folders.")
            }
        case let error as MailSessionError:
            if case .commandFailed(_, let detail) = error {
                // `no(ResponseText(code: …, text: "Mailbox exists"))` → "Mailbox exists"
                let said = detail.range(of: "text: \"").flatMap { start in
                    detail[start.upperBound...].firstIndex(of: "\"").map { String(detail[start.upperBound..<$0]) }
                } ?? detail
                return String(localized: "The server said no: \(said)")
            }
            return error.description
        default:
            return String(localized: "Couldn't reach the server: \(error.localizedDescription)")
        }
    }
}

struct FolderFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension AppModel {
    /// ⌘K: New Folder per account; Rename / Move / Delete / Use As for the folder on screen;
    /// Go to each folder.
    var folderCommands: [AppCommand] {
        var list: [AppCommand] = []
        for account in accounts {
            let title = accounts.count > 1 ? String(localized: "New Folder in \(account.displayName)…") : String(localized: "New Folder…")
            list.append(AppCommand(id: "newFolder-\(account.id)", title: title, symbol: "folder.badge.plus", keys: nil) {
                self.newFolder(accountID: account.id)
            })
        }
        if let box = selectedFolder, canChangeFolder(box) {
            let name = folderName(box)
            list += [
                AppCommand(id: "newSubfolder", title: String(localized: "New Folder Inside “\(name)”…"), symbol: "folder.badge.plus", keys: nil) {
                    self.newFolder(accountID: box.accountID, in: box.path)
                },
                AppCommand(id: "renameFolder", title: String(localized: "Rename Folder “\(name)”…"), symbol: "pencil", keys: nil) {
                    self.renameFolder(box)
                },
                AppCommand(id: "moveFolderTo", title: String(localized: "Move Folder “\(name)”…"), symbol: "folder", keys: nil) {
                    self.moveFolder(box)
                },
                AppCommand(id: "deleteFolder", title: String(localized: "Delete Folder “\(name)”…"), symbol: "trash", keys: nil) {
                    self.requestDeleteFolder(box)
                },
            ]
            for role in AccountSync.choosableRoles where box.role != role {
                list.append(AppCommand(id: "useFolderAs-\(role.rawValue)", title: String(localized: "Use “\(name)” as \(role.title)"),
                                       symbol: role.symbol, keys: nil) {
                    self.useFolder(box, as: role, accountID: box.accountID)
                })
            }
        }
        for account in accounts {
            for row in folderRows(accountID: account.id) where row.box.role == nil {
                let title = accounts.count > 1 ? String(localized: "Go to \(row.name) (\(account.displayName))")
                                               : String(localized: "Go to \(row.name)")
                list.append(AppCommand(id: "goFolder-\(account.id)-\(row.box.path)", title: title, symbol: "folder", keys: nil) {
                    self.selection = .mailbox(accountID: account.id, path: row.box.path)
                })
            }
        }
        return list
    }
}
