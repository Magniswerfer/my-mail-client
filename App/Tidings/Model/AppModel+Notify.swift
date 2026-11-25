import AppIntents
import Foundation
import MailEngine
import SwiftUI

/// What interrupts you (SPEC §10). Never per bundle message.
enum NotifyMode: String, CaseIterable, Identifiable {
    case people     // Primary mail from people, VIPs, pinned conversations, replies you're waiting for
    case vipsOnly
    case off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: String(localized: "People in Primary, VIPs and replies")
        case .vipsOnly: String(localized: "VIPs only")
        case .off: String(localized: "Off")
        }
    }
}

enum NotifySettings {
    static let modeKey = "notify.mode"
    static let vipsKey = "notify.vips"
    static let lastIDKey = "notify.lastMessageID"
    static let focusVIPOnlyKey = "notify.focusVIPOnly"

    static var mode: NotifyMode { UserDefaults.standard.string(forKey: modeKey).flatMap(NotifyMode.init) ?? .people }
    static var vips: [String] {
        get { UserDefaults.standard.stringArray(forKey: vipsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: vipsKey) }
    }
    /// Set by the Focus filter.
    static var focusVIPOnly: Bool { UserDefaults.standard.bool(forKey: focusVIPOnlyKey) }
}

extension AppModel {
    /// After each sync: notify about new Inbox mail worth it, at most a handful at a time.
    func notifyNewMail() {
        let defaults = UserDefaults.standard
        guard let last = defaults.object(forKey: NotifySettings.lastIDKey) as? Int64 else {
            // First run: start from here, don't announce the backlog.
            defaults.set((try? store.maxMessageID()) ?? 0, forKey: NotifySettings.lastIDKey)
            seedVIPsIfNeeded()
            return
        }
        let fresh = (try? store.inboxMessages(after: last)) ?? []
        guard let newest = fresh.last?.id else { return }
        defaults.set(newest, forKey: NotifySettings.lastIDKey)
        let mode = NotifySettings.focusVIPOnly ? .vipsOnly : NotifySettings.mode
        guard mode != .off else { return }
        let waiting = Set((try? store.waitingForReplyThreadIDs(ownAddresses: ownAddresses)) ?? [])
        let vips = Set(NotifySettings.vips.map { $0.lowercased() })
        var worth: [(StoredMessage, String?)] = []
        for message in fresh {
            guard message.isUnread, !ownAddresses.contains(message.fromAddress.lowercased()),
                  Date().timeIntervalSince(message.date) < 6 * 3_600, !isMuted(message.threadID) else { continue }
            if vips.contains(message.fromAddress.lowercased()) { worth.append((message, String(localized: "VIP"))); continue }
            guard mode == .people else { continue }
            let threadID = message.threadID ?? ""
            let previous = messages(inThread: threadID).filter { $0.id != message.id }.last
            let answersYou = previous.map { ownAddresses.contains($0.fromAddress.lowercased()) } ?? false
            if waiting.contains(threadID) || answersYou {
                worth.append((message, String(localized: "Reply")))
            } else if threads.first(where: { $0.threadID == threadID })?.isPinned == true {
                worth.append((message, String(localized: "Pinned")))
            } else if message.category == .primary, !SignatureInfo.looksAutomated(message.fromAddress) {
                worth.append((message, nil))
            }
        }
        guard !worth.isEmpty else { return }
        Task {
            for (message, reason) in worth.prefix(5) { await Notifier.shared.notify(message: message, reason: reason) }
        }
    }

    func isMuted(_ threadID: String?) -> Bool {
        guard let threadID else { return false }
        return messages(inThread: threadID).contains { $0.flags.contains(mutedKeyword) }
    }

    // MARK: VIPs

    func seedVIPsIfNeeded() {
        guard UserDefaults.standard.object(forKey: NotifySettings.vipsKey) == nil else { return }
        NotifySettings.vips = ((try? store.topCorrespondents(ownAddresses: ownAddresses, limit: 8)) ?? []).map(\.address)
    }

    var vips: [String] { NotifySettings.vips }

    func isVIP(_ address: String) -> Bool { NotifySettings.vips.contains { $0.caseInsensitiveCompare(address) == .orderedSame } }

    func toggleVIP(_ address: String) {
        var list = NotifySettings.vips
        if let i = list.firstIndex(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            list.remove(at: i)
            show(Toast(message: String(localized: "Removed \(address) from VIPs"), symbol: "star.slash"))
        } else {
            list.append(address.lowercased())
            show(Toast(message: String(localized: "\(address) is a VIP: you'll always be notified"), symbol: "star.fill"))
        }
        NotifySettings.vips = list
        revision &+= 1
    }

    /// The sender of the selected conversation (for ⌘K / context menu).
    func toggleVIPForSelection(_ thread: ThreadSummary? = nil) {
        guard let thread = thread ?? targetThreads.first else { return }
        let sender = messages(inThread: thread.threadID).last { !ownAddresses.contains($0.fromAddress.lowercased()) } ?? thread.latest
        toggleVIP(sender.fromAddress)
    }
}

// MARK: - Settings

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NotifySettings.modeKey) private var mode = NotifyMode.people.rawValue
    @State private var vips: [String] = NotifySettings.vips
    @State private var newVIP = ""

    var body: some View {
        Form {
            Section {
                Picker("Notify me about", selection: $mode) {
                    ForEach(NotifyMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Never for bundles or newsletters. A Focus can limit this to VIPs (Settings › Focus › Focus Filters).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(vips, id: \.self) { address in
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(address)
                        Spacer()
                        Button(role: .destructive) { remove(address) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add address", text: $newVIP, prompt: Text(verbatim: "anna@example.com"))
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!newVIP.contains("@"))
                }
                Button("Suggest From My Mail") {
                    let suggested = ((try? model.store.topCorrespondents(ownAddresses: model.ownAddresses, limit: 8)) ?? []).map(\.address)
                    for address in suggested where !vips.contains(address) { vips.append(address) }
                    NotifySettings.vips = vips
                }
            } header: {
                Text("VIPs")
            } footer: {
                Text("Mail from VIPs always notifies you, in any category. Suggestions are the people you write to most.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let a = newVIP.trimmingCharacters(in: .whitespaces).lowercased()
        guard a.contains("@"), !vips.contains(a) else { return }
        vips.append(a)
        NotifySettings.vips = vips
        newVIP = ""
    }

    private func remove(_ address: String) {
        vips.removeAll { $0 == address }
        NotifySettings.vips = vips
    }
}

// MARK: - Focus filter

/// Settings › Focus › (a Focus) › Focus Filters › Tidings: only VIPs while that Focus is on.
struct TidingsFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Tidings Notifications"
    static let description = IntentDescription("Only notify about VIPs while this Focus is on.")

    @Parameter(title: "Only VIPs", default: true)
    var onlyVIPs: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: onlyVIPs ? "Only VIPs" : "Usual notifications")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(onlyVIPs, forKey: NotifySettings.focusVIPOnlyKey)
        return .result()
    }
}
