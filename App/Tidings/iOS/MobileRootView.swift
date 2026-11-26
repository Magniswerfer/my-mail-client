#if os(iOS)
import MailEngine
import QuickLook
import SwiftUI

/// iPhone: Inbox → conversation, with the sidebar one step back. iPad: the Mac's three columns.
/// Every action is a tap, a swipe or a long-press menu, and the same commands as the Mac.
struct MobileRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var composeDraft: ComposeDraft?
    @State private var isSettingsShown = false

    struct ComposeDraft: Identifiable { let id: Int64 }

    /// One column at a time (iPhone) and it's the conversation: the toast goes there.
    private var isToastInReader: Bool { sizeClass == .compact && compactColumn == .detail }

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
            // Select mode says how many are ticked under the title (not in the crowded bottom bar).
            .navigationSubtitle(model.isSelecting
                ? (model.multiSelection.isEmpty ? String(localized: "Select conversations")
                                                : String(localized: "\(model.multiSelection.count) selected"))
                : (model.isInInbox ? model.inboxAccountID.flatMap(model.account(id:))?.displayName ?? "" : ""))
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text("Search mail"))
            .refreshable { await model.refresh() }
            .toolbar { streamToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The toast sits above the bar, inside the safe area: it never covers the bar or
                // anything else you can tap, and the list scrolls clear of it.
                VStack(spacing: 8) {
                    if let toast = model.toast, !isToastInReader {
                        ToastView(toast: toast)
                    }
                    if Platform.isPhone, !model.isSelecting, !model.isSearching { PhoneBottomBar() }
                }
                .padding(.bottom, Platform.isPhone ? 0 : 12)
            }
            .animation(.snappy, value: model.toast)
        } detail: {
            ReaderView(threadID: model.readerThreadID)
                .toolbar { readerToolbar }
                // iPhone, reading: the list is out of sight, so the toast shows here, just above
                // the reader's buttons.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let toast = model.toast, isToastInReader {
                        ToastView(toast: toast).padding(.bottom, 8)
                    }
                }
                .animation(.snappy, value: model.toast)
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
        .sheet(isPresented: $model.isSnoozePickerShown, onDismiss: { model.snoozeTarget = nil; model.isSelecting = false }) {
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
            // .id: a new draft while the sheet is up (Clear Suggestion) rebuilds the composer
            // instead of keeping the old one's state.
            NavigationStack { ComposeWindow(draftID: draft.id).id(draft.id) }
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
        .sheet(isPresented: $model.isAccountSetupShown) {
            NavigationStack { AccountSetupView() }
                .environment(model)
                .interactiveDismissDisabled(model.needsAccountSetup)
        }
        .modifier(AccountRemovalConfirmation(account: $model.accountToRemove))
        .modifier(FolderManagement())
        .sheet(item: $model.accountToSignIn) { account in
            AccountPasswordSheet(account: account).environment(model)
        }
        .sheet(isPresented: $model.isPushServerSheetShown) {
            PushServerSheet().environment(model)
        }
        .onAppear {
            model.undoManager = undoManager
            model.openComposeWindow = { id in composeDraft = ComposeDraft(id: id) }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    @ToolbarContentBuilder private var streamToolbar: some ToolbarContent {
        // Nothing is ever "focused" on a phone, so the top-left button selects instead.
        if !model.threads.isEmpty || model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(model.isSelecting ? String(localized: "Done") : String(localized: "Select")) {
                    withAnimation(.snappy) { model.isSelecting.toggle() }
                }
                .fontWeight(model.isSelecting ? .semibold : .regular)
            }
        }
        if !model.isSelecting {
            ToolbarItem(placement: .topBarTrailing) { UnreadFilterButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.isSelecting {
                    Button("Select All", systemImage: "checkmark.circle") {
                        model.multiSelection = Set(model.visibleThreadIDs)
                    }
                    Divider()
                }
                if model.isInInbox {
                    Toggle(isOn: Binding(get: { model.pinnedOnly }, set: { model.pinnedOnly = $0 })) {
                        Label("Pinned Only", systemImage: "pin")
                    }
                    if model.sweepableCount > 0 {
                        Button("Mark \(model.sweepableCount) Unpinned Done", systemImage: "checkmark.circle") {
                            model.requestSweep()
                        }
                    }
                    Divider()
                }
                Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Rules…", systemImage: "line.3.horizontal.decrease.circle") { model.isRulesShown = true }
                Button("Senders…", systemImage: "person.2") { model.isSendersShown = true }
                Button("Attachments…", systemImage: "paperclip") { model.isAttachmentsShown = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        if model.isSelecting {
            bulkActions
        } else if !Platform.isPhone {
            // (iPhone: categories and New Message are the glass PhoneBottomBar instead. The sync
            // status is the small line under the sidebar.)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { model.composeNew() } label: { Label("New Message", systemImage: "square.and.pencil") }
            }
        }
    }

    /// Select mode's bottom bar: what to do with every ticked conversation.
    @ToolbarContentBuilder private var bulkActions: some ToolbarContent {
        let chosen = model.targetThreads
        let none = model.multiSelection.isEmpty
        ToolbarItemGroup(placement: .bottomBar) {
            Button { act(.done) } label: { Label("Done", systemImage: "checkmark") }
                .disabled(none)
            Button { model.isSnoozePickerShown = true } label: { Label("Snooze", systemImage: "clock") }
                .disabled(none)
            Button { act(chosen.allSatisfy(\.isPinned) ? .unpin : .pin) } label: {
                Label("Pin", systemImage: !none && chosen.allSatisfy(\.isPinned) ? "pin.slash" : "pin")
            }
            .disabled(none)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Menu {
                Button("Mark as Read", systemImage: "envelope.open") { act(.markRead) }
                Button("Mark as Unread", systemImage: "envelope.badge") { act(.markUnread) }
                Button("Set Aside", systemImage: "arrowshape.turn.up.left.circle") { act(.replyLater) }
                Divider()
                if let first = chosen.first {
                    MoveMenuContent(thread: first, threads: chosen)
                }
                Button("Move to Folder…", systemImage: "folder") { model.isFolderPickerShown = true }
                if model.isInJunk {
                    Button("Not Junk", systemImage: "tray.and.arrow.down") { act(.moveToInbox) }
                } else {
                    Button("Move to Junk", systemImage: "xmark.bin") { act(.junk) }
                }
                Button("Move to Trash", systemImage: "trash", role: .destructive) { act(.trash) }
            } label: {
                Label("More Actions", systemImage: "ellipsis")
            }
            .disabled(none)
        }
    }

    /// Acts on the ticked conversations, then leaves Select mode.
    private func act(_ kind: TriageKind) {
        model.perform(kind)
        withAnimation(.snappy) { model.isSelecting = false }
    }

    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        let none = model.targetThreads.isEmpty
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.toggleContactPanel() } label: { Label("Contact Info", systemImage: "person.crop.circle") }
                .disabled(none)
            // What to do with it later, apart from answering it now (that's the reply button).
            Menu {
                Button("Reply Later", systemImage: "arrowshape.turn.up.left.circle") { model.toggleReplyLater() }
                Button("Read Later", systemImage: "book") { model.readLater() }
                Button("Add to Reminders", systemImage: "checklist") { model.addToReminders() }
                Divider()
                Button("Reply to Introduction", systemImage: "person.2.wave.2") { model.replyToIntroduction() }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
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
                    Button(model.isInJunk ? "Not Junk" : "Move to Junk",
                           systemImage: model.isInJunk ? "tray.and.arrow.down" : "xmark.bin") { model.toggleJunk() }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { model.perform(.trash) }
                }
            } label: {
                Label("Move to", systemImage: "tray.and.arrow.down")
            }
            .disabled(none)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // A tap opens just the three ways to answer, side by side in one row (as in Mail).
            Menu {
                ControlGroup {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { model.compose(.reply) }
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { model.compose(.replyAll) }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { model.compose(.forward) }
                }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .menuOrder(.fixed)
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
            .sheet(isPresented: $model.isFolderPickerShown, onDismiss: { model.isSelecting = false }) {
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
