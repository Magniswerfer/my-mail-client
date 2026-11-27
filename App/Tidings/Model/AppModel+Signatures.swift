import Foundation
import MailEngine
import SwiftUI

/// HTML signatures: kept in the store (they sync through iCloud), picked per address, per new
/// mail or reply, and by recipient rules.
extension AppModel {
    func loadSignatures() {
        adoptPlainTextSignatures()
        signatures = (try? store.signatures()) ?? []
        signatureSettings = (try? store.signatureSettings()) ?? SignatureSettings()
        SignatureRenderer.shared.prerender(signatures)
    }

    /// The plain-text signatures identities had before HTML signatures: each becomes a
    /// signature and its address's default, once. The identity's own text is then cleared so a
    /// signature you delete doesn't come back from it.
    private func adoptPlainTextSignatures() {
        let identities = accounts.flatMap(\.sendingIdentities).filter { !$0.signature.isEmpty }
        guard !identities.isEmpty else { return }
        _ = try? store.adoptPlainTextSignatures(identities)
        for index in accounts.indices {
            accounts[index].identities = accounts[index].identities?.map { var i = $0; i.signature = ""; return i }
        }
        persistAccounts()
    }

    var signaturesByID: [String: Signature] { Dictionary(signatures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    func signature(id: String?) -> Signature? { id.flatMap { id in signatures.first { $0.id == id } } }

    /// The signature rules pick for a message from this address.
    func chooseSignature(from identity: Identity, kind: ComposeKind, recipients: [MailAddress]) -> Signature? {
        signature(id: signatureSettings.choose(from: identity.address, kind: kind, recipients: recipients.map(\.address)))
    }

    // MARK: Changing them

    func saveSignature(_ signature: Signature) {
        if let index = signatures.firstIndex(where: { $0.id == signature.id }) {
            signatures[index] = signature
        } else {
            signatures.append(signature)
        }
        persistSignatures()
        SignatureRenderer.shared.prerender([signature])
    }

    func deleteSignature(_ signature: Signature) {
        signatures.removeAll { $0.id == signature.id }
        signatureSettings.forget(signatureID: signature.id)
        persistSignatures()
        persistSignatureSettings()
    }

    func moveSignatures(from source: IndexSet, to destination: Int) {
        signatures.move(fromOffsets: source, toOffset: destination)
        persistSignatures()
    }

    func duplicateSignature(_ signature: Signature) -> Signature {
        var copy = signature
        copy.id = UUID().uuidString
        copy.name = String(localized: "\(signature.name) Copy")
        saveSignature(copy)
        return copy
    }

    func updateSignatureSettings(_ change: (inout SignatureSettings) -> Void) {
        change(&signatureSettings)
        persistSignatureSettings()
    }

    private func persistSignatures() {
        do { try store.saveSignatures(signatures) } catch { lastError = String(describing: error) }
        scheduleCloudPush()
    }

    private func persistSignatureSettings() {
        do { try store.saveSignatureSettings(signatureSettings) } catch { lastError = String(describing: error) }
        scheduleCloudPush()
    }

    // MARK: Opening the window

    /// Mac: the Signatures window; iPhone and iPad: its sheet. `editing`: open on that one.
    func showSignatures(editing id: String? = nil) {
        signatureToEdit = id
        isSignaturesShown = true
    }

    func newSignature() {
        let signature = Signature(name: String(localized: "New Signature"),
                                  html: "<p>\(SignatureHTML.escape(Platform.fullUserName))</p>")
        saveSignature(signature)
        showSignatures(editing: signature.id)
    }

    /// iPhone and iPad (and the Mac): a signature from rich text or HTML you copied.
    func pasteSignatureFromClipboard() {
        guard let html = SignaturePasteboard.html() else {
            show(Toast(message: String(localized: "There's no formatted text on the clipboard."), symbol: "doc.on.clipboard"))
            return
        }
        let extracted = SignatureHTML.extractingImages(SignatureHTML.sanitize(html))
        let signature = Signature(name: String(localized: "Pasted Signature"), html: extracted.html, images: extracted.images)
        saveSignature(signature)
        showSignatures(editing: signature.id)
    }

    // MARK: ⌘K

    /// Choosing the signature of the message you're writing.
    var signatureCommands: [AppCommand] {
        var list = [
            AppCommand(id: "signatures", title: String(localized: "Edit Signatures…"), symbol: "signature", keys: nil) { self.showSignatures() },
            AppCommand(id: "newSignature", title: String(localized: "New Signature…"), symbol: "plus.rectangle.on.rectangle", keys: nil) {
                self.newSignature()
            },
        ]
        guard let composer = activeComposer else { return list }
        list.append(AppCommand(id: "signature-none", title: String(localized: "No Signature"), symbol: "xmark.rectangle",
                               keys: nil, isEnabled: composer.signatureID != nil) { composer.useSignature(nil) })
        for signature in signatures {
            list.append(AppCommand(id: "signature-\(signature.id)", title: String(localized: "Use Signature “\(signature.name)”"),
                                   symbol: "signature", keys: nil, isEnabled: composer.signatureID != signature.id) {
                composer.useSignature(signature.id)
            })
        }
        return list
    }
}

/// HTML from the clipboard: rich text you copied (a web page, Mail, Pages) or HTML source.
enum SignaturePasteboard {
    @MainActor static func html() -> String? {
        #if os(macOS)
        let board = NSPasteboard.general
        if let html = board.string(forType: .html), !html.isEmpty { return html }
        if let data = board.data(forType: .rtf) ?? board.data(forType: .rtfd),
           let text = NSAttributedString(rtf: data, documentAttributes: nil) { return htmlFromAttributed(text) }
        if let text = board.string(forType: .string), text.contains("<"), text.contains(">") { return text }
        #else
        let board = UIPasteboard.general
        if let data = board.data(forPasteboardType: "public.html"), let html = String(data: data, encoding: .utf8) { return html }
        if let data = board.data(forPasteboardType: "public.rtf"),
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return htmlFromAttributed(text)
        }
        if let text = board.string, text.contains("<"), text.contains(">") { return text }
        #endif
        return nil
    }

    static func htmlFromAttributed(_ text: NSAttributedString) -> String? {
        guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
