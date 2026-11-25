import Foundation
import MailEngine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Opening attachments and the attachment browser (SPEC §11). Files come out of the message
/// (cache, else fetched) into a private temporary folder, quarantined like downloads, so
/// macOS checks them before anything runs.
extension AppModel {
    /// Writes the attachment to a temporary file and returns it.
    func fileURL(for info: AttachmentInfo, in message: StoredMessage) async throws -> URL {
        let raw = try await rawMessage(message)
        guard let file = MIMEParser.attachmentFile(info, in: raw) else {
            throw MailSessionError.commandFailed(command: "attachment", detail: "not found in the message")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(message.id ?? 0)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = file.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        try file.data.write(to: url, options: .atomic)
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Tidings",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var quarantined = url
        try? quarantined.setResourceValues(values)
        #endif
        return url
    }

    /// Space / click: Quick Look.
    func preview(_ info: AttachmentInfo, in message: StoredMessage) {
        withAttachment(info, in: message) { url in self.quickLookURL = url }
    }

    /// Opens it in its default app.
    func openAttachment(_ info: AttachmentInfo, in message: StoredMessage) {
        withAttachment(info, in: message) { url in Platform.openExternally(url) }
    }

    /// Save…: asks where.
    func saveAttachment(_ info: AttachmentInfo, in message: StoredMessage) {
        #if os(macOS)
        withAttachment(info, in: message) { url in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let target = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                self.lastError = String(localized: "Couldn't save \(url.lastPathComponent): \(String(describing: error))")
            }
        }
        #endif
    }

    private func withAttachment(_ info: AttachmentInfo, in message: StoredMessage, _ action: @escaping @MainActor (URL) -> Void) {
        Task {
            do {
                action(try await fileURL(for: info, in: message))
            } catch {
                show(Toast(message: String(localized: "Couldn't open \(info.filename ?? "the attachment")"), symbol: "exclamationmark.triangle"))
            }
        }
    }

    /// Background: attachment lists for mail synced before they were kept (cache only).
    func indexAttachmentsInBackground() {
        for sync in syncs.values {
            Task { _ = try? await sync.indexAttachmentsFromCache() }
        }
    }
}

/// The kinds the attachment browser filters by.
enum AttachmentKind: CaseIterable, Hashable {
    case all, images, pdfs, documents, other

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .images: String(localized: "Images")
        case .pdfs: String(localized: "PDFs")
        case .documents: String(localized: "Documents")
        case .other: String(localized: "Other")
        }
    }

    static func of(_ info: AttachmentInfo) -> AttachmentKind {
        let type = UTType(mimeType: info.mimeType)
            ?? info.filename.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        guard let type else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .pdf) { return .pdfs }
        if type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) || type.identifier.contains("officedocument") || type.identifier.contains("microsoft") {
            return .documents
        }
        return .other
    }
}
