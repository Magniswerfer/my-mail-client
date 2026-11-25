import MailEngine
import QuickLook
import SwiftUI

// MARK: - Senders

/// Everyone who mails you, by volume (SPEC §11): unsubscribe, clear out, or decide where they go.
struct SendersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var senders: [SenderStat] = []
    @State private var filter = ""
    @State private var onlyLists = false

    private var shown: [SenderStat] {
        senders.filter { s in
            (!onlyLists || s.canUnsubscribe)
                && (filter.isEmpty || s.address.localizedCaseInsensitiveContains(filter) || (s.name ?? "").localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        NavigationStack {
            List(shown) { sender in
                HStack(spacing: 10) {
                    Avatar(name: sender.name ?? sender.address, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(sender.name ?? sender.address).lineLimit(1)
                            if model.isVIP(sender.address) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                            if model.isUnsubscribed(sender.address) {
                                Text("Unsubscribed").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).background(.quaternary, in: .capsule)
                            }
                        }
                        Text("\(sender.count) messages · \(sender.inInbox) in Inbox · last \(MailDate.short(sender.lastDate))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(sender.category.title, systemImage: sender.category.symbol)
                        .labelStyle(.iconOnly).foregroundStyle(sender.category.tint)
                        .help(sender.category.title)
                    Menu {
                        if sender.canUnsubscribe {
                            Button("Unsubscribe…", systemImage: "envelope.badge.shield.half.filled") { model.requestUnsubscribe(from: sender.address) }
                        }
                        Button("Mark All in Inbox Done", systemImage: "checkmark.circle") {
                            model.markAllDone(from: sender.address)
                            reload()
                        }
                        .disabled(sender.inInbox == 0)
                        Menu("Always Put In", systemImage: "tray.and.arrow.down") {
                            ForEach(MailCategory.allCases, id: \.self) { category in
                                Button(category.title, systemImage: category.symbol) {
                                    _ = try? model.store.remember(category: category, forSender: sender.address)
                                    model.reload()
                                    reload()
                                }
                            }
                        }
                        Button(model.isVIP(sender.address) ? "Remove from VIPs" : "Make VIP", systemImage: "star") {
                            model.toggleVIP(sender.address)
                        }
                        Button("Show Their Mail", systemImage: "magnifyingglass") {
                            model.searchText = "from:\(sender.address)"
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
            .searchable(text: $filter, prompt: Text("Filter senders"))
            .navigationTitle("Senders")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $onlyLists) { Label("Mailing Lists Only", systemImage: "newspaper") }
                        .help("Only senders you can unsubscribe from")
                }
            }
        }
        .macFrame(width: 640, height: 600)
        .onAppear(perform: reload)
    }

    private func reload() {
        senders = (try? model.store.senders(ownAddresses: model.ownAddresses)) ?? []
    }
}

// MARK: - Attachments

/// Every attachment you've received, newest first; Quick Look on click (SPEC §11).
struct AttachmentBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AttachmentEntry] = []
    @State private var filter = ""
    @State private var kind = Kind.all
    @State private var preview: URL?
    @State private var loading: String?

    enum Kind: String, CaseIterable { case all, documents, images, other
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .documents: String(localized: "Documents")
            case .images: String(localized: "Images")
            case .other: String(localized: "Other")
            }
        }

        func matches(_ mime: String) -> Bool {
            let isImage = mime.hasPrefix("image/")
            let isDoc = mime.contains("pdf") || mime.contains("word") || mime.contains("excel") || mime.contains("sheet")
                || mime.contains("presentation") || mime.contains("powerpoint") || mime.hasPrefix("text/") || mime.contains("opendocument")
            switch self {
            case .all: return true
            case .images: return isImage
            case .documents: return isDoc
            case .other: return !isImage && !isDoc
            }
        }
    }

    private var shown: [AttachmentEntry] {
        entries.filter { e in
            kind.matches(e.info.mimeType)
                && (filter.isEmpty || (e.info.filename ?? "").localizedCaseInsensitiveContains(filter)
                    || e.sender.localizedCaseInsensitiveContains(filter) || e.subject.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                List(shown) { entry in
                    Button { Task { await open(entry) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(entry.info.mimeType)).font(.title3).frame(width: 28).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.info.filename ?? entry.info.mimeType).lineLimit(1)
                                Text("\(entry.sender) · \(entry.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if loading == entry.id { ProgressView().controlSize(.small) }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(MailDate.short(entry.date)).font(.caption)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.info.size), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Show Message", systemImage: "envelope") {
                            if let threadID = model.threadID(forMessage: entry.messageID) { model.selectedThreadID = threadID }
                            dismiss()
                        }
                    }
                }
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView("No attachments yet", systemImage: "paperclip",
                                               description: Text("Attachments appear here as mail syncs."))
                    }
                }
            }
            .searchable(text: $filter, prompt: Text("Filter by name, sender or subject"))
            .navigationTitle("Attachments")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .quickLookPreview($preview)
        }
        .macFrame(width: 680, height: 620)
        .onAppear { entries = (try? model.store.attachmentEntries()) ?? [] }
    }

    private func open(_ entry: AttachmentEntry) async {
        loading = entry.id
        defer { loading = nil }
        if let url = await model.file(for: entry) { preview = url }
    }

    static func symbol(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("sheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        if mime.contains("zip") || mime.contains("compressed") { return "doc.zipper" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.contains("calendar") { return "calendar" }
        return "doc"
    }
}

// MARK: - Snippets

struct SnippetsSettings: View {
    @State private var snippets = SnippetStore.all

    var body: some View {
        Form {
            Section {
                ForEach($snippets) { $snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(";").foregroundStyle(.secondary)
                            TextField("keyword", text: $snippet.keyword)
                                .onChange(of: snippet.keyword) { save() }
                            Spacer()
                            Button(role: .destructive) {
                                snippets.removeAll { $0.id == snippet.id }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Text", text: $snippet.text, axis: .vertical)
                            .lineLimit(2...6)
                            .onChange(of: snippet.text) { save() }
                    }
                }
                Button("New Snippet", systemImage: "plus") {
                    snippets.append(Snippet(keyword: "", text: ""))
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Type ;keyword and a space in a message to insert the text. {first} and {name} are the first recipient, {me} is you, {date} is today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        SnippetStore.all = snippets.map {
            var s = $0
            s.keyword = s.keyword.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";")).lowercased()
            return s
        }
    }
}

// MARK: - Reader mode

/// Read Later's reader mode: the message as clean text, sized for reading.
struct ReaderModeText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.title3, design: .serif))
            .lineSpacing(6)
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
    }
}
