import MailEngine
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Every attachment in your mail, newest first (SPEC §11). Space or double-click for Quick Look.
struct AttachmentBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AttachmentEntry] = []
    @State private var kind: AttachmentKind = .all
    @State private var filter = ""
    @State private var selection: AttachmentEntry.ID?

    private var shown: [AttachmentEntry] {
        entries.filter { entry in
            (kind == .all || AttachmentKind.of(entry.info) == kind)
                && (filter.isEmpty || [entry.filename, entry.sender, entry.subject].contains { $0.localizedCaseInsensitiveContains(filter) })
        }
    }

    var body: some View {
        // Filtered once per redraw (each keystroke in the search field), not once per use.
        let shown = self.shown
        NavigationStack {
            List(shown, selection: $selection) { entry in
                AttachmentRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { actions(for: entry) }
            }
            .contextMenu(forSelectionType: AttachmentEntry.ID.self) { _ in } primaryAction: { ids in
                if let entry = entry(ids.first) { preview(entry) }
            }
            .onKeyPress(.space) {
                guard let entry = entry(selection) else { return .ignored }
                preview(entry)
                return .handled
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("No attachments", systemImage: "paperclip",
                                           description: Text("Files people send you show up here."))
                }
            }
            .searchable(text: $filter, placement: .toolbar, prompt: Text("File, sender or subject"))
            .navigationTitle("Attachments")
            .toolbar {
                // A sheet on iPhone needs Close; a Mac window has its own close button.
                if !Platform.isMac {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Kind", selection: $kind) {
                        ForEach(AttachmentKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        .macFrame(minWidth: 720, minHeight: 520)
        .task {
            // Up to 3,000 rows across all your mail: read off the main actor.
            let store = model.store
            entries = await Task.detached(priority: .userInitiated) { (try? store.attachmentEntries()) ?? [] }.value
        }
    }

    private func entry(_ id: AttachmentEntry.ID?) -> AttachmentEntry? {
        id.flatMap { id in entries.first { $0.id == id } }
    }

    private func message(_ entry: AttachmentEntry) -> StoredMessage? {
        try? model.store.message(id: entry.messageLocalID)
    }

    private func preview(_ entry: AttachmentEntry) {
        if let message = message(entry) { model.preview(entry.info, in: message) }
    }

    @ViewBuilder private func actions(for entry: AttachmentEntry) -> some View {
        Button("Quick Look", systemImage: "eye") { preview(entry) }
        Button("Open", systemImage: "arrow.up.forward.app") { if let m = message(entry) { model.openAttachment(entry.info, in: m) } }
        #if os(macOS)
        Button("Save…", systemImage: "square.and.arrow.down") { if let m = message(entry) { model.saveAttachment(entry.info, in: m) } }
        #endif
        Divider()
        Button("Show Conversation", systemImage: "envelope") {
            if let m = message(entry), let url = model.link(for: m) {
                dismiss()
                model.open(url: url)
            }
        }
    }
}

struct AttachmentRow: View {
    let entry: AttachmentEntry

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(info: entry.info).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.filename).font(.headline.weight(.regular)).lineLimit(1)
                Text("\(entry.sender) · \(entry.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.info.size), countStyle: .file))
                    .font(.caption.monospacedDigit())
                Text(MailDate.short(entry.date)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The system's icon for a file type.
struct FileIcon: View {
    let info: AttachmentInfo

    var body: some View {
        #if os(macOS)
        let type = UTType(mimeType: info.mimeType)
            ?? info.filename.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
        Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().scaledToFit()
        #else
        Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
        #endif
    }
}
