#if os(macOS)
import MailEngine
import QuickLook
import SwiftUI

@main
struct TidingsApp: App {
    @State private var model: AppModel

    init() {
        // Sync runs with the app, not with a window: it keeps going if the window is closed.
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
        GlobalHotKey.shared.registerCopyCode { [weak model] in model?.copyLatestCode() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.start() }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Go to Inbox") { model.goToInbox() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Go to Snoozed") { model.selection = .snoozed }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Go to Set Aside") { model.selection = .replyLater }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Next Conversation") { model.moveSelection(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Conversation") { model.moveSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
            // Single-letter shortcuts are handled in RootView (so they never fire while typing);
            // the menu carries ⌘ equivalents and makes every action discoverable.
            CommandMenu("Message") {
                Button("Command Palette…") { model.isPaletteShown.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("New Message") { model.composeNew() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Reply") { model.compose(.reply) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reply All") { model.compose(.replyAll) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forward") { model.compose(.forward) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Reply to Introduction") { model.replyToIntroduction() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Mute Conversation") { model.toggleMute() }
                    .disabled(model.targetThreads.isEmpty)
                Button("Reply Later") { model.toggleReplyLater() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Answer Reply Later Pile…") { model.startReplySession() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Add to Reminders") { model.addToReminders() }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                Button("Copy Link to Message") { model.copyLink() }
                Button("Copy Latest Login Code") { model.copyLatestCode() }
                Divider()
                Button("Next Category") { model.cycleCategory(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Category") { model.cycleCategory(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("New AI Category…") {
                    model.editingAICategory = AICategoryEditing(category: AICategory(name: "", description: ""), isNew: true)
                }
                Button("Read Later") { model.readLater() }
                Divider()
                Button("Mark Done") { model.perform(.done) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Pin / Unpin") { model.togglePin() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Snooze…") { model.isSnoozePickerShown = true }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Mark as Read / Unread") { model.toggleRead() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                // ⌘⌫ is handled in RootView, not here: a menu shortcut fires before the focused
                // text field sees the key, so it would trash mail instead of deleting the line.
                Button("Move to Trash") { model.perform(.trash) }
                Button("Move to Junk") { model.perform(.junk) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Move to Folder…") { model.isFolderPickerShown = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Accept Invitation") { model.respondToSelectedInvite(.accepted) }
                    .keyboardShortcut("y", modifiers: [.command, .control])
                    .disabled(model.answerableInvite == nil)
                Button("Maybe") { model.respondToSelectedInvite(.tentative) }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                    .disabled(model.answerableInvite == nil)
                Button("Decline Invitation") { model.respondToSelectedInvite(.declined) }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                    .disabled(model.answerableInvite == nil)
            }
            CommandGroup(after: .toolbar) {
                Button(model.isContactPanelShown ? String(localized: "Hide Contact Info") : String(localized: "Show Contact Info")) {
                    model.toggleContactPanel()
                }
                    .keyboardShortcut("i", modifiers: [.command, .control])
            }
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") { model.isShortcutsShown = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu("Mailbox") {
                Button("Check for New Mail") { model.checkForNewMail() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Sweep Inbox") { model.requestSweep() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Show Only Pinned", isOn: Binding(get: { model.pinnedOnly }, set: { model.pinnedOnly = $0 }))
                Divider()
                Button(model.searchEverywhere ? "Search Only Here" : "Search Everywhere") { model.toggleSearchEverywhere() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.isSearching || (model.searchScope == nil && !model.searchEverywhere))
                Button("Save Search as Smart Folder…") { model.saveCurrentSearch() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isSearching)
                Button("Attachments…") { model.isAttachmentsShown = true }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                Button("Senders…") { model.isSendersShown = true }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Unsubscribe…") { if let address = model.listSenderOfSelection { model.requestUnsubscribe(address: address) } }
                    .disabled(model.listSenderOfSelection == nil)
                Button("Rules…") { model.isRulesShown = true }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("New Rule from Message…") { model.newRule(from: model.targetThreads.first) }
                    .disabled(model.targetThreads.isEmpty)
            }
        }

        WindowGroup("New Message", id: "compose", for: Int64.self) { $draftID in
            if let draftID {
                ComposeWindow(draftID: draftID)
                    .environment(model)
            }
        }
        .defaultSize(width: 720, height: 600)
        .commands { TextFormattingCommands() }

        // Rules, Senders and Attachments are windows of their own (as in Mail), with their
        // buttons in a compact title bar rather than a sheet's bottom bar over the inbox.
        Window("Rules", id: "rules") {
            RulesView().environment(model)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 720, height: 520)

        Window("Senders", id: "senders") {
            SendersView().environment(model)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 760, height: 560)

        Window("Attachments", id: "attachments") {
            AttachmentBrowser().environment(model)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 800, height: 560)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    @FocusState private var streamFocused: Bool
    /// Set after "g" for two-key navigation (G I, G S, G A, G P).
    @State private var pendingG: Date?
    @State private var commandAMonitor: Any?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            Group {
                if model.isSearching {
                    SearchResultsView()
                } else if model.selection == .outbox {
                    OutboxView()
                } else {
                    StreamView()
                }
            }
            .focused($streamFocused)
            // A wide max: when the list hit a narrow one, dragging the divider further pushed the
            // extra width into the sidebar instead (it should keep its size, as in Mail).
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 1200)
            // As in Mail: the list column has its own title, subtitle and buttons, and the
            // reader's buttons sit over the reader; both follow the divider when you drag it.
            .navigationTitle(model.listTitle)
            .navigationSubtitle(model.listSubtitle)
            .toolbar { listToolbar }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ToastView(toast: toast).padding(.bottom, 16)
                }
            }
            .animation(.snappy, value: model.toast)
        } detail: {
            VStack(spacing: 0) {
                ReaderView(threadID: model.readerThreadID)
                    .frame(maxHeight: .infinity)
                // Reply / Reply All / Forward open here, under the conversation.
                if let threadID = model.readerThreadID, let draftID = model.inlineDrafts[threadID] {
                    Divider()
                    InlineComposer(threadID: threadID, draftID: draftID)
                        .id(draftID)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.inlineDrafts)
            .navigationSplitViewColumnWidth(min: 380, ideal: 640)
            .toolbar { readerToolbar }
                .inspector(isPresented: $model.isContactPanelShown) {
                    ContactPanel()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search mail"))
        .searchFocused($searchFocused)
        .overlay(alignment: .top) {
            if model.isPaletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea()
                        .onTapGesture { model.isPaletteShown = false }
                    CommandPalette().padding(.top, 80)
                }
            }
            if model.isFolderPickerShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea()
                        .onTapGesture { model.isFolderPickerShown = false }
                    FolderPicker().padding(.top, 80)
                }
            }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .onKeyPress(.escape) {
            if model.isPaletteShown { model.isPaletteShown = false; return .handled }
            if model.isFolderPickerShown { model.isFolderPickerShown = false; return .handled }
            if !searchFocused, model.clearMultiSelection() { return .handled }
            guard model.isSearching else { return .ignored }
            model.searchText = ""
            searchFocused = false
            streamFocused = true
            return .handled
        }
        .sheet(isPresented: $model.isSnoozePickerShown) { SnoozePicker() }
        .sheet(isPresented: $model.isShortcutsShown) { ShortcutsView() }
        // The menu, ⌘K and keys still set these flags; on the Mac they open (or bring forward) a window.
        .onChange(of: model.isRulesShown) { _, show in if show { openWindow(id: "rules"); model.isRulesShown = false } }
        .onChange(of: model.isSendersShown) { _, show in if show { openWindow(id: "senders"); model.isSendersShown = false } }
        .onChange(of: model.isAttachmentsShown) { _, show in if show { openWindow(id: "attachments"); model.isAttachmentsShown = false } }
        .quickLookPreview($model.quickLookURL)
        .modifier(UnsubscribeConfirmation(isActive: !model.isSendersWindowOpen))
        .sheet(item: $model.editingSmartFolder) { folder in SmartFolderEditor(folder: folder).environment(model) }
        .sheet(item: $model.editingAICategory) { editing in AICategoryEditor(editing: editing).environment(model) }
        .sheet(item: $model.replySession) { session in
            ReplySessionView(session: session).environment(model)
        }
        .onOpenURL { url in model.open(url: url) }
        .sheet(isPresented: $model.isCategoryPickerShown) { CategoryPicker() }
        .confirmationDialog(model.sweepCandidate?.title ?? "", isPresented: Binding(
            get: { model.sweepCandidate != nil }, set: { if !$0 { model.sweepCandidate = nil } }
        ), presenting: model.sweepCandidate) { request in
            Button("Mark \(request.threadIDs.count) Done") { model.confirmSweep(request) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.sweepCandidate = nil }
        } message: { _ in
            Text("Pinned conversations stay. You can undo this.")
        }
        .sheet(isPresented: .constant(model.needsAccountSetup)) {
            AccountSetupView()
                .interactiveDismissDisabled()
        }
        .onChange(of: model.searchEndedCount) {
            searchFocused = false
            streamFocused = true
        }
        .onChange(of: isOverlayOpen) { _, open in
            if !open { returnFocusToList() }
        }
        .onAppear {
            model.undoManager = undoManager
            model.openComposeWindow = { id in openWindow(id: "compose", value: id) }
            installCommandA()
        }
        .onDisappear {
            if let commandAMonitor { NSEvent.removeMonitor(commandAMonitor) }
            commandAMonitor = nil
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    /// Over the list: filter and more, at the column's trailing edge.
    @ToolbarContentBuilder private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                // In here rather than as a second pin button next to the reader's Pin (G P).
                if model.isInInbox {
                    Toggle(isOn: Binding(get: { model.pinnedOnly }, set: { model.pinnedOnly = $0 })) {
                        Label("Pinned Only", systemImage: "pin")
                    }
                }
                if model.isInInbox, model.sweepableCount > 0 {
                    Button("Mark \(model.sweepableCount) Unpinned Done", systemImage: "checkmark.circle") { model.requestSweep() }
                    Divider()
                }
                Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                Button("Rules…", systemImage: "line.3.horizontal.decrease.circle") { model.isRulesShown = true }
                Button("Senders…", systemImage: "person.2") { model.isSendersShown = true }
                Button("Attachments…", systemImage: "paperclip") { model.isAttachmentsShown = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
    }

    /// Over the reader, as in Mail: write, answer, triage (each its own glass group), then who
    /// this is next to search at the window's trailing edge.
    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        let none = model.targetThreads.isEmpty
        ToolbarItem(placement: .primaryAction) {
            Button { model.composeNew() } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help("New Message (C or ⌘N)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.compose(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (R)").disabled(none)
            Button { model.compose(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply All (A)").disabled(none)
            Button { model.compose(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (F)").disabled(none)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark") }
                .help("Mark Done (E)").disabled(none)
            Button { model.isSnoozePickerShown = true } label: { Label("Snooze", systemImage: "clock") }
                .help("Snooze (B)").disabled(none)
            Button { model.togglePin() } label: {
                Label("Pin", systemImage: model.targetThreads.first?.isPinned == true ? "pin.fill" : "pin")
            }
            .help("Pin (P)").disabled(none)
            Menu {
                let targets = model.targetThreads
                if let thread = targets.first {
                    MoveMenuContent(thread: thread, threads: targets)
                    Section("Folder") { FolderMenuContent(thread: thread, threads: targets) }
                }
            } label: {
                Label("Move to", systemImage: "tray.and.arrow.down")
            }
            .menuIndicator(.hidden)
            .help("Move to another category (M) or folder (V)")
            .disabled(none)
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.isContactPanelShown }, set: { _ in model.toggleContactPanel() })) {
                Label("Contact Info", systemImage: "person.crop.circle")
            }
            .help("Who this is (⌃⌘I)")
        }
    }

    /// A picker, the palette or a sheet over the window. The V picker and ⌘K palette take focus
    /// with their text field, and it goes nowhere when they close; sheets don't reliably hand it
    /// back either. Either way J/K/E would stop working until you clicked the list.
    private var isOverlayOpen: Bool {
        model.isPaletteShown || model.isFolderPickerShown || model.isSnoozePickerShown || model.isCategoryPickerShown
            || model.isShortcutsShown || model.replySession != nil || model.sweepCandidate != nil || model.isRulesShown
            || model.editingSmartFolder != nil || model.isSendersShown || model.unsubscribeCandidate != nil
            || model.isAttachmentsShown
    }

    /// Keys go back to the list (and the conversation the action moved on to), unless the
    /// action opened something else or went to search.
    private func returnFocusToList() {
        Task { @MainActor in
            // After the overlay or sheet has finished closing, or the focus change is lost.
            guard !isOverlayOpen, !searchFocused else { return }
            streamFocused = true
        }
    }

    /// ⌘A in the stream: this conversation and everything below it, so one triage key handles
    /// the lot. It has to be caught before the menus: Edit ▸ Select All would otherwise hand it
    /// to the list, which selects every row. Text (search, ⌘K, the composer, the reader) keeps
    /// ⌘A for selecting text.
    private func installCommandA() {
        guard commandAMonitor == nil else { return }
        commandAMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "a",
                  streamFocused, !searchFocused, !isOverlayOpen, !model.isSearching,
                  !(event.window?.firstResponder is NSText)
            else { return event }
            model.selectFocusedAndBelow()
            return nil
        }
    }

    /// Gmail/Superhuman-style single keys (SPEC §12). Ignored while typing.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !searchFocused, !model.isPaletteShown, !model.isFolderPickerShown, !model.isSnoozePickerShown, !model.isCategoryPickerShown
        else { return .ignored }
        // ⌘⌫: Move to Trash, like Apple Mail (only here, so text fields keep ⌘⌫ for themselves).
        if press.key == .delete, press.modifiers == .command, press.phase == .down {
            model.perform(.trash)
            return .handled
        }
        // Tab / ⇧Tab: the next / previous category (Superhuman-style split inbox).
        if press.key == .tab, press.modifiers.subtracting(.shift).isEmpty, press.phase == .down {
            model.cycleCategory(press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        let key = press.characters
        // Holding J or K keeps moving (key repeat); every other key acts once per press.
        if press.phase == .repeat, key != "j", key != "k" { return .ignored }

        if let g = pendingG, Date().timeIntervalSince(g) < 1.5 {
            pendingG = nil
            switch key {
            case "i": model.goToInbox()
            case "s": model.selection = .snoozed
            case "l": model.selection = .replyLater
            case "a": model.goToArchive()
            case "o": model.selection = .outbox
            case "p": model.pinnedOnly.toggle()
            default: return .ignored
            }
            return .handled
        }

        switch key {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "/": searchFocused = true
        case "e": model.perform(.done)
        case "p": model.togglePin()
        case "b": if !model.targetThreads.isEmpty { model.isSnoozePickerShown = true }
        case "u": model.toggleRead()
        case "#": model.perform(.trash)
        case "!": model.perform(.junk)
        case "i": model.run(commandID: "inbox")
        case "g": pendingG = Date()
        case "m": if !model.targetThreads.isEmpty { model.isCategoryPickerShown = true }
        case "v": if !model.targetThreads.isEmpty { model.isFolderPickerShown = true }
        case "c": model.composeNew()
        case "r": model.compose(.reply)
        case "a": model.compose(.replyAll)
        case "f": model.compose(.forward)
        case "l": model.toggleReplyLater()
        case "M": model.toggleMute()
        case "R": model.readLater()
        case "?": model.isShortcutsShown = true
        default: return .ignored
        }
        return .handled
    }
}
#endif
