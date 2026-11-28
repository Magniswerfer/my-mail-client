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
            if let owner = app?.accountID(sending: identity, preferring: accountID) { accountID = owner }
            applyAutomaticSignature(force: true)
        }
    }
    /// The signature in the text (nil: none, or an old plain-text one).
    private(set) var signatureID: String?
    /// Picked by hand (menu, ⌘K) or deleted from the text: rules leave it alone from then on.
    @ObservationIgnored var signatureChosenByHand = false
    /// Who the rules last saw it going to.
    @ObservationIgnored private var signatureRecipients: [String] = []
    /// The composer's appearance: the signature's picture is drawn for it.
    @ObservationIgnored var isDark = false {
        didSet { if isDark != oldValue { refreshSignatureImage() } }
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
    /// Whether you've changed anything since it opened (isDirty resets on every save).
    @ObservationIgnored var wasEdited = false
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
        // A signature's images are added when it's sent, never kept as attachments.
        attachments = message.attachments.filter { $0.contentID?.hasPrefix(SignatureImage.contentIDPrefix) != true }
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
        signatureID = Self.signatureRange(in: body)?.id
        signatureRecipients = signatureRecipientAddresses
        refreshSignatureImage()
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
        let signatures = app?.signaturesByID ?? [:]
        let full = fullBody   // put together once (it copies the folded quote in)
        var message = OutgoingMessage(
            from: identity.mailAddress, to: recipients(to), cc: recipients(cc), bcc: recipients(bcc),
            subject: subject, text: MailBodyConverter.plainText(full, signatures: signatures),
            html: MailBodyConverter.html(full, signatures: signatures),
            attachments: attachments, inReplyTo: inReplyTo, references: references
        )
        // The signature's embedded images go along as parts its HTML points at.
        message.addSignatureImages(Array(signatures.values))
        message.editorState = EditorArchive.data(full)
        return message
    }

    /// What goes out: what you wrote, and the folded quote under it.
    var fullBody: NSAttributedString {
        guard let foldedQuote else { return body }
        let full = NSMutableAttributedString(attributedString: body)
        full.append(foldedQuote)
        return full
    }

    /// Where the quoted (or forwarded) part of a text starts, if it has one.
    static func quoteStart(in text: NSAttributedString) -> Int? {
        var start: Int?
        text.enumerateAttribute(.tidingsQuotedReply, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if value != nil { start = range.location; stop.pointee = true }
        }
        return start
    }

    /// Takes a reply's quote out of the editor (it ends the text); "•••" brings it back.
    private func foldQuotedReply() {
        guard kind == .reply || kind == .replyAll, body.length > 0, let start = Self.quoteStart(in: body) else { return }
        foldedQuote = body.attributedSubstring(from: NSRange(location: start, length: body.length - start))
        body = body.attributedSubstring(from: NSRange(location: 0, length: start))
    }

    /// Forward after Reply (or back): becomes the other kind. What you wrote stays; recipients,
    /// subject and the quoted part are the new kind's (a forward starts with no one in To).
    func adopt(_ conversion: InlineConversion) {
        let typedEnd = foldedQuote != nil ? body.length : (Self.quoteStart(in: body) ?? body.length)
        let combined = NSMutableAttributedString(attributedString: body.attributedSubstring(from: NSRange(location: 0, length: typedEnd)))
        if let start = Self.quoteStart(in: conversion.body) {
            combined.append(conversion.body.attributedSubstring(from: NSRange(location: start, length: conversion.body.length - start)))
        }
        let message = conversion.message
        kind = conversion.kind
        to = message.to.map(\.description).joined(separator: ", ")
        cc = message.cc.map(\.description).joined(separator: ", ")
        showCcBcc = !cc.isEmpty || !bcc.isEmpty
        subject = message.subject
        inReplyTo = message.inReplyTo
        references = message.references
        originalLocalID = conversion.originalLocalID
        if kind == .forward {
            for attachment in message.attachments where !attachments.contains(where: { $0.filename == attachment.filename && $0.data == attachment.data }) {
                attachments.append(attachment)
            }
        }
        foldedQuote = nil
        body = combined
        foldQuotedReply()
        changed()
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
        return SendCheck.problems(text: MailBodyConverter.plainText(body, signatures: app?.signaturesByID ?? [:]),
                                  attachmentCount: attachments.count,
                                  recipients: recipients(to) + recipients(cc) + recipients(bcc),
                                  conversationPeople: people, ownAddresses: app?.ownAddresses ?? [])
    }

    func add(_ person: MailAddress) {
        to = to.trimmingCharacters(in: .whitespaces).isEmpty ? person.description : "\(to), \(person.description)"
        changed()
    }

    // MARK: Saving

    func changed() {
        noticeSignatureChanges()
        isDirty = true
        wasEdited = true
        app?.editedDrafts.insert(draftID)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // Saved now: the debounced save still waiting would only build and write it again.
        saveTask?.cancel()
        saveTask = nil
        guard let app, var item = try? app.store.outboxItem(id: draftID), item.state == .draft else { return }
        item.message = buildMessage()
        item.accountID = accountID
        item.kind = kind
        item.originalLocalID = originalLocalID
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

    /// Where the signature is in a text, and which one (nil id: an old plain-text signature).
    static func signatureRange(in text: NSAttributedString) -> (range: NSRange, id: String?)? {
        var found: (range: NSRange, id: String?)?
        text.enumerateAttribute(.tidingsSignature, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let value else { return }
            found = (range, value as? String)
            stop.pointee = true
        }
        return found
    }

    private var signatureRecipientAddresses: [String] {
        (recipients(to) + recipients(cc) + recipients(bcc)).map { $0.address.lowercased() }
    }

    /// The signature the rules pick for this message now, unless you chose one yourself.
    /// `force`: also when the recipients haven't changed (another From address).
    func applyAutomaticSignature(force: Bool = false) {
        let addresses = signatureRecipientAddresses
        guard force || addresses != signatureRecipients else { return }
        signatureRecipients = addresses
        guard !signatureChosenByHand, let app else { return }
        let chosen = app.chooseSignature(from: identity, kind: kind, recipients: recipients(to) + recipients(cc) + recipients(bcc))
        let current = Self.signatureRange(in: body)
        if let current, current.id == chosen?.id { return }           // already the right one
        if current == nil, chosen == nil { return }
        if let current, current.id == nil, chosen == nil { return }   // an old plain-text one stays
        replaceSignature(with: chosen)
    }

    /// The menu or ⌘K: this signature (nil: none) for this message, whatever the rules say.
    func useSignature(_ id: String?) {
        signatureChosenByHand = true
        replaceSignature(with: app?.signature(id: id))
    }

    /// Typing: a signature you deleted from the text stays deleted; new recipients may pick
    /// another one.
    private func noticeSignatureChanges() {
        if signatureID != nil, Self.signatureRange(in: body) == nil {
            signatureID = nil
            signatureChosenByHand = true
        }
        applyAutomaticSignature()
    }

    /// Puts `signature` where the old one was; with none there, at the end of what you wrote
    /// (above a reply's or forward's quote).
    private func replaceSignature(with signature: Signature?) {
        let mutable = NSMutableAttributedString(attributedString: body)
        let block = signature.map { Self.signatureBlock($0, dark: isDark) } ?? NSAttributedString()
        if let found = Self.signatureRange(in: mutable) {
            var range = found.range
            if signature == nil, range.location > 0, (mutable.string as NSString).character(at: range.location - 1) == 10 {
                range = NSRange(location: range.location - 1, length: range.length + 1)   // its line too
            }
            mutable.replaceCharacters(in: range, with: block)
        } else if signature != nil {
            let insertAt = Self.quoteStart(in: mutable) ?? mutable.length
            let piece = NSMutableAttributedString(string: "\n", attributes: RichTextEditor.baseAttributes)
            piece.append(block)
            if insertAt < mutable.length { piece.append(NSAttributedString(string: "\n\n", attributes: RichTextEditor.baseAttributes)) }
            mutable.insert(piece, at: insertAt)
        }
        body = mutable
        signatureID = signature?.id
        refreshSignatureImage()
        isDirty = true
        wasEdited = true
        app?.editedDrafts.insert(draftID)
        scheduleSave()
    }

    /// Gives the signature in the text its picture (drawn now if it isn't yet).
    func refreshSignatureImage() {
        guard let app, let found = Self.signatureRange(in: body), let id = found.id, let signature = app.signature(id: id) else { return }
        let dark = isDark
        if let image = SignatureRenderer.shared.cachedImage(signature, dark: dark) {
            setSignatureImage(image, id: id)
            return
        }
        Task { [weak self] in
            guard let image = await SignatureRenderer.shared.image(signature, dark: dark), self?.isDark == dark else { return }
            self?.setSignatureImage(image, id: id)
        }
    }

    private func setSignatureImage(_ image: PlatformImage, id: String) {
        guard let found = Self.signatureRange(in: body), found.id == id else { return }
        let current = body.attribute(.attachment, at: found.range.location, effectiveRange: nil) as? NSTextAttachment
        guard current?.image !== image else { return }
        // A new attachment, so the editor sees a change and lays the picture out again.
        let mutable = NSMutableAttributedString(attributedString: body)
        let fresh = NSTextAttachment()
        Self.setImage(image, on: fresh)
        mutable.addAttribute(.attachment, value: fresh, range: NSRange(location: found.range.location, length: 1))
        body = mutable
    }

    /// The name of the signature in use, for the composer's menu.
    var signatureMenuTitle: String {
        app?.signature(id: signatureID)?.name ?? String(localized: "No Signature")
    }

    /// Signatures to choose from in the composer.
    var availableSignatures: [Signature] { app?.signatures ?? [] }
}

import UniformTypeIdentifiers

/// Forward after Reply (or back) on an open inline reply: the new kind's draft, for the open
/// composer to take on (`ComposeModel.adopt`).
struct InlineConversion: Equatable {
    let id = UUID()
    var kind: ComposeKind
    var message: OutgoingMessage
    var body: NSAttributedString
    var originalLocalID: Int64?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

