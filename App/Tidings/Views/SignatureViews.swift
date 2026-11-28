import ImageIO
import MailEngine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Settings pane

/// Settings › Signatures: on the Mac when each is used (the signatures themselves are edited
/// in their own window); on iPhone and iPad the whole list.
struct SignatureSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: Signature?

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("\(model.signatures.count) signatures").foregroundStyle(.secondary)
                Spacer()
                Button("Edit Signatures…") { model.showSignatures() }
            }
            .padding(.horizontal, 20).padding(.top, 12)
            SignatureRulesView()
        }
        #else
        SignaturesList(deleting: $deleting)
            .confirmsSignatureDeletion($deleting) { model.deleteSignature($0) }
        #endif
    }
}

// MARK: - Signatures (window on the Mac, sheet on iPhone and iPad)

struct SignaturesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Item?
    @State private var isImportingHTML = false
    @State private var deleting: Signature?

    enum Item: Hashable { case rules, signature(String) }

    var body: some View {
        Group {
            #if os(macOS)
            split
            #else
            stack
            #endif
        }
        .onAppear { openRequested() }
        .onChange(of: model.signatureToEdit) { openRequested() }
        .fileImporter(isPresented: $isImportingHTML, allowedContentTypes: [.html, .webArchive, .plainText]) { result in
            if case .success(let url) = result { importHTML(url) }
        }
        .confirmsSignatureDeletion($deleting) { signature in
            model.deleteSignature(signature)
            if selection == .signature(signature.id) { selection = nil }
        }
    }

    private func openRequested() {
        if let id = model.signatureToEdit {
            selection = .signature(id)
            model.signatureToEdit = nil
        } else if selection == nil {
            selection = model.signatures.first.map { .signature($0.id) } ?? .rules
        }
    }

    // MARK: Mac

    #if os(macOS)
    private var split: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("When to Use", systemImage: "arrow.triangle.branch").tag(Item.rules)
                Section("Signatures") {
                    ForEach(model.signatures) { signature in
                        Label(signature.name, systemImage: "signature")
                            .tag(Item.signature(signature.id))
                            .contextMenu { rowMenu(signature) }
                    }
                    .onMove { model.moveSignatures(from: $0, to: $1) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar { ToolbarItem { addMenu } }
            .onDeleteCommand {
                if case .signature(let id) = selection, let signature = model.signature(id: id) { deleting = signature }
            }
        } detail: {
            switch selection {
            case .rules:
                SignatureRulesView()
            case .signature(let id):
                if let signature = model.signature(id: id) {
                    SignatureEditor(original: signature).id(id)
                } else {
                    empty
                }
            case nil:
                empty
            }
        }
    }

    #endif

    private var empty: some View {
        ContentUnavailableView {
            Label("No Signature Selected", systemImage: "signature")
        } description: {
            Text("Make one, paste one you copied from Mail or a web page, or import an HTML file.")
        } actions: {
            Button("New Signature") { model.newSignature() }
        }
    }

    @ViewBuilder private func rowMenu(_ signature: Signature) -> some View {
        Button("Duplicate") { selection = .signature(model.duplicateSignature(signature).id) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = signature }
    }

    private var addMenu: some View {
        Menu {
            Button("New Signature") { model.newSignature() }
            Button("Paste as New Signature") { model.pasteSignatureFromClipboard() }
            Button("Import HTML File…") { isImportingHTML = true }
        } label: {
            Label("Add Signature", systemImage: "plus")
        } primaryAction: {
            model.newSignature()
        }
        .help("New signature (or paste one, or import an HTML file)")
    }

    private func importHTML(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        var html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if url.pathExtension.lowercased() == "webarchive", let archived = SignatureImport.webArchiveHTML(data) { html = archived }
        let extracted = SignatureHTML.extractingImages(SignatureHTML.sanitize(html))
        let signature = Signature(name: url.deletingPathExtension().lastPathComponent, html: extracted.html, images: extracted.images)
        model.saveSignature(signature)
        selection = .signature(signature.id)
    }

    // MARK: iPhone and iPad

    private var stack: some View {
        NavigationStack {
            SignaturesList(deleting: $deleting)
                .navigationTitle("Signatures")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

private extension View {
    /// Asks before deleting the signature in `deleting`, then hands it to `delete`.
    func confirmsSignatureDeletion(_ deleting: Binding<Signature?>, delete: @escaping (Signature) -> Void) -> some View {
        confirmationDialog(String(localized: "Delete this signature?"), isPresented: Binding(
            get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } }
        ), titleVisibility: .visible, presenting: deleting.wrappedValue) { signature in
            Button("Delete “\(signature.name)”", role: .destructive) { delete(signature) }
        } message: { _ in
            Text("It's removed from all your devices, and from the rules that use it. Messages you sent keep it.")
        }
    }
}

/// iPhone and iPad: the signatures (with previews) and when each is used.
struct SignaturesList: View {
    @Environment(AppModel.self) private var model
    @Binding var deleting: Signature?

    var body: some View {
        List {
            Section {
                ForEach(model.signatures) { signature in
                    NavigationLink {
                        SignatureDetail(original: signature)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(signature.name).font(.headline)
                            SignaturePreview(signature: signature).frame(maxHeight: 120)
                        }
                    }
                }
                .onDelete { offsets in deleting = offsets.first.map { model.signatures[$0] } }
                .onMove { model.moveSignatures(from: $0, to: $1) }
                Button("Paste as New Signature", systemImage: "doc.on.clipboard") { model.pasteSignatureFromClipboard() }
            } header: {
                Text("Signatures")
            } footer: {
                Text("Copy a signature from a web page, Mail or Notes and paste it here. The full editor is on the Mac; signatures sync through iCloud.")
            }
            Section {
                NavigationLink {
                    SignatureRulesView().navigationTitle("When to Use")
                } label: {
                    Label("When to Use", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }
}

// MARK: - iPhone and iPad: one signature

/// Name, preview, the plain-text version and the HTML as text (the visual editor is on the Mac).
struct SignatureDetail: View {
    @Environment(AppModel.self) private var model
    let original: Signature
    @State private var signature: Signature
    @State private var source: String

    init(original: Signature) {
        self.original = original
        _signature = State(initialValue: original)
        _source = State(initialValue: original.html)
    }

    var body: some View {
        Form {
            Section("Name") { TextField("Name", text: $signature.name) }
            Section("Preview") { SignaturePreview(signature: signature) }
            Section {
                Toggle("Write My Own Plain-Text Version", isOn: Binding(
                    get: { signature.customPlainText != nil },
                    set: { signature.customPlainText = $0 ? signature.plainText : nil }))
                if signature.customPlainText != nil {
                    TextField("Plain text", text: Binding(get: { signature.customPlainText ?? "" },
                                                          set: { signature.customPlainText = $0 }), axis: .vertical)
                        .lineLimit(3...10)
                } else {
                    Text(signature.plainText).foregroundStyle(.secondary).font(.callout)
                }
            } header: {
                Text("Plain Text")
            } footer: {
                Text("Sent with the HTML for mail programs that show only text.")
            }
            Section {
                TextField("HTML", text: $source, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .lineLimit(4...20)
            } header: {
                Text("HTML")
            }
        }
        .navigationTitle(signature.name)
        .onChange(of: signature) { model.saveSignature(signature) }
        .onChange(of: source) {
            let extracted = SignatureHTML.extractingImages(SignatureHTML.sanitize(source), existing: original.images)
            signature.html = extracted.html
            signature.images = extracted.images
        }
    }
}

// MARK: - When to use which

struct SignatureRulesView: View {
    @Environment(AppModel.self) private var model

    private var identities: [Identity] {
        var seen = Set<String>()
        return model.accounts.flatMap(\.sendingIdentities).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Form {
            addressDefaultsSection
            rulesSection
        }
        .formStyle(.grouped)
    }

    private var addressDefaultsSection: some View {
        Section {
            ForEach(identities) { identity in
                VStack(alignment: .leading, spacing: 8) {
                    Text(identity.address).font(.headline)
                    Picker("New mail", selection: newMailBinding(identity.address)) {
                        Text("None").tag(SignatureChoiceTag.none)
                        signatureOptions
                    }
                    Picker("Replies and forwards", selection: repliesBinding(identity.address)) {
                        Text("Same as New Mail").tag(SignatureChoiceTag.sameAsNewMail)
                        Text("None").tag(SignatureChoiceTag.none)
                        signatureOptions
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("For Each Address")
        } footer: {
            Text("Switching From in a message switches its signature too.")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach(model.signatureSettings.rules) { rule in
                SignatureRuleRow(rule: rule, identities: identities)
            }
            .onDelete { offsets in model.updateSignatureSettings { $0.rules.remove(atOffsets: offsets) } }
            .onMove { from, to in model.updateSignatureSettings { $0.rules.move(fromOffsets: from, toOffset: to) } }
            Button("Add Rule", systemImage: "plus", action: addRule)
        } header: {
            Text("Rules by Recipient")
        } footer: {
            Text("The first rule that fits wins, before the address's own choice. They look at To, Cc and Bcc and change the signature as you add people, until you pick one yourself.")
        }
    }

    private var signatureOptions: some View {
        ForEach(model.signatures) { Text($0.name).tag(SignatureChoiceTag.signature($0.id)) }
    }

    /// A new rule starts from your first address's domain and your newest signature.
    private func addRule() {
        let domain = identities.first.flatMap { $0.address.split(separator: "@").last.map(String.init) } ?? ""
        model.updateSignatureSettings {
            $0.rules.append(SignatureRule(match: .everyRecipientIn, domains: domain.isEmpty ? [] : [domain],
                                          use: model.signatures.last.map { .signature($0.id) } ?? .none))
        }
    }

    private func newMailBinding(_ address: String) -> Binding<String> {
        Binding(
            get: { SignatureChoiceTag.tag(for: model.signatureSettings.defaults(for: address).newMail) },
            set: { tag in model.updateSignatureSettings { s in
                var d = s.defaults(for: address)
                d.newMail = SignatureRuleRow.choice(tag)
                s.setDefaults(d, for: address)
            } })
    }

    private func repliesBinding(_ address: String) -> Binding<String> {
        Binding(
            get: {
                switch model.signatureSettings.defaults(for: address).replies {
                case nil: SignatureChoiceTag.sameAsNewMail
                case let choice?: SignatureChoiceTag.tag(for: choice)
                }
            },
            set: { tag in model.updateSignatureSettings { s in
                var d = s.defaults(for: address)
                d.replies = tag == SignatureChoiceTag.sameAsNewMail ? nil : SignatureRuleRow.choice(tag)
                s.setDefaults(d, for: address)
            } })
    }
}

struct SignatureRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: SignatureRule
    let identities: [Identity]
    @State private var domains = ""

    static func choice(_ tag: String) -> SignatureChoice {
        tag.hasPrefix(SignatureChoiceTag.signaturePrefix)
            ? .signature(String(tag.dropFirst(SignatureChoiceTag.signaturePrefix.count))) : .none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When", selection: binding(\.match)) {
                Text("Everyone it goes to is at").tag(SignatureRule.Match.everyRecipientIn)
                Text("Someone it goes to is at").tag(SignatureRule.Match.anyRecipientIn)
                Text("Someone it goes to isn't at").tag(SignatureRule.Match.anyRecipientOutside)
            }
            TextField("Domains", text: $domains, prompt: Text(verbatim: "creativeoak.dk, creativeoak.io"))
                .onSubmit(saveDomains)
                .onChange(of: domains) { saveDomains() }
            Picker("Sending from", selection: binding(\.fromAddress)) {
                Text("Any address").tag(String?.none)
                ForEach(identities) { Text($0.address).tag(Optional($0.address.lowercased())) }
            }
            Picker("In", selection: binding(\.context)) {
                Text("All mail").tag(SignatureRule.Context.all)
                Text("New mail").tag(SignatureRule.Context.newMail)
                Text("Replies and forwards").tag(SignatureRule.Context.replies)
            }
            Picker("Use", selection: Binding(
                get: { SignatureChoiceTag.tag(for: rule.use) },
                set: { tag in update { $0.use = Self.choice(tag) } })) {
                Text("No signature").tag(SignatureChoiceTag.none)
                ForEach(model.signatures) { Text($0.name).tag(SignatureChoiceTag.signature($0.id)) }
            }
        }
        .padding(.vertical, 4)
        .onAppear { domains = rule.domains.joined(separator: ", ") }
    }

    private func binding<T>(_ path: WritableKeyPath<SignatureRule, T>) -> Binding<T> {
        Binding(get: { rule[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func saveDomains() {
        let list = domains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init).filter { !$0.isEmpty }
        guard list != rule.domains else { return }
        update { $0.domains = list }
    }

    private func update(_ change: (inout SignatureRule) -> Void) {
        model.updateSignatureSettings { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            change(&settings.rules[index])
        }
    }
}

/// Picker tags for a `SignatureChoice` ("none", "sig:<id>"), plus "same" for replies that
/// follow the new-mail choice.
private enum SignatureChoiceTag {
    static let none = "none"
    static let sameAsNewMail = "same"
    static let signaturePrefix = "sig:"

    static func signature(_ id: String) -> String { signaturePrefix + id }

    static func tag(for choice: SignatureChoice?) -> String {
        choice?.signatureID.map(signature) ?? none
    }
}

// MARK: - Importing

enum SignatureImport {
    /// The HTML of a .webarchive (Safari, Mail), with its images as data: URIs.
    static func webArchiveHTML(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let bytes = main["WebResourceData"] as? Data,
              var html = String(data: bytes, encoding: .utf8) else { return nil }
        for case let resource as [String: Any] in plist["WebSubresources"] as? [Any] ?? [] {
            guard let url = resource["WebResourceURL"] as? String, let body = resource["WebResourceData"] as? Data,
                  let mime = resource["WebResourceMIMEType"] as? String, mime.hasPrefix("image/") else { continue }
            let shrunk = SignatureImageShrinker.shrink(body, mimeType: mime)
            html = html.replacingOccurrences(of: url, with: "data:\(shrunk.mimeType);base64,\(shrunk.data.base64EncodedString())")
        }
        return html
    }

    /// Downloads a hosted image (to embed it).
    static func download(_ url: String) async -> SignatureImage? {
        guard let address = URL(string: url), let (data, response) = try? await URLSession.shared.data(from: address),
              let mime = (response as? HTTPURLResponse)?.mimeType ?? response.mimeType, mime.hasPrefix("image/"),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let shrunk = SignatureImageShrinker.shrink(data, mimeType: mime)
        let name = address.lastPathComponent.isEmpty ? "image" : address.lastPathComponent
        return SignatureImage(filename: name, mimeType: shrunk.mimeType, data: shrunk.data)
    }
}

/// Large pictures made small enough to travel in every message and sync (a signature is a few
/// hundred points wide; 1200 pixels covers a Retina screen twice over).
enum SignatureImageShrinker {
    static let threshold = 120_000
    static let maxPixels = 1200

    static func shrink(_ data: Data, mimeType: String) -> (data: Data, mimeType: String) {
        guard data.count > threshold, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (data, mimeType) }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return (data, mimeType) }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = opaque ? UTType.jpeg : UTType.png
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return (data, mimeType) }
        CGImageDestinationAddImage(destination, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination), out.length < data.count else { return (data, mimeType) }
        return (out as Data, opaque ? "image/jpeg" : "image/png")
    }

    /// Pixel width, to show a picture at half (a Retina picture at its size).
    static func pixelWidth(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }
}

// MARK: - Mac: the editor

#if os(macOS)
/// One signature: edit it as it looks (WebKit, so pasted tables and styles survive) or as HTML.
/// Changes save as you go.
struct SignatureEditor: View {
    @Environment(AppModel.self) private var model
    let original: Signature
    @State private var name: String
    @State private var images: [SignatureImage]
    @State private var customPlainText: String?
    @State private var mode = Mode.visual
    /// The HTML with embedded images as `cid:` (what the source view shows).
    @State private var source: String
    @State private var editor = SignatureWebEditor.Controller()
    /// Bumped to load new HTML into the visual editor.
    @State private var loadToken = UUID()
    @State private var problem: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var isAddingImage = false
    @State private var isLinkPromptShown = false
    @State private var linkAddress = ""
    @State private var isEmbedding = false
    @State private var size = 0

    enum Mode: String, CaseIterable { case visual, source }

    init(original: Signature) {
        self.original = original
        _name = State(initialValue: original.name)
        _images = State(initialValue: original.images)
        _customPlainText = State(initialValue: original.customPlainText)
        _source = State(initialValue: original.html)
        _size = State(initialValue: original.storedSize)
    }

    private var current: Signature {
        Signature(id: original.id, name: name, html: source, images: images, customPlainText: customPlainText)
    }

    /// Typing pauses this long before the signature saves.
    private static let saveDelay: Duration = .milliseconds(700)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameAndMode
            formatBar
            editorArea
            plainTextSection
            footer
        }
        .padding(16)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .top)
        .navigationTitle(name)
        .onDisappear { saveTask?.cancel(); Task { await save() } }
        .fileImporter(isPresented: $isAddingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { addImage(url) }
        }
        .alert("Link", isPresented: $isLinkPromptShown) {
            TextField("Address", text: $linkAddress, prompt: Text(verbatim: "https://creativeoak.io"))
            Button("Add Link") { addLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A web address, an email address or a phone number.")
        }
    }

    private var nameAndMode: some View {
        HStack {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(maxWidth: 280)
                .onChange(of: name) { scheduleSave() }
            Spacer()
            Picker("Edit as", selection: $mode) {
                Text("Visual").tag(Mode.visual)
                Text("HTML").tag(Mode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { old, new in switchMode(from: old, to: new) }
        }
    }

    private var editorArea: some View {
        Group {
            if mode == .visual {
                SignatureWebEditor(html: SignatureHTML.inliningImages(source, images), loadToken: loadToken,
                                   controller: editor, onChange: scheduleSave)
            } else {
                TextEditor(text: $source)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .onChange(of: source) { if mode == .source { scheduleSave() } }
            }
        }
        .frame(minHeight: 220, idealHeight: 320, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private var formatBar: some View {
        HStack(spacing: 8) {
            Group {
                Button { editor.run("bold") } label: { Label("Bold", systemImage: "bold") }
                Button { editor.run("italic") } label: { Label("Italic", systemImage: "italic") }
                Button { editor.run("underline") } label: { Label("Underline", systemImage: "underline") }
                Button { linkAddress = ""; isLinkPromptShown = true } label: { Label("Link…", systemImage: "link") }
                Button { isAddingImage = true } label: { Label("Add Picture…", systemImage: "photo") }
            }
            .labelStyle(.iconOnly)
            .disabled(mode != .visual)
            Divider().frame(height: 16)
            Button("Paste Formatted") { pasteFormatted() }
                .help("Replace the signature with formatted text or HTML you copied")
            Button("Embed Hosted Pictures") { Task { await embedHostedImages() } }
                .disabled(isEmbedding || SignatureHTML.remoteImageURLs(in: source).isEmpty)
                .help("Download pictures linked from the web and send them inside each message, so they show without loading remote content")
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private var plainTextSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Write my own", isOn: Binding(
                    get: { customPlainText != nil },
                    set: { customPlainText = $0 ? current.plainText : nil; scheduleSave() }))
                if customPlainText != nil {
                    TextEditor(text: Binding(get: { customPlainText ?? "" }, set: { customPlainText = $0; scheduleSave() }))
                        .font(.body)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                } else {
                    ScrollView {
                        Text(current.plainText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Plain-text version")
        }
    }

    private var footer: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Text(images.isEmpty
                     ? String(localized: "Pictures from the web show when the reader allows remote content.")
                     : String(localized: "\(images.count) pictures travel inside each message."))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.fileSize(size)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
    }

    // MARK: Changes

    private func switchMode(from old: Mode, to new: Mode) {
        guard old == .visual, new == .source else {
            reloadEditor()   // HTML → visual: show what was typed
            return
        }
        Task {
            guard let html = await editor.html() else { return }
            take(html)
        }
    }

    /// HTML from the editor (data: images) → the source with `cid:` images.
    private func take(_ html: String) {
        let extracted = SignatureHTML.extractingImages(SignatureHTML.sanitize(html), existing: images)
        source = extracted.html
        images = extracted.images.map { image in
            let shrunk = SignatureImageShrinker.shrink(image.data, mimeType: image.mimeType)
            var copy = image
            copy.data = shrunk.data
            copy.mimeType = shrunk.mimeType
            return copy
        }
    }

    /// Shows `source` in the visual editor. Until it has loaded, saving uses `source` as it is
    /// (the page still has the old HTML).
    private func reloadEditor() {
        editor.isLoading = true
        loadToken = UUID()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        if mode == .visual, let html = await editor.html() { take(html) }
        let signature = current
        size = signature.storedSize
        if size > Signature.maxStoredSize {
            problem = String(localized: "Too large to sync (\(Self.fileSize(size)) of \(Self.fileSize(Signature.maxStoredSize))). Use smaller pictures, or ones from the web.")
            return
        }
        problem = editor.droppedImages > 0
            ? String(localized: "A pasted picture couldn't be kept. Add it with the picture button instead.") : nil
        guard signature != model.signature(id: original.id) else { return }
        model.saveSignature(signature)
    }

    private static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func addImage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        let shrunk = SignatureImageShrinker.shrink(data, mimeType: type)
        let width = min(320, max(8, (SignatureImageShrinker.pixelWidth(shrunk.data) ?? 640) / 2))
        editor.insertHTML("<img src=\"data:\(shrunk.mimeType);base64,\(shrunk.data.base64EncodedString())\" width=\"\(width)\" alt=\"\">")
    }

    private func addLink() {
        let address = linkAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        editor.run("createLink", value: Self.linkURL(for: address))
    }

    /// What was typed in the link prompt as a URL: an email address, a phone number or a web
    /// address without its scheme get one.
    private static func linkURL(for address: String) -> String {
        if address.contains("@"), !address.contains(":") { return "mailto:" + address }
        if address.hasPrefix("+") || address.allSatisfy({ $0.isNumber || $0 == " " }) {
            return "tel:" + address.filter { !$0.isWhitespace }
        }
        if !address.contains(":") { return "https://" + address }
        return address
    }

    private func pasteFormatted() {
        guard let html = SignaturePasteboard.html() else {
            problem = String(localized: "There's no formatted text on the clipboard.")
            return
        }
        let extracted = SignatureHTML.extractingImages(SignatureHTML.sanitize(html), existing: images)
        source = extracted.html
        images = extracted.images
        reloadEditor()
        scheduleSave()
    }

    private func embedHostedImages() async {
        isEmbedding = true
        defer { isEmbedding = false }
        if mode == .visual, let html = await editor.html() { take(html) }
        var failed = 0
        for url in SignatureHTML.remoteImageURLs(in: source) {
            guard let image = await SignatureImport.download(url) else { failed += 1; continue }
            source = SignatureHTML.embedding(url, as: image, in: source)
            images.append(image)
        }
        reloadEditor()
        await save()
        if failed > 0, problem == nil { problem = String(localized: "\(failed) pictures couldn't be downloaded and stay linked.") }
    }
}

/// The visual editor: the signature in an editable web page, white as mail usually is.
struct SignatureWebEditor: NSViewRepresentable {
    let html: String
    let loadToken: UUID
    let controller: Controller
    let onChange: () -> Void

    @MainActor final class Controller {
        weak var webView: WKWebView?
        /// New HTML is on its way in: what the page has is stale.
        var isLoading = true
        /// Pictures a paste brought that couldn't be read (left out on save).
        var droppedImages = 0

        func run(_ command: String, value: String? = nil) {
            let argument = value.map { "'\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'" } ?? "null"
            webView?.evaluateJavaScript("tidingsCommand('\(command)', \(argument))")
        }

        func insertHTML(_ html: String) {
            webView?.callAsyncJavaScript("tidingsCommand('insertHTML', html)", arguments: ["html": html], in: nil, in: .page) { _ in }
        }

        /// The signature's HTML, with pasted pictures made into data: URIs.
        func html() async -> String? {
            guard let webView, !isLoading else { return nil }
            let result = try? await webView.callAsyncJavaScript("return await tidingsHTML()", contentWorld: .page)
            guard let pair = result as? [Any], let html = pair.first as? String else { return nil }
            droppedImages = (pair.last as? Int) ?? 0
            return html
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "changed")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        controller.webView = view
        context.coordinator.token = loadToken
        context.coordinator.controller = controller
        controller.isLoading = true
        view.loadHTMLString(Self.page(html), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
        controller.webView = view
        guard context.coordinator.token != loadToken else { return }
        context.coordinator.token = loadToken
        controller.isLoading = true
        view.loadHTMLString(Self.page(html), baseURL: nil)
    }

    static func page(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:#fff;color:#000;font-family:-apple-system,Helvetica,sans-serif;font-size:14px;line-height:1.3}
        #sig{padding:14px 16px;min-height:180px;outline:none}
        #sig img{max-width:100%}
        </style></head><body><div id="sig" contenteditable="true">\(html)</div>
        <script>
        const sig = document.getElementById('sig');
        let saved = null;
        sig.addEventListener('input', () => webkit.messageHandlers.changed.postMessage(1));
        document.addEventListener('selectionchange', () => {
          const s = getSelection();
          if (s.rangeCount && sig.contains(s.anchorNode)) saved = s.getRangeAt(0).cloneRange();
        });
        function tidingsCommand(name, value) {
          sig.focus();
          if (saved) { const s = getSelection(); s.removeAllRanges(); s.addRange(saved); }
          document.execCommand(name, false, value);
          webkit.messageHandlers.changed.postMessage(1);
        }
        async function tidingsHTML() {
          let dropped = 0;
          for (const img of Array.from(sig.querySelectorAll('img'))) {
            const src = img.getAttribute('src') || '';
            if (/^(https?:|data:|cid:)/i.test(src)) continue;
            try {
              const blob = await (await fetch(img.src)).blob();
              const url = await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result); reader.onerror = reject;
                reader.readAsDataURL(blob);
              });
              img.setAttribute('src', url);
            } catch (e) {
              try {
                const c = document.createElement('canvas');
                c.width = img.naturalWidth; c.height = img.naturalHeight;
                c.getContext('2d').drawImage(img, 0, 0);
                img.setAttribute('src', c.toDataURL('image/png'));
              } catch (e2) { img.remove(); dropped++; }
            }
          }
          return [sig.innerHTML, dropped];
        }
        </script></body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onChange: () -> Void
        var token: UUID?
        weak var controller: Controller?

        init(onChange: @escaping () -> Void) { self.onChange = onChange }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { controller?.isLoading = false }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { onChange() }

        /// Clicking a link while editing doesn't leave the signature.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}
#endif
