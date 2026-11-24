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
                Button("Next Conversation") { model.moveSelection(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Conversation") { model.moveSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @FocusState private var streamFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            Group {
                if model.isSearching {
                    SearchResultsView()
                } else {
                    StreamView()
                }
            }
            .focused($streamFocused)
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
        } detail: {
            ReaderView(threadID: model.selectedThreadID)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search mail"))
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem(placement: .status) {
                SyncStatusView()
            }
        }
        .navigationTitle(model.currentMailboxTitle)
        // Gmail-style single keys while the stream has focus (SPEC §12); ⌘ equivalents live in the menu.
        .onKeyPress(characters: .init(charactersIn: "jk/"), phases: .down) { press in
            guard !searchFocused else { return .ignored }
            switch press.characters {
            case "j": model.moveSelection(1)
            case "k": model.moveSelection(-1)
            case "/": searchFocused = true
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.escape) {
            guard model.isSearching else { return .ignored }
            model.searchText = ""
            searchFocused = false
            streamFocused = true
            return .handled
        }
        .sheet(isPresented: .constant(model.needsAccountSetup)) {
            AccountSetupView()
                .interactiveDismissDisabled()
        }
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
            Text(model.syncStatus.values.sorted().first ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
