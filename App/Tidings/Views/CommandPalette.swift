import MailEngine
import SwiftUI

/// Every action lives here once: the ⌘K palette, the key handler and the menus read from it
/// (CLAUDE.md: every action is keyboard-reachable and in the palette).
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Shortcut as shown to the user, e.g. "E", "G I", "⌘⇧E".
    let keys: String?
    var isEnabled = true
    let run: @MainActor () -> Void
}

extension AppModel {
    var commands: [AppCommand] {
        let hasSelection = !targetThreads.isEmpty
        let thread = targetThreads.first
        let inSnoozedOrFolder = sourceMailbox != "INBOX"
        var list: [AppCommand] = [
            AppCommand(id: "compose", title: String(localized: "New Message"), symbol: "square.and.pencil", keys: "C") { self.composeNew() },
            AppCommand(id: "reply", title: String(localized: "Reply"), symbol: "arrowshape.turn.up.left", keys: "R",
                       isEnabled: hasSelection) { self.compose(.reply) },
            AppCommand(id: "replyAll", title: String(localized: "Reply All"), symbol: "arrowshape.turn.up.left.2", keys: "A",
                       isEnabled: hasSelection) { self.compose(.replyAll) },
            AppCommand(id: "forward", title: String(localized: "Forward"), symbol: "arrowshape.turn.up.right", keys: "F",
                       isEnabled: hasSelection) { self.compose(.forward) },
            AppCommand(id: "goOutbox", title: String(localized: "Go to Outbox"), symbol: "paperplane", keys: "G O") { self.selection = .outbox },
            AppCommand(id: "done", title: String(localized: "Mark Done"), symbol: "checkmark.circle", keys: "E",
                       isEnabled: hasSelection) { self.perform(.done) },
            AppCommand(id: "pin", title: thread?.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin"),
                       symbol: "pin", keys: "P", isEnabled: hasSelection) { self.togglePin() },
            AppCommand(id: "snooze", title: String(localized: "Snooze…"), symbol: "clock", keys: "B",
                       isEnabled: hasSelection) { self.isSnoozePickerShown = true },
            AppCommand(id: "read", title: thread?.unreadCount ?? 0 > 0 ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                       symbol: "envelope.open", keys: "U", isEnabled: hasSelection) { self.toggleRead() },
            AppCommand(id: "trash", title: String(localized: "Move to Trash"), symbol: "trash", keys: "#",
                       isEnabled: hasSelection) { self.perform(.trash) },
            AppCommand(id: "junk", title: String(localized: "Move to Junk"), symbol: "xmark.bin", keys: "!",
                       isEnabled: hasSelection) { self.perform(.junk) },
            AppCommand(id: "inbox", title: String(localized: "Move to Inbox"), symbol: "tray.and.arrow.down", keys: "I",
                       isEnabled: hasSelection && inSnoozedOrFolder) {
                self.perform(self.selection == .snoozed ? .unsnooze : .moveToInbox)
            },
            AppCommand(id: "sweep", title: String(localized: "Sweep Inbox (Done for all unpinned)"), symbol: "checkmark.rectangle.stack",
                       keys: "⌘⇧E", isEnabled: selection == .inbox) { self.requestSweep() },
            AppCommand(id: "undo", title: String(localized: "Undo"), symbol: "arrow.uturn.backward", keys: "⌘Z",
                       isEnabled: undoManager?.canUndo == true) { self.undoManager?.undo() },
            AppCommand(id: "pinnedOnly", title: pinnedOnly ? String(localized: "Show All Conversations") : String(localized: "Show Only Pinned"),
                       symbol: "pin.circle", keys: "G P") { self.pinnedOnly.toggle() },
            AppCommand(id: "next", title: String(localized: "Next Conversation"), symbol: "chevron.down", keys: "J") { self.moveSelection(1) },
            AppCommand(id: "previous", title: String(localized: "Previous Conversation"), symbol: "chevron.up", keys: "K") { self.moveSelection(-1) },
            AppCommand(id: "goInbox", title: String(localized: "Go to Inbox"), symbol: "tray", keys: "G I") { self.selection = .inbox },
            AppCommand(id: "goSnoozed", title: String(localized: "Go to Snoozed"), symbol: "clock", keys: "G S") { self.selection = .snoozed },
        ]
        for account in accounts {
            for box in mailboxes where box.accountID == account.id && box.role == .archive {
                list.append(AppCommand(id: "goArchive-\(account.id)", title: String(localized: "Go to Archive"), symbol: "archivebox",
                                       keys: "G A") { self.selection = .mailbox(accountID: account.id, path: box.path) })
            }
        }
        for category in MailCategory.allCases {
            list.append(AppCommand(id: "bundle-\(category.rawValue)", title: String(localized: "Go to \(category.title)"),
                                   symbol: category.symbol, keys: nil) { self.selection = .category(category) })
        }
        return list
    }

    func run(commandID: String) {
        guard let command = commands.first(where: { $0.id == commandID }), command.isEnabled else { return }
        command.run()
    }

    func goToArchive() {
        if let box = mailboxes.first(where: { $0.role == .archive }) {
            selection = .mailbox(accountID: box.accountID, path: box.path)
        }
    }
}

/// ⌘K: type to filter every command, ↑↓ to choose, Return to run.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let matches = filtered
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { runHighlighted(matches) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            row(command, highlighted: index == highlighted)
                                .id(command.id)
                                .onTapGesture { run(command) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .onChange(of: highlighted) { _, i in
                    if matches.indices.contains(i) { proxy.scrollTo(matches[i].id) }
                }
            }
        }
        .frame(width: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(radius: 30, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, matches.count - 1)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { model.isPaletteShown = false; return .handled }
    }

    private var filtered: [AppCommand] {
        let words = query.lowercased().split(separator: " ")
        let all = model.commands.filter(\.isEnabled)
        guard !words.isEmpty else { return all }
        return all.filter { command in
            let haystack = "\(command.title) \(command.keys ?? "")".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func row(_ command: AppCommand, highlighted: Bool) -> some View {
        HStack {
            Image(systemName: command.symbol).frame(width: 22)
            Text(command.title)
            Spacer()
            if let keys = command.keys {
                Text(keys)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func runHighlighted(_ matches: [AppCommand]) {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    private func run(_ command: AppCommand) {
        model.isPaletteShown = false
        command.run()
    }
}

/// B: snooze presets (1–5) or a specific date.
struct SnoozePicker: View {
    @Environment(AppModel.self) private var model
    @State private var presets = SnoozePreset.all()
    @State private var custom = Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze until…").font(.headline)
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                Button { model.snooze(preset) } label: {
                    HStack {
                        Image(systemName: preset.symbol).frame(width: 22)
                        Text(preset.title)
                        Spacer()
                        Text(preset.detail).foregroundStyle(.secondary)
                        Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
            Divider()
            HStack {
                DatePicker("Pick a date", selection: $custom, in: Date()...)
                    .labelsHidden()
                Spacer()
                Button("Snooze") { model.snooze(until: custom) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// "Marked done · Undo", floating in Liquid Glass at the bottom of the stream.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Label(toast.message, systemImage: toast.symbol)
            if let box = toast.undo {
                Button("Undo") { model.undoFromToast(box) }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            } else if let outboxID = toast.undoSend {
                Button("Undo") { model.undoSend(outboxID) }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
