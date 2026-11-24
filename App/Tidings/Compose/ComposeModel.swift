import Foundation
import MailEngine
import SwiftUI
import Observation

/// One composer window's state. Autosaves to the outbox table as a draft.
@MainActor @Observable
final class ComposeModel {
    let draftID: Int64
    var accountID: String
    var identity: Identity { didSet { if identity != oldValue { swapSignature(from: oldValue) } } }
    var to = ""
    var cc = ""
    var bcc = ""
    var showCcBcc = false
    var subject = ""
    var body = NSAttributedString()
    var attachments: [OutgoingAttachment] = []
    var kind: ComposeKind = .new
    var originalLocalID: Int64?
    var inReplyTo: String?
    var references: [String] = []
    var error: String?
    var isDirty = false

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
        if let rtf = message.editorState,
           let restored = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            body = restored
        } else {
            body = NSAttributedString(string: message.text, attributes: RichTextEditor.baseAttributes)
        }
    }

    var availableIdentities: [Identity] { app?.identities(for: accountID) ?? [identity] }

    var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    // MARK: Building

    func recipients(_ field: String) -> [MailAddress] {
        AddressParser.parse(field.replacingOccurrences(of: ";", with: ","))
    }

    func buildMessage() -> OutgoingMessage {
        var message = OutgoingMessage(
            from: identity.mailAddress, to: recipients(to), cc: recipients(cc), bcc: recipients(bcc),
            subject: subject, text: MailBodyConverter.plainText(body), html: MailBodyConverter.html(body),
            attachments: attachments, inReplyTo: inReplyTo, references: references
        )
        message.editorState = try? body.data(from: NSRange(location: 0, length: body.length),
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        return message
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
    func send(at sendAt: Date? = nil) async -> Bool {
        if let problem = validationError() { error = problem; return false }
        saveTask?.cancel()
        guard let app else { return false }
        do {
            try await app.send(buildMessage(), accountID: accountID, sendAt: sendAt, kind: kind,
                               originalLocalID: originalLocalID, draftID: draftID)
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
