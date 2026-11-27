import Foundation
import MailEngine
import SwiftUI
import Observation

/// One composer window's state. Autosaves to the outbox table as a draft.
@MainActor @Observable
final class ComposeModel {
    let draftID: Int64
    var accountID: String
    /// Picking an address of another account sends through that account (its SMTP server,
    /// its Sent folder).
    var identity: Identity {
        didSet {
            guard identity != oldValue else { return }
            swapSignature(from: oldValue)
            if let owner = app?.accountID(sending: identity, preferring: accountID) { accountID = owner }
        }
    }
    var to = ""
    var cc = ""
    var bcc = ""
    var showCcBcc = false
    var subject = ""
    var body = NSAttributedString()
    /// A reply's quoted mail, out of the editor until you click "•••" (it's sent either way).
    var foldedQuote: NSAttributedString?
    var attachments: [OutgoingAttachment] = []
    var kind: ComposeKind = .new
    var originalLocalID: Int64?
    var inReplyTo: String?
    var references: [String] = []
    var error: String?
    var isDirty = false
    /// Text waiting to go in at the caret (Share Availability).
    var insertion: TextInsertion?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// iCloud's per-message limit (Mail Drop is Apple-only).
    static let sizeLimit = 20 * 1_048_576

    init?(draftID: Int64, app: AppModel) {
        guard let item = try? app.store.outboxItem(id: draftID), let message = item.message else { return nil }
        self.draftID = draftID
        self.app = app
        accountID = item.accountID
        let identities = app.identities(for: item.accountID)
        identity = identities.first { $0.address.caseInsensitiveCompare(message.from.address) == .orderedSame }
            ?? Identity(address: message.from.address, name: message.from.name ?? "")
        to = message.to.map(\.description).joined(separator: ", ")
        cc = message.cc.map(\.description).joined(separator: ", ")
        bcc = message.bcc.map(\.description).joined(separator: ", ")
        showCcBcc = !cc.isEmpty || !bcc.isEmpty
        subject = message.subject
        attachments = message.attachments
        kind = item.kind
        originalLocalID = item.originalLocalID
        inReplyTo = message.inReplyTo
        references = message.references
        if let saved = message.editorState, let restored = EditorArchive.restore(saved) {
            body = restored
        } else {
            body = NSAttributedString(string: message.text, attributes: RichTextEditor.baseAttributes)
        }
        foldQuotedReply()
    }

    /// Every address of every account (this draft's account first).
    var availableIdentities: [Identity] {
        guard let app else { return [identity] }
        let own = app.identities(for: accountID)
        let others = app.accounts.filter { $0.id != accountID }.flatMap(\.sendingIdentities)
            .filter { other in !own.contains { $0.id == other.id } }
        let all = own + others
        return all.contains(identity) ? all : [identity] + all
    }

    /// The From menu in sections per account, when there's more than one.
    var identitySections: [(account: String, identities: [Identity])] {
        guard let app, app.accounts.count > 1 else { return [("", availableIdentities)] }
        let available = availableIdentities
        return app.accounts.compactMap { account in
            let mine = available.filter { identity in account.sendingIdentities.contains { $0.id == identity.id } }
            return mine.isEmpty ? nil : (account.displayName, mine)
        }
    }

    var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    // MARK: Building

    func recipients(_ field: String) -> [MailAddress] {
        AddressParser.parse(field.replacingOccurrences(of: ";", with: ","))
    }

    func buildMessage() -> OutgoingMessage {
        var message = OutgoingMessage(
            from: identity.mailAddress, to: recipients(to), cc: recipients(cc), bcc: recipients(bcc),
            subject: subject, text: MailBodyConverter.plainText(fullBody), html: MailBodyConverter.html(fullBody),
            attachments: attachments, inReplyTo: inReplyTo, references: references
        )
        message.editorState = EditorArchive.data(fullBody)
        return message
    }

    /// What goes out: what you wrote, and the folded quote under it.
    var fullBody: NSAttributedString {
        guard let foldedQuote else { return body }
        let full = NSMutableAttributedString(attributedString: body)
        full.append(foldedQuote)
        return full
    }

    /// Takes a reply's quote out of the editor (it ends the text); "•••" brings it back.
    private func foldQuotedReply() {
        guard kind == .reply || kind == .replyAll, body.length > 0 else { return }
        var start: Int?
        body.enumerateAttribute(.tidingsQuotedReply, in: NSRange(location: 0, length: body.length)) { value, range, stop in
            if value != nil { start = range.location; stop.pointee = true }
        }
        guard let start else { return }
        foldedQuote = body.attributedSubstring(from: NSRange(location: start, length: body.length - start))
        body = body.attributedSubstring(from: NSRange(location: 0, length: start))
    }

    /// "•••": the quoted mail back in the editor, to edit or trim.
    func unfoldQuote() {
        guard foldedQuote != nil else { return }
        body = fullBody
        foldedQuote = nil
        changed()
    }

    /// Problems that block sending, in plain words.
    func validationError() -> String? {
        let all = recipients(to) + recipients(cc) + recipients(bcc)
        if all.isEmpty { return String(localized: "Add at least one recipient.") }
        let typed = [to, cc, bcc].flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        if typed.count != all.count || all.contains(where: { !$0.address.contains("@") || $0.address.contains(" ") }) {
            return String(localized: "One of the addresses doesn't look right.")
        }
        if attachmentBytes > Self.sizeLimit {
            return String(localized: "Attachments are over iCloud's 20 MB limit. Share large files with a link instead.")
        }
        return nil
    }

    /// Forgotten attachment, or someone you named who's no longer on the message.
    func sendProblems() -> [SendCheck.Problem] {
        var people: [MailAddress] = []
        if let id = originalLocalID, let original = try? app?.store.message(id: id) {
            people = [MailAddress(name: original.fromName, address: original.fromAddress)] + AddressParser.parse(original.recipients)
        }
        return SendCheck.problems(text: MailBodyConverter.plainText(body), attachmentCount: attachments.count,
                                  recipients: recipients(to) + recipients(cc) + recipients(bcc),
                                  conversationPeople: people, ownAddresses: app?.ownAddresses ?? [])
    }

    func add(_ person: MailAddress) {
        to = to.trimmingCharacters(in: .whitespaces).isEmpty ? person.description : "\(to), \(person.description)"
        changed()
    }

    // MARK: Saving

    func changed() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let app, var item = try? app.store.outboxItem(id: draftID), item.state == .draft else { return }
        item.message = buildMessage()
        item.accountID = accountID
        _ = try? app.store.save(item)
        isDirty = false
    }

    func discard() {
        saveTask?.cancel()
        try? app?.store.deleteOutboxItem(id: draftID)
    }

    /// Queues the message (send now = after the undo window; or at `sendAt`). Returns true when queued.
    /// Replies follow the Send and Done setting; `markDone` overrides it (⌥⌘↩ sends the other way).
    var isReply: Bool { kind == .reply || kind == .replyAll }

    func send(at sendAt: Date? = nil, markDone: Bool? = nil) async -> Bool {
        if let problem = validationError() { error = problem; return false }
        saveTask?.cancel()
        guard let app else { return false }
        do {
            try await app.send(buildMessage(), accountID: accountID, sendAt: sendAt, kind: kind,
                               originalLocalID: originalLocalID, draftID: draftID,
                               markDone: isReply && (markDone ?? AssistSettings.sendAndDone))
            return true
        } catch {
            self.error = String(describing: error)
            return false
        }
    }

    // MARK: Attachments

    func attach(urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
        changed()
    }

    // MARK: Signature

    /// Replaces the old identity's signature block with the new one's.
    private func swapSignature(from old: Identity) {
        let mutable = NSMutableAttributedString(attributedString: body)
        var found: NSRange?
        mutable.enumerateAttribute(.tidingsSignature, in: NSRange(location: 0, length: mutable.length)) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        let block = Self.signatureBlock(identity.signature)
        if let found { mutable.replaceCharacters(in: found, with: block) } else if !identity.signature.isEmpty { mutable.append(block) }
        body = mutable
        changed()
    }

    static func signatureBlock(_ signature: String) -> NSAttributedString {
        guard !signature.isEmpty else { return NSAttributedString() }
        var attrs = RichTextEditor.baseAttributes
        attrs[.tidingsSignature] = true
        attrs[.foregroundColor] = PlatformColor.tidingsSecondaryLabel
        return NSAttributedString(string: "\n-- \n\(signature)", attributes: attrs)
    }
}

import UniformTypeIdentifiers
