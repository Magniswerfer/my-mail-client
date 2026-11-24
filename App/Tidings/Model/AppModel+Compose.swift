import Foundation
import MailEngine
import SwiftUI

extension AppModel {
    // MARK: Identities

    func identities(for accountID: String) -> [Identity] {
        accounts.first { $0.id == accountID }?.sendingIdentities ?? []
    }

    var defaultAccount: AccountConfig? { accounts.first }

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
    func persistAccounts() {
        if !isDevServer { AccountStorage.save(accounts) }
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
        let original = messages(inThread: thread.threadID).filter { $0.accountID == account.id }.last ?? thread.latest
        Task {
            do {
                let raw = try await rawMessage(original)
                let parsed = MIMEParser.parse(raw)
                let draft = Self.draft(kind, replyingTo: parsed, raw: raw, account: account)
                openDraft(draft.message, body: draft.body, accountID: account.id, kind: kind, originalLocalID: original.id)
            } catch {
                lastError = String(localized: "Couldn't open the original message: \(String(describing: error))")
            }
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
              originalLocalID: Int64?, draftID: Int64) async throws {
        guard let sync = syncs[accountID] else { throw MailSessionError.commandFailed(command: "send", detail: "account is offline") }
        let item = try await sync.queue(message, sendAt: sendAt, kind: kind, originalLocalID: originalLocalID, replacingDraft: draftID)
        reloadOutbox()
        if let id = item.id, sendAt == nil {
            show(Toast(message: String(localized: "Sending…"), symbol: "paperplane", undoSend: id))
        } else if let sendAt {
            show(Toast(message: String(localized: "Will send \(sendAt.formatted(.dateTime.weekday(.wide).hour().minute()))"),
                       symbol: "clock", undoSend: item.id))
        }
    }

    /// Undo send: takes the message back and reopens it.
    func undoSend(_ outboxID: Int64) {
        guard let item = try? store.outboxItem(id: outboxID), let sync = syncs[item.accountID] else { return }
        Task {
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
