import Foundation
import MailEngine
import SwiftUI

extension AppModel {
    // MARK: Identities

    func identities(for accountID: String) -> [Identity] {
        accounts.first { $0.id == accountID }?.sendingIdentities ?? []
    }

    /// New mail comes from the account whose Inbox you're looking at, else the first one.
    var defaultAccount: AccountConfig? { inboxAccountID.flatMap(account(id:)) ?? accounts.first }

    /// The account that sends as this identity: `preferring` if it has it, else the first that does.
    func accountID(sending identity: Identity, preferring: String? = nil) -> String? {
        let owners = accounts.filter { $0.sendingIdentities.contains { $0.id == identity.id } }
        return owners.first { $0.id == preferring }?.id ?? owners.first?.id
    }

    func addIdentity(address: String, accountID: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard let index = accounts.firstIndex(where: { $0.id == accountID }), trimmed.contains("@") else { return }
        var list = accounts[index].sendingIdentities
        guard !list.contains(where: { $0.address == trimmed }) else { return }
        list.append(Identity(address: trimmed, name: list.first?.name ?? Platform.fullUserName, signature: list.first?.signature ?? ""))
        accounts[index].identities = list
        if !accounts[index].addresses.contains(trimmed) { accounts[index].addresses.append(trimmed) }
        persistAccounts()
    }

    func updateIdentity(_ identity: Identity, accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        var list = accounts[index].sendingIdentities
        guard let i = list.firstIndex(where: { $0.id == identity.id }) else { return }
        list[i] = identity
        accounts[index].identities = list
        persistAccounts()
    }

    func removeIdentity(_ identity: Identity, accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].identities = accounts[index].sendingIdentities.filter { $0.id != identity.id }
        persistAccounts()
    }

    /// Identities and addresses live in the account list (UserDefaults), never in the Keychain.
    /// The dev copy keeps its own list (its local Dovecot account included, for its identities).
    func persistAccounts() {
        AccountStorage.save(accounts, dev: isDevServer)
        AccountStorage.saveAwaiting(accountsAwaitingPassword, dev: isDevServer)
        // Accounts sync too (names, servers, identities; never passwords).
        scheduleCloudPush()
    }

    // MARK: Opening the composer

    func composeNew(to recipients: [MailAddress] = []) {
        guard let account = defaultAccount, let identity = account.sendingIdentities.first else { return }
        let body = NSMutableAttributedString(string: "", attributes: RichTextEditor.baseAttributes)
        if !identity.signature.isEmpty {
            body.append(NSAttributedString(string: "\n", attributes: RichTextEditor.baseAttributes))
            body.append(ComposeModel.signatureBlock(identity.signature))
        }
        openDraft(OutgoingMessage(from: identity.mailAddress, to: recipients, subject: "", text: ""), body: body,
                  accountID: account.id, kind: .new, originalLocalID: nil)
    }

    /// Reply, reply all or forward the newest message of the selected conversation (SPEC §9).
    func compose(_ kind: ComposeKind, thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first,
              let account = accounts.first(where: { $0.id == thread.latest.accountID }) else { return }
        // A reply (or follow-up) Tidings drafted for this conversation is what Reply opens, ready
        // to edit; the editor's Clear Suggestion starts over.
        if kind == .reply, let suggested = autoDraft(forThread: thread.threadID)?.outboxID {
            openDraftInPlace(suggested, threadID: thread.threadID)
            return
        }
        // Mac: a conversation with a reply already open in the reading pane keeps that one.
        if Platform.isMac, let open = inlineDrafts[thread.threadID],
           (try? store.outboxItem(id: open))?.state == .draft {
            return
        }
        Task {
            guard let id = await prepareDraft(kind, thread: thread, account: account) else { return }
            openDraftInPlace(id, threadID: thread.threadID)
        }
    }

    /// A reply or forward: in the reading pane under its conversation on the Mac, a window or
    /// sheet elsewhere.
    func openDraftInPlace(_ id: Int64, threadID: String) {
        if Platform.isMac {
            if selectedThreadID != threadID { selectedThreadID = threadID }
            inlineDrafts[threadID] = id
        } else {
            openComposeWindow?(id)
        }
    }

    /// Clear Suggestion: drop the text Tidings drafted (it won't draft this one again) and start
    /// a plain reply in its place.
    /// `inWindow`: the suggestion was open in a window or sheet, so the fresh reply opens there too.
    func clearSuggestedReply(threadID: String, inWindow: Bool = false) {
        guard let thread = (threads + targetThreads).first(where: { $0.threadID == threadID }) else { return }
        try? store.dismissAutoDraft(threadID: threadID)
        reloadOutbox()
        Task {
            guard let fresh = await prepareDraft(.reply, thread: thread) else { return }
            if Platform.isMac && !inWindow { inlineDrafts[threadID] = fresh } else { openComposeWindow?(fresh) }
        }
    }

    /// Pop Out: the inline reply moves to its own window (same draft, nothing lost).
    func popOutInlineDraft(threadID: String) {
        guard let id = inlineDrafts.removeValue(forKey: threadID) else { return }
        openComposeWindow?(id)
    }

    /// Builds and stores a reply/forward draft for a conversation without opening it.
    func prepareDraft(_ kind: ComposeKind, thread: ThreadSummary, account: AccountConfig? = nil) async -> Int64? {
        guard let account = account ?? accounts.first(where: { $0.id == thread.latest.accountID }) else { return nil }
        let original = messages(inThread: thread.threadID).filter { $0.accountID == account.id }.last ?? thread.latest
        do {
            let raw = try await rawMessage(original)
            let parsed = MIMEParser.parse(raw)
            let draft = Self.draft(kind, replyingTo: parsed, raw: raw, account: account)
            return saveDraft(draft.message, body: draft.body, accountID: account.id, kind: kind, originalLocalID: original.id)
        } catch {
            lastError = String(localized: "Couldn't open the original message: \(String(describing: error))")
            return nil
        }
    }

    private func openDraft(_ message: OutgoingMessage, body: NSAttributedString, accountID: String, kind: ComposeKind, originalLocalID: Int64?) {
        if let id = saveDraft(message, body: body, accountID: accountID, kind: kind, originalLocalID: originalLocalID) {
            openComposeWindow?(id)
        }
    }

    /// Stores a draft (with the editor's rich text) without opening it. Returns its outbox id.
    func saveDraft(_ message: OutgoingMessage, body: NSAttributedString, accountID: String, kind: ComposeKind, originalLocalID: Int64?) -> Int64? {
        var message = message
        message.editorState = try? body.data(from: NSRange(location: 0, length: body.length),
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        message.text = MailBodyConverter.plainText(body)
        do {
            let item = try store.save(OutboxItem(accountID: accountID, message: message, state: .draft,
                                                 kind: kind, originalLocalID: originalLocalID))
            return item.id
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    // MARK: Instant Intro

    /// "Anna, meet Bob" → reply to Bob (and anyone Cc'd), Anna moved to Bcc, opening with a thank-you.
    func replyToIntroduction(thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first,
              let account = accounts.first(where: { $0.id == thread.latest.accountID }) else { return }
        let original = messages(inThread: thread.threadID).filter { $0.accountID == account.id }.last ?? thread.latest
        Task {
            do {
                let raw = try await rawMessage(original)
                let parsed = MIMEParser.parse(raw)
                guard let plan = IntroReply.plan(for: parsed, ownAddresses: ownAddresses) else {
                    show(Toast(message: String(localized: "There's nobody besides the sender to reply to."), symbol: "person.2.slash"))
                    return
                }
                var draft = Self.draft(.replyAll, replyingTo: parsed, raw: raw, account: account)
                draft.message.to = plan.to
                draft.message.cc = plan.cc
                draft.message.bcc = plan.bcc
                let thanks = NSMutableAttributedString(
                    string: String(localized: "Thanks, \(IntroReply.firstName(plan.introducer)) (moved to Bcc)!"),
                    attributes: RichTextEditor.baseAttributes)
                thanks.append(draft.body)
                openDraft(draft.message, body: thanks, accountID: account.id, kind: .replyAll, originalLocalID: original.id)
            } catch {
                lastError = String(localized: "Couldn't open the original message: \(String(describing: error))")
            }
        }
    }

    /// Builds recipients, subject, threading headers and the quoted body.
    static func draft(_ kind: ComposeKind, replyingTo parsed: ParsedMessage, raw: Data, account: AccountConfig)
        -> (message: OutgoingMessage, body: NSAttributedString) {
        let identity = account.identity(replyingTo: parsed)
        let mine = Set(account.sendingIdentities.map { $0.address.lowercased() } + account.addresses.map { $0.lowercased() })
        let sender = parsed.replyTo.isEmpty ? parsed.from : parsed.replyTo
        let sentByMe = parsed.from.contains { mine.contains($0.address.lowercased()) }

        var to: [MailAddress] = []
        var cc: [MailAddress] = []
        switch kind {
        case .reply:
            to = sentByMe ? parsed.to : sender
        case .replyAll:
            to = sentByMe ? parsed.to : sender + parsed.to
            cc = parsed.cc
        case .forward, .new:
            break
        }
        var seen = Set<String>()
        func unique(_ list: [MailAddress]) -> [MailAddress] {
            list.filter { !mine.contains($0.address.lowercased()) && seen.insert($0.address.lowercased()).inserted }
        }
        to = unique(to)
        cc = unique(cc)

        let subject = kind == .forward ? prefixed(parsed.subject, "Fwd:", existing: ["fwd:", "fw:", "vs:", "wg:"])
                                       : prefixed(parsed.subject, "Re:", existing: ["re:", "sv:", "aw:"])
        var references = parsed.references
        if let id = parsed.messageID, !references.contains(id) { references.append(id) }

        let body = NSMutableAttributedString(string: "\n\n", attributes: RichTextEditor.baseAttributes)
        if !identity.signature.isEmpty {
            body.append(ComposeModel.signatureBlock(identity.signature))
            body.append(NSAttributedString(string: "\n\n", attributes: RichTextEditor.baseAttributes))
        }
        let who = parsed.from.first.map { $0.name ?? $0.address } ?? ""
        let when = parsed.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        let header = kind == .forward
            ? String(localized: "---------- Forwarded message ----------\nFrom: \(parsed.from.map(\.description).joined(separator: ", "))\nDate: \(when)\nSubject: \(parsed.subject)\nTo: \(parsed.to.map(\.description).joined(separator: ", "))\n\n")
            : String(localized: "On \(when), \(who) wrote:\n")
        body.append(NSAttributedString(string: header, attributes: RichTextEditor.baseAttributes))
        let quotedText = parsed.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        body.append(NSAttributedString(string: quotedText,
                                       attributes: kind == .forward ? RichTextEditor.baseAttributes : RichTextEditor.quoteAttributes))

        let message = OutgoingMessage(
            from: identity.mailAddress, to: to, cc: cc, subject: subject, text: "",
            attachments: kind == .forward ? MIMEParser.attachments(in: raw).filter { $0.contentID == nil } : [],
            inReplyTo: kind == .forward ? nil : parsed.messageID,
            references: kind == .forward ? [] : references
        )
        return (message, body)
    }

    static func prefixed(_ subject: String, _ prefix: String, existing: [String]) -> String {
        let lower = subject.lowercased()
        return existing.contains(where: { lower.hasPrefix($0) }) ? subject : "\(prefix) \(subject)"
    }

    // MARK: Sending

    func send(_ message: OutgoingMessage, accountID: String, sendAt: Date?, kind: ComposeKind,
              originalLocalID: Int64?, draftID: Int64, markDone: Bool = false) async throws {
        guard let sync = syncs[accountID] else { throw MailSessionError.commandFailed(command: "send", detail: "account is offline") }
        let item = try await sync.queue(message, sendAt: sendAt, kind: kind, originalLocalID: originalLocalID, replacingDraft: draftID)
        reloadOutbox()
        // Sending later: the push server sends it even with every device asleep (ADR 0007).
        if sendAt != nil { handOffToPushServer(item) }

        // Answering takes the conversation off the Reply Later pile, and (Send and Done) out of the Inbox.
        var boxes: [ChangeBox] = []
        var markedDone = false
        if kind == .reply || kind == .replyAll, let originalLocalID,
           let original = try? store.message(id: originalLocalID), let threadID = original.threadID {
            if messages(inThread: threadID).contains(where: { $0.flags.contains(replyLaterKeyword) }) {
                boxes.append(performQuietly(.clearReplyLater, threadID: threadID, accountID: accountID))
            }
            if markDone, messages(inThread: threadID).contains(where: { $0.mailbox == "INBOX" }) {
                boxes.append(performQuietly(.done, threadID: threadID, accountID: accountID))
                markedDone = true
            }
        }

        if sendAt == nil, accountErrors[accountID] != nil {
            // It can't go out until this account connects: no "Sending…" that never ends.
            let name = accounts.first { $0.id == accountID }?.displayName ?? ""
            show(Toast(message: String(localized: "Not sent yet: can't connect to \(name). It's waiting in the Outbox."),
                       symbol: "exclamationmark.triangle", undoSend: item.id))
        } else if let id = item.id, sendAt == nil {
            let allBoxes = boxes
            if markedDone {
                let undo: @MainActor () -> Void = { [weak self] in
                    self?.undoSend(id)
                    allBoxes.forEach { self?.undo(box: $0) }
                }
                let undoToken = offerUndo(named: String(localized: "Send and Done"), undo)
                show(Toast(message: String(localized: "Sending… and marked done"), symbol: "paperplane", undo: undoToken))
            } else {
                show(Toast(message: String(localized: "Sending…"), symbol: "paperplane", undoSend: id))
            }
        } else if let sendAt {
            show(Toast(message: String(localized: "Will send \(sendAt.formatted(.dateTime.weekday(.wide).hour().minute()))"),
                       symbol: "clock", undoSend: item.id))
        }
    }

    /// Undo send: takes the message back and reopens it.
    func undoSend(_ outboxID: Int64) {
        guard let item = try? store.outboxItem(id: outboxID), let sync = syncs[item.accountID] else { return }
        Task {
            // Handed to the push server: it has to let go first.
            if item.state == .remote, await !takeBackFromPushServer(outboxID) {
                show(Toast(message: String(localized: "Too late, it's already sent"), symbol: "paperplane"))
                return
            }
            if let draft = try? await sync.cancelSend(id: outboxID), let id = draft.id {
                toast = nil
                reloadOutbox()
                openComposeWindow?(id)
            } else {
                show(Toast(message: String(localized: "Too late, it's already sent"), symbol: "paperplane"))
            }
        }
    }

    func retrySend(_ outboxID: Int64) {
        guard let item = try? store.outboxItem(id: outboxID), let sync = syncs[item.accountID] else { return }
        Task { try? await sync.retrySend(id: outboxID); reloadOutbox() }
    }

    func editQueued(_ outboxID: Int64) { undoSend(outboxID) }

    func deleteOutboxItem(_ outboxID: Int64) {
        if let item = try? store.outboxItem(id: outboxID), item.state == .remote {
            Task {
                guard await takeBackFromPushServer(outboxID) else {
                    show(Toast(message: String(localized: "Too late, it's already sent"), symbol: "paperplane"))
                    return
                }
                try? store.deleteOutboxItem(id: outboxID)
                reloadOutbox()
            }
            return
        }
        try? store.deleteOutboxItem(id: outboxID)
        reloadOutbox()
    }

    func reloadOutbox() {
        outboxItems = (try? store.outbox()) ?? []
        draftItems = (try? store.drafts()) ?? []
        autoDrafts = (try? store.pendingAutoDrafts()) ?? []
    }

    func suggestions(for query: String) -> [MailAddress] {
        let last = query.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard last.count >= 2 else { return [] }
        return (try? store.contacts(matching: last)) ?? []
    }
}
