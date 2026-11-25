#if os(iOS)
import MailEngine
import SwiftUI

/// iPhone: Inbox → conversation, with the sidebar one step back. iPad: the Mac's three columns.
/// Every action is a tap, a swipe or a long-press menu, and the same commands as the Mac.
struct MobileRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var composeDraft: ComposeDraft?
    @State private var isSettingsShown = false

    struct ComposeDraft: Identifiable { let id: Int64 }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            SidebarView(didPick: { compactColumn = .content })
                .navigationTitle("Tidings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isSettingsShown = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                }
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
            .navigationTitle(model.isSearching ? String(localized: "Search") : model.currentMailboxTitle)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text("Search mail"))
            .refreshable { await model.refresh() }
            .toolbar { streamToolbar }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ToastView(toast: toast).padding(.bottom, 12)
                }
            }
            .animation(.snappy, value: model.toast)
        } detail: {
            ReaderView(threadID: model.readerThreadID)
                .toolbar { readerToolbar }
                .inspector(isPresented: $model.isContactPanelShown) {
                    NavigationStack {
                        ContactPanel()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { model.isContactPanelShown = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        // Opening a conversation shows it; finishing the last one (or going back) shows the list.
        .onChange(of: model.selectedThreadID) { _, id in
            compactColumn = id == nil ? .content : .detail
        }
        .onChange(of: compactColumn) { _, column in
            if column == .content, Platform.isPhone, model.selectedThreadID != nil { model.selectedThreadID = nil }
        }
        .sheet(isPresented: $model.isSnoozePickerShown, onDismiss: { model.snoozeTarget = nil }) {
            SnoozePicker().presentationDetents([.medium, .large])
        }
        .modifier(MobileToolSheets())
        .onOpenURL { url in model.open(url: url) }
        .sheet(isPresented: $model.isCategoryPickerShown) {
            CategoryPicker().presentationDetents([.medium])
        }
        .confirmationDialog(model.sweepCandidate?.title ?? "", isPresented: Binding(
            get: { model.sweepCandidate != nil }, set: { if !$0 { model.sweepCandidate = nil } }
        ), titleVisibility: .visible, presenting: model.sweepCandidate) { request in
            Button("Mark \(request.threadIDs.count) Done") { model.confirmSweep(request) }
            Button("Cancel", role: .cancel) { model.sweepCandidate = nil }
        } message: { _ in
            Text("Pinned conversations stay. You can undo this.")
        }
        .sheet(item: $composeDraft) { draft in
            NavigationStack { ComposeWindow(draftID: draft.id) }
                .environment(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isSettingsShown) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { isSettingsShown = false } }
                    }
            }
            .environment(model)
        }
        .sheet(isPresented: .constant(model.needsAccountSetup)) {
            ScrollView { AccountSetupView() }
                .interactiveDismissDisabled()
        }
        .onAppear {
            model.undoManager = undoManager
            model.openComposeWindow = { id in composeDraft = ComposeDraft(id: id) }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    @ToolbarContentBuilder private var streamToolbar: some ToolbarContent {
        if model.selection == .inbox {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.pinnedOnly.toggle()
                } label: {
                    Label("Pinned Only", systemImage: model.pinnedOnly ? "pin.fill" : "pin")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Rules…", systemImage: "line.3.horizontal.decrease.circle") { model.isRulesShown = true }
                Button("Senders…", systemImage: "person.2") { model.isSendersShown = true }
                Button("Attachments…", systemImage: "paperclip") { model.isAttachmentsShown = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            SidebarStatus()
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button { model.composeNew() } label: { Label("New Message", systemImage: "square.and.pencil") }
        }
    }

    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        let none = model.targetThreads.isEmpty
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.toggleContactPanel() } label: { Label("Contact Info", systemImage: "person.crop.circle") }
                .disabled(none)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark") }
                .disabled(none)
            Button { model.isSnoozePickerShown = true } label: { Label("Snooze", systemImage: "clock") }
                .disabled(none)
            Button { model.togglePin() } label: {
                Label("Pin", systemImage: model.targetThreads.first?.isPinned == true ? "pin.fill" : "pin")
            }
            .disabled(none)
            Menu {
                if let thread = model.targetThreads.first {
                    MoveMenuContent(thread: thread)
                    Button("Move to Folder…", systemImage: "folder") { model.isFolderPickerShown = true }
                    Divider()
                    Button("Move to Junk", systemImage: "xmark.bin") { model.perform(.junk) }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { model.perform(.trash) }
                }
            } label: {
                Label("Move to", systemImage: "tray.and.arrow.down")
            }
            .disabled(none)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { model.compose(.replyAll) }
                Button("Forward", systemImage: "arrowshape.turn.up.right") { model.compose(.forward) }
                Button("Reply to Introduction", systemImage: "person.2.wave.2") { model.replyToIntroduction() }
                Button("Reply Later", systemImage: "arrowshape.turn.up.left.circle") { model.toggleReplyLater() }
                Button("Read Later", systemImage: "book") { model.readLater() }
                Button("Add to Reminders", systemImage: "checklist") { model.addToReminders() }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                model.compose(.reply)
            }
            .disabled(none)
        }
    }
}

extension AppModel {
    /// Pull to refresh: reconnect if iOS dropped the connection, then check every folder.
    func refresh() async {
        checkForNewMail()
        // Let the spinner reflect the work a little, without blocking on a slow server.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            if syncStatus.values.allSatisfy({ $0 == String(localized: "Up to date") }) { break }
        }
    }
}
/// The tool sheets (palette, folder picker, rules, senders, attachments, editors, Answer Now),
/// split out of the root view so the type-checker keeps up.
private struct MobileToolSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.isShortcutsShown) { ShortcutsView() }
            .sheet(isPresented: $model.isPaletteShown) {
                CommandPalette().padding(.top, 8).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $model.isFolderPickerShown) {
                FolderPicker().padding(.top, 8).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $model.isRulesShown) { RulesView().environment(model) }
            .sheet(isPresented: $model.isSendersShown) { SendersView().environment(model) }
            .sheet(isPresented: $model.isAttachmentsShown) { AttachmentBrowser().environment(model) }
            .quickLookPreview($model.quickLookURL)
            .modifier(UnsubscribeConfirmation(isActive: !model.isSendersShown))
            .sheet(item: $model.editingSmartFolder) { folder in SmartFolderEditor(folder: folder).environment(model) }
            .sheet(item: $model.editingAICategory) { editing in AICategoryEditor(editing: editing).environment(model) }
            .fullScreenCover(item: $model.replySession) { session in
                ReplySessionView(session: session).environment(model)
            }
    }
}
#endif
