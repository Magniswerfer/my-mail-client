import MailEngine
import SwiftUI

@main
struct TidingsApp: App {
    @State private var model = AppModel()

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
                Divider()
                Button("Mark Done") { model.perform(.done) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Pin / Unpin") { model.togglePin() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Snooze…") { model.isSnoozePickerShown = true }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Mark as Read / Unread") { model.toggleRead() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Move to Trash") { model.perform(.trash) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Move to Junk") { model.perform(.junk) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
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
            ReaderView(threadID: model.selectedThreadID)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search mail"))
        .searchFocused($searchFocused)
        .toolbar { toolbar }
        .navigationTitle(model.currentMailboxTitle)
        .overlay(alignment: .top) {
            if model.isPaletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea()
                        .onTapGesture { model.isPaletteShown = false }
                    CommandPalette().padding(.top, 80)
                }
            }
        }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onKeyPress(.escape) {
            if model.isPaletteShown { model.isPaletteShown = false; return .handled }
            guard model.isSearching else { return .ignored }
            model.searchText = ""
            searchFocused = false
            streamFocused = true
            return .handled
        }
        .sheet(isPresented: $model.isSnoozePickerShown) { SnoozePicker() }
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
        .onAppear {
            model.undoManager = undoManager
            model.openComposeWindow = { id in openWindow(id: "compose", value: id) }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark") }
                .help("Mark Done (E)")
                .disabled(model.targetThreads.isEmpty)
            Button { model.isSnoozePickerShown = true } label: { Label("Snooze", systemImage: "clock") }
                .help("Snooze (B)")
                .disabled(model.targetThreads.isEmpty)
            Button { model.togglePin() } label: {
                Label("Pin", systemImage: model.targetThreads.first?.isPinned == true ? "pin.fill" : "pin")
            }
            .help("Pin (P)")
            .disabled(model.targetThreads.isEmpty)
        }
        ToolbarItemGroup(placement: .navigation) {
            if model.selection == .inbox {
                Toggle(isOn: Binding(get: { model.pinnedOnly }, set: { model.pinnedOnly = $0 })) {
                    Label("Pinned only", systemImage: "pin.circle")
                }
                .help("Show only pinned (G P)")
                Button { model.requestSweep() } label: { Label("Sweep", systemImage: "checkmark.rectangle.stack") }
                    .help("Mark everything that isn't pinned done (⌘⇧E)")
            }
        }
        ToolbarItem(placement: .status) { SyncStatusView() }
    }

    /// Gmail/Superhuman-style single keys (SPEC §12). Ignored while typing.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !searchFocused, !model.isPaletteShown, !model.isSnoozePickerShown, !model.isCategoryPickerShown,
              press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        let key = press.characters

        if let g = pendingG, Date().timeIntervalSince(g) < 1.5 {
            pendingG = nil
            switch key {
            case "i": model.selection = .inbox
            case "s": model.selection = .snoozed
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
        case "c": model.composeNew()
        case "r": model.compose(.reply)
        case "a": model.compose(.replyAll)
        case "f": model.compose(.forward)
        default: return .ignored
        }
        return .handled
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help(error)
            }
            if model.isRefining {
                Label("Sorting with on-device AI…", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Sorting with on-device AI…")
            }
            Text(model.syncStatus.values.sorted().first ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
