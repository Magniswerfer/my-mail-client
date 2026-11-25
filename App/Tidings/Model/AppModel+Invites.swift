import Foundation
import MailEngine
import SwiftUI

/// Meeting invitations: answer the organizer, keep the calendar in step, show what's waiting.
extension AppModel {
    /// The invitation a conversation is about: its newest invite/update/cancellation (answers
    /// from attendees don't count).
    func invite(inThread threadID: String) -> (message: StoredMessage, invite: CalendarInvite)? {
        for message in messages(inThread: threadID).reversed() {
            if let invite = message.invite, invite.method != .reply { return (message, invite) }
        }
        return nil
    }

    /// The selected conversation's invite, if it's one you can answer (for keys, menu and ⌘K).
    var answerableInvite: (message: StoredMessage, invite: CalendarInvite)? {
        guard let thread = targetThreads.first, let found = invite(inThread: thread.threadID),
              found.invite.method == .request, !found.invite.isCancelled,
              found.invite.organizer != nil, !found.invite.isOrganized(by: ownAddresses) else { return nil }
        return found
    }

    /// Your current answer: the newest of what you sent (from any client) and what the invite says.
    func myResponse(to invite: CalendarInvite, accountID: String) -> CalendarInvite.ParticipationStatus? {
        if let sent = try? store.inviteResponse(accountID: accountID, uid: invite.uid), sent.sequence >= invite.sequence {
            return sent.status
        }
        let mine = invite.attendee(matching: ownAddresses)?.status
        return mine == .needsAction ? nil : mine
    }

    /// Accept / Maybe / Decline: mails the answer to the organizer (through the outbox, so the
    /// usual undo-send window applies) and adds, updates or removes the calendar copy.
    func respond(_ status: CalendarInvite.ParticipationStatus, to invite: CalendarInvite, message: StoredMessage) {
        guard let account = accounts.first(where: { $0.id == message.accountID }), let sync = syncs[account.id] else {
            lastError = String(localized: "This account is offline, so the answer can't be sent yet.")
            return
        }
        let invited = Set(invite.attendees.map { $0.address.lowercased() })
        let identity = account.sendingIdentities.first { invited.contains($0.address.lowercased()) }
            ?? account.sendingIdentities.first ?? Identity(address: account.endpoint.username, name: "")
        let me = identity.mailAddress
        let who = me.name.flatMap { $0.isEmpty ? nil : $0 } ?? me.address
        let (subject, text, symbol): (String, String, String) = switch status {
        case .accepted: (String(localized: "Accepted: \(invite.summary)"), String(localized: "\(who) has accepted this invitation."), "checkmark.circle")
        case .tentative: (String(localized: "Tentative: \(invite.summary)"), String(localized: "\(who) might attend."), "questionmark.circle")
        default: (String(localized: "Declined: \(invite.summary)"), String(localized: "\(who) has declined this invitation."), "xmark.circle")
        }
        var references = [String]()
        if let id = message.messageID { references.append(id) }
        guard let reply = invite.replyMessage(from: me, status: status, subject: subject, text: text,
                                              inReplyTo: message.messageID, references: references) else { return }

        let previous = try? store.inviteResponse(accountID: account.id, uid: invite.uid)
        let response = InviteResponse(accountID: account.id, uid: invite.uid, sequence: invite.sequence,
                                      status: status, respondedAt: Date())
        try? store.recordInviteResponse(response)
        revision &+= 1

        Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await sync.queue(reply, kind: .reply, originalLocalID: message.id)
                reloadOutbox()
                let organizer = invite.organizer?.display ?? ""
                let toastText = switch status {
                case .accepted: String(localized: "Accepted. Telling \(organizer)…")
                case .tentative: String(localized: "Maybe. Telling \(organizer)…")
                default: String(localized: "Declined. Telling \(organizer)…")
                }
                let undo: @MainActor () -> Void = { [weak self] in
                    self?.undoResponse(outboxID: item.id, invite: invite, accountID: account.id, previous: previous)
                }
                undoManager?.registerUndo(withTarget: self) { _ in MainActor.assumeIsolated { undo() } }
                undoManager?.setActionName(String(localized: "Answer"))
                show(Toast(message: toastText, symbol: symbol, undoAction: undo))
            } catch {
                lastError = String(localized: "Couldn't send your answer: \(String(describing: error))")
            }
            await updateCalendar(for: invite, status: status)
        }
    }

    /// Takes the answer back while it's still in the outbox.
    private func undoResponse(outboxID: Int64?, invite: CalendarInvite, accountID: String, previous: InviteResponse?) {
        guard let outboxID, let sync = syncs[accountID] else { return }
        Task {
            guard (try? await sync.cancelSend(id: outboxID)) != nil else {
                show(Toast(message: String(localized: "Too late, your answer is already sent"), symbol: "paperplane"))
                return
            }
            try? store.deleteOutboxItem(id: outboxID)
            try? store.forgetInviteResponse(accountID: accountID, uid: invite.uid)
            if let previous { try? store.recordInviteResponse(previous) }
            if previous?.status != .accepted, previous?.status != .tentative { try? CalendarBridge.shared.remove(invite) }
            reloadOutbox()
            revision &+= 1
            toast = nil
        }
    }

    func updateCalendar(for invite: CalendarInvite, status: CalendarInvite.ParticipationStatus) async {
        let calendar = CalendarBridge.shared
        switch status {
        case .accepted, .tentative:
            guard await calendar.requestAccess() else { return }
            do { try calendar.save(invite, tentative: status == .tentative) } catch {
                lastError = String(localized: "Couldn't add it to your calendar: \(error.localizedDescription)")
            }
        default:
            try? calendar.remove(invite)
        }
        revision &+= 1
    }

    /// "Add to Calendar" for invites you don't answer (PUBLISH: tickets, bookings) or already
    /// answered elsewhere.
    func addToCalendar(_ invite: CalendarInvite) {
        Task {
            guard await CalendarBridge.shared.requestAccess() else {
                show(Toast(message: Platform.calendarSettingsHint,
                           symbol: "calendar.badge.exclamationmark"))
                return
            }
            do {
                try CalendarBridge.shared.save(invite)
                show(Toast(message: String(localized: "Added to your calendar"), symbol: "calendar.badge.plus"))
            } catch {
                lastError = String(localized: "Couldn't add it to your calendar: \(error.localizedDescription)")
            }
            revision &+= 1
        }
    }

    func removeFromCalendar(_ invite: CalendarInvite) {
        try? CalendarBridge.shared.remove(invite)
        show(Toast(message: String(localized: "Removed from your calendar"), symbol: "calendar.badge.minus"))
        revision &+= 1
    }

    /// A newer version of an event you already put in your calendar moves it there too, and a
    /// cancellation takes it out. Runs when the reader shows the invite.
    func syncCalendarCopy(_ invite: CalendarInvite) {
        let calendar = CalendarBridge.shared
        guard calendar.hasAccess, calendar.isLinked(invite) else { return }
        if invite.isCancelled {
            try? calendar.remove(invite)
        } else if invite.method == .request, let event = calendar.existingEvent(for: invite),
                  event.startDate != calendar.localRange(invite).0 || event.title != invite.summary
                    || event.location != invite.location {
            try? calendar.save(invite, tentative: event.availability == .tentative)
        }
    }

    func respondToSelectedInvite(_ status: CalendarInvite.ParticipationStatus) {
        guard let found = answerableInvite else { return }
        respond(status, to: found.invite, message: found.message)
    }
}
