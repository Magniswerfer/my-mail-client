import Foundation
import MailEngine
import SwiftUI

/// Assistant settings (Settings → Assistant). UserDefaults-backed so views can use @AppStorage.
enum AssistSettings {
    static let summariesKey = "assist.summaries"
    static let autoDraftsKey = "assist.autoDrafts"
    static let followUpDaysKey = "assist.followUpDays"
    static let workdayStartKey = "assist.workdayStart"
    static let workdayEndKey = "assist.workdayEnd"
    static let sendAndDoneKey = "compose.sendAndDone"
    static var sendAndDone: Bool { UserDefaults.standard.object(forKey: sendAndDoneKey) as? Bool ?? true }

    static var summaries: Bool { UserDefaults.standard.object(forKey: summariesKey) as? Bool ?? true }
    static var autoDrafts: Bool { UserDefaults.standard.object(forKey: autoDraftsKey) as? Bool ?? true }
    static var followUpDays: Int { UserDefaults.standard.object(forKey: followUpDaysKey) as? Int ?? 3 }
    static var workdayStart: Int { UserDefaults.standard.object(forKey: workdayStartKey) as? Int ?? 9 }
    static var workdayEnd: Int { UserDefaults.standard.object(forKey: workdayEndKey) as? Int ?? 17 }
}

extension AppModel {
    /// The on-device writer, created on first use (nil without Apple Intelligence).
    var assistant: (any MailWriter)? {
        if !writerChecked {
            writer = FoundationModelsWriter()
            writerChecked = true
        }
        return writer
    }

    // MARK: Auto Summarize

    /// What a conversation's summary would be made from, or nil when it's too short to need one.
    func summaryDigest(threadID: String) -> ThreadDigest? {
        guard AssistSettings.summaries else { return nil }
        let messages = messages(inThread: threadID)
        guard let latest = messages.last else { return nil }
        let digest = ThreadDigest(subject: latest.subject, messages: messages, ownAddresses: ownAddresses)
        return digest.isWorthSummarizing ? digest : nil
    }

    /// A stored summary when it's still current (no new message since), else nil.
    func cachedSummary(threadID: String, digest: ThreadDigest) -> String? {
        guard let cached = try? store.digest(threadID: threadID), cached.basis == digest.basis else { return nil }
        return cached.summary
    }

    /// Makes (and stores) a summary on device. Nil without Apple Intelligence or on failure.
    func makeSummary(threadID: String, digest: ThreadDigest) async -> String? {
        guard let writer = assistant, let summary = await writer.summarize(digest) else { return nil }
        try? store.saveDigest(threadID: threadID, basis: digest.basis, summary: summary)
        return summary
    }

    // MARK: Auto Drafts

    /// After each sync: retire follow-ups that got an answer, then draft new ones (a few per pass).
    func scheduleAutoDrafts() {
        _ = try? store.retireAnsweredAutoDrafts()
        reloadOutbox()
        guard AssistSettings.autoDrafts, autoDraftTask == nil else { return }
        autoDraftTask = Task { [weak self] in
            await self?.draftFollowUps()
            self?.autoDraftTask = nil
        }
    }

    private func draftFollowUps() async {
        let days = AssistSettings.followUpDays
        for account in accounts {
            let candidates = (try? store.followUpCandidates(accountID: account.id, ownAddresses: Set(account.addresses),
                                                             minDays: days, limit: 3)) ?? []
            for mine in candidates {
                guard let id = mine.id, let threadID = mine.threadID else { continue }
                do {
                    let raw = try await rawMessage(mine)
                    let parsed = MIMEParser.parse(raw)
                    let draft = Self.draft(.reply, replyingTo: parsed, raw: raw, account: account)
                    let recipient = parsed.to.first
                    let waited = max(days, Int(Date().timeIntervalSince(mine.date) / 86_400))
                    let request = FollowUpRequest(subject: parsed.subject, lastMessage: parsed.plainText,
                                                  recipientName: recipient.map(IntroReply.firstName), daysWaiting: waited)
                    let text = await assistant?.followUp(request) ?? Self.followUpTemplate(recipient: recipient)
                    let body = NSMutableAttributedString(string: text, attributes: RichTextEditor.baseAttributes)
                    body.append(draft.body)
                    let outboxID = saveDraft(draft.message, body: body, accountID: account.id, kind: .reply, originalLocalID: id)
                    try store.saveAutoDraft(AutoDraft(threadID: threadID, accountID: account.id, outboxID: outboxID, messageID: id))
                } catch {
                    // Offline or the message is gone: try again after the next sync.
                    continue
                }
            }
        }
        reloadOutbox()
    }

    /// Without Apple Intelligence: a plain nudge in the app's language.
    static func followUpTemplate(recipient: MailAddress?) -> String {
        let nudge = String(localized: "Just following up on my email below. Let me know what you think when you have a moment.")
        guard let recipient else { return nudge }
        return String(localized: "Hi \(IntroReply.firstName(recipient)),") + "\n\n" + nudge
    }

    /// The waiting follow-up for a conversation, if any.
    func autoDraft(forThread threadID: String) -> AutoDraft? {
        autoDrafts.first { $0.threadID == threadID }
    }

    func reviewFollowUp(threadID: String) {
        guard let id = autoDraft(forThread: threadID)?.outboxID else { return }
        openComposeWindow?(id)
    }

    func dismissFollowUp(threadID: String) {
        try? store.dismissAutoDraft(threadID: threadID)
        reloadOutbox()
        show(Toast(message: String(localized: "Follow-up discarded. Tidings won't draft one for this conversation again."),
                   symbol: "xmark.circle"))
    }

    // MARK: Contact sidebar

    /// Whose profile the contact panel shows: the chosen person, else the other side of the
    /// open conversation.
    var contactPanelAddress: String? {
        if let contactAddress { return contactAddress }
        guard let threadID = readerThreadID else { return nil }
        let mine = Set(ownAddresses.map { $0.lowercased() })
        let messages = messages(inThread: threadID)
        if let other = messages.last(where: { !mine.contains($0.fromAddress.lowercased()) }) { return other.fromAddress }
        // Only your own messages: whoever you wrote to.
        return messages.last.flatMap { AddressParser.parse($0.recipients).first { !mine.contains($0.address.lowercased()) }?.address }
    }

    func contactProfile(_ address: String) -> ContactProfile? {
        try? store.contactProfile(address: address, ownAddresses: ownAddresses)
    }

    func showContact(_ address: String?) {
        contactAddress = address
        isContactPanelShown = true
    }

    func toggleContactPanel() {
        contactAddress = nil
        isContactPanelShown.toggle()
    }
}
