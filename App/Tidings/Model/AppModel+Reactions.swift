import Foundation
import MailEngine

/// Email reactions ("likes"): Outlook's, Gmail's and RFC 9078's, shown on the message they're
/// about; yours go out in a form all three understand (the engine's `OutgoingMessage.reaction`).
extension AppModel {
    /// Outlook's six, in its order.
    static let reactionChoices = ["👍", "❤️", "🎉", "😆", "😮", "😢"]

    /// Reactions on these messages, by local id: theirs from the store, yours as you last set it.
    func reactions(on messages: [StoredMessage]) -> [Int64: [MailReaction]] {
        let ids = messages.compactMap(\.messageID)
        guard !ids.isEmpty else { return [:] }
        let stored = storedReactions(ids.map(Self.bareMessageID))
        var result: [Int64: [MailReaction]] = [:]
        for message in messages {
            guard let id = message.id, let messageID = message.messageID else { continue }
            let key = Self.bareMessageID(messageID)
            var list = stored[key] ?? []
            if let mine = sentReactions[key] {
                list.removeAll(where: \.isMine)
                if !mine.isEmpty, let me = reactionIdentity(for: message) {
                    list.append(MailReaction(emoji: mine, fromAddress: me.address, fromName: me.name, date: Date(), isMine: true))
                }
            }
            if !list.isEmpty { result[id] = list }
        }
        return result
    }

    /// Whether you can react to this message: someone else's, with a Message-ID, and not one
    /// whose sender asked for no reactions (Outlook's `x-ms-reactions: disallow`).
    func canReact(to message: StoredMessage) -> Bool {
        message.messageID != nil && !message.reactionsDisallowed && !message.isReaction
            && !ownAddresses.contains { $0.caseInsensitiveCompare(message.fromAddress) == .orderedSame }
    }

    /// Your reaction now (sent this session, else synced back).
    func myReaction(to message: StoredMessage) -> String? {
        guard let messageID = message.messageID else { return nil }
        let key = Self.bareMessageID(messageID)
        if let sent = sentReactions[key] { return sent.isEmpty ? nil : sent }
        return storedReactions([key])[key]?.first(where: \.isMine)?.emoji
    }

    /// Reactions in the store by bare Message-ID, read once per revision: the reader and every
    /// hovered message's ribbon and menu ask again on each redraw.
    private func storedReactions(_ keys: [String]) -> [String: [MailReaction]] {
        if reactionCache.revision != revision { reactionCache = (revision, [:]) }
        let missing = Array(Set(keys.filter { reactionCache.byKey[$0] == nil }))
        if !missing.isEmpty {
            let found = (try? store.reactions(toMessageIDs: missing, ownAddresses: ownAddresses)) ?? [:]
            for key in missing { reactionCache.byKey[key] = found[key] ?? [] }
        }
        var result: [String: [MailReaction]] = [:]
        for key in keys { if let list = reactionCache.byKey[key], !list.isEmpty { result[key] = list } }
        return result
    }

    /// Reacts with `emoji`, or takes your reaction back when it's the one you already gave.
    func toggleReaction(_ emoji: String, to message: StoredMessage) {
        guard canReact(to: message), let messageID = message.messageID,
              let sync = syncs[message.accountID], let identity = reactionIdentity(for: message) else { return }
        let send = myReaction(to: message) == emoji ? "" : emoji
        let caption = send.isEmpty ? nil : String(localized: "\(identity.name.isEmpty ? identity.address : identity.name) reacted to your message")
        guard let outgoing = OutgoingMessage.reaction(send, from: identity.mailAddress, to: message, caption: caption) else { return }
        sentReactions[Self.bareMessageID(messageID)] = send
        Task {
            do { _ = try await sync.queue(outgoing, sendAt: Date(), kind: .new) }
            catch { lastError = String(localized: "Couldn't send the reaction: \(String(describing: error))") }
            reloadOutbox()
        }
    }

    /// ⌘K "Like": 👍 on the newest message of the selected conversation that you can react to.
    func likeSelected() {
        guard let thread = targetThreads.first,
              let message = readerMessages(inThread: thread.threadID).last(where: canReact) else { return }
        toggleReaction("👍", to: message)
    }

    /// The address the message came to, else the account's first.
    private func reactionIdentity(for message: StoredMessage) -> Identity? {
        let all = identities(for: message.accountID)
        let recipients = message.recipients.lowercased()
        return all.first { recipients.contains($0.address.lowercased()) } ?? all.first
    }

    static func bareMessageID(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }
}
