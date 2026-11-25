#if os(macOS)
import MailEngine
import SwiftUI

@main
struct TidingsApp: App {
    @State private var model: AppModel

    init() {
        // Sync runs with the app, not with a window: it keeps going if the window is closed.
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
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
                Button("Go to Inbox") { model.selection = .inbox }
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
                Button("Reply Later") { model.toggleReplyLater() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Answer Reply Later Pile…") { model.startReplySession() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Add to Reminders") { model.addToReminders() }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                Button("Copy Link to Message") { model.copyLink() }
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
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ToastView(toast: toast).padding(.bottom, 16)
                }
            }
            .animation(.snappy, value: model.toast)
        } detail: {
            ReaderView(threadID: model.readerThreadID)
                .inspector(isPresented: $model.isContactPanelShown) {
                    ContactPanel()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search mail"))
        .searchFocused($searchFocused)
        .toolbar { toolbar }
        .navigationTitle(model.isSearching ? String(localized: "Search") : model.currentMailboxTitle)
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
            guard model.isSearching else { return .ignored }
            model.searchText = ""
            searchFocused = false
            streamFocused = true
            return .handled
        }
        .sheet(isPresented: $model.isSnoozePickerShown) { SnoozePicker() }
        .sheet(isPresented: $model.isShortcutsShown) { ShortcutsView() }
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
        .onAppear {
            model.undoManager = undoManager
            model.openComposeWindow = { id in openWindow(id: "compose", value: id) }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Over the stream: write, and filter.
        ToolbarItemGroup(placement: .navigation) {
            Button { model.composeNew() } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help("New Message (C or ⌘N)")
            if model.selection == .inbox {
                Toggle(isOn: Binding(get: { model.pinnedOnly }, set: { model.pinnedOnly = $0 })) {
                    Label("Pinned Only", systemImage: model.pinnedOnly ? "pin.fill" : "pin")
                }
                .help(model.pinnedOnly ? "Showing pinned only (G P)" : "Show pinned only (G P)")
            }
        }
        // Over the reader: answer, then triage.
        ToolbarItemGroup(placement: .primaryAction) {
            let none = model.targetThreads.isEmpty
            Button { model.compose(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (R)").disabled(none)
            Button { model.compose(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply All (A)").disabled(none)
            Button { model.compose(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (F)").disabled(none)
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            let none = model.targetThreads.isEmpty
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark") }
                .help("Mark Done (E)").disabled(none)
            Button { model.isSnoozePickerShown = true } label: { Label("Snooze", systemImage: "clock") }
                .help("Snooze (B)").disabled(none)
            Button { model.togglePin() } label: {
                Label("Pin", systemImage: model.targetThreads.first?.isPinned == true ? "pin.fill" : "pin")
            }
            .help("Pin (P)").disabled(none)
            Menu {
                if let thread = model.targetThreads.first {
                    MoveMenuContent(thread: thread)
                    Section("Folder") { FolderMenuContent(thread: thread) }
                }
            } label: {
                Label("Move to", systemImage: "tray.and.arrow.down")
            }
            .menuIndicator(.hidden)
            .help("Move to another category (M) or folder (V)")
            .disabled(none)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.isContactPanelShown }, set: { _ in model.toggleContactPanel() })) {
                Label("Contact Info", systemImage: "person.crop.circle")
            }
            .help("Who this is (⌃⌘I)")
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
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        let key = press.characters
        // Holding J or K keeps moving (key repeat); every other key acts once per press.
        if press.phase == .repeat, key != "j", key != "k" { return .ignored }

        if let g = pendingG, Date().timeIntervalSince(g) < 1.5 {
            pendingG = nil
            switch key {
            case "i": model.selection = .inbox
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
        case "?": model.isShortcutsShown = true
        default: return .ignored
        }
        return .handled
    }
}
#endif
