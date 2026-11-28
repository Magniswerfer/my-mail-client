import MailEngine
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Show Source: which message.
struct SourceRequest: Identifiable {
    let id = UUID()
    let message: StoredMessage
}

extension AppModel {
    /// Show Source (⌥⌘U) for the newest message of the selected conversation.
    func showSourceOfSelected() {
        guard let thread = targetThreads.first, let message = readerMessages(inThread: thread.threadID).last else { return }
        sourceRequest = SourceRequest(message: message)
    }
}

/// A message as it came: every header and MIME part, to copy or save as .eml.
struct MessageSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: StoredMessage
    @State private var source: String?
    @State private var raw: Data?
    @State private var error: String?
    @State private var file: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let source {
                    TextEditor(text: .constant(source))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } else if let error {
                    ContentUnavailableView("Couldn't load the source", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text("Source: \(message.subject)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            // A sheet's toolbar on the Mac shows only its Done button: the rest go in a bar.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { if let source { Platform.copy(source) } }
                        .disabled(source == nil)
                        .help("Copy the whole source")
                    Button("Save…", systemImage: "square.and.arrow.down") { save() }
                        .disabled(raw == nil)
                        .help("Save as an .eml file")
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { if let source { Platform.copy(source) } }
                        .disabled(source == nil)
                    if let file { ShareLink(item: file) }
                }
            }
            #endif
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await load() }
    }

    private var filename: String {
        let base = message.subject.isEmpty ? "Message" : message.subject
        return String(base.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80)) + ".eml"
    }

    private func load() async {
        do {
            let data = try await model.rawMessage(message)
            raw = data
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            // Decoding and writing a large message (attachments and all) off the main actor.
            source = await Task.detached(priority: .userInitiated) { () -> String in
                try? data.write(to: url)
                return String(decoding: data, as: UTF8.self)
            }.value
            file = url
        } catch {
            self.error = String(describing: error)
        }
    }

    #if os(macOS)
    private func save() {
        guard let raw else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        if panel.runModal() == .OK, let url = panel.url { try? raw.write(to: url) }
    }
    #endif
}
