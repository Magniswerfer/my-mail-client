import Foundation
import MailEngine

/// One-click unsubscribe and the Senders screen (SPEC §11). Unsubscribing always asks first.
struct UnsubscribeRequest: Identifiable {
    let id = UUID()
    var address: String
    var name: String
    var accountID: String
    var method: UnsubscribeMethod
    /// Conversations from them still in the Inbox (offered to archive along with it).
    var inboxCount: Int

    /// What will happen, in plain words, for the confirmation.
    var explanation: String {
        switch method {
        case .oneClick(let url): String(localized: "Tidings tells \(url.host() ?? name) you want no more of their mail. Nothing opens.")
        case .web(let url): String(localized: "Their unsubscribe page on \(url.host() ?? "the web") opens in your browser.")
        case .mail(let to, _, _): String(localized: "Tidings sends an unsubscribe email to \(to). You can undo it for a few seconds.")
        }
    }
}

extension AppModel {
    var listSenderOfSelection: String? {
        guard let message = targetThreads.first?.latest else { return nil }
        return message.isList ? message.fromAddress : nil
    }

    /// Looks up how to leave their list (from their newest message's headers), then asks.
    func requestUnsubscribe(address: String) {
        Task {
            guard let message = try? store.newestMessage(from: address), let sync = syncs[message.accountID] else {
                show(Toast(message: String(localized: "No mail from them on this device"), symbol: "envelope.badge"))
                return
            }
            let methods: [UnsubscribeMethod]
            do {
                methods = Unsubscribe.methods(in: MIMEParser.parse(try await sync.rawMessage(message)))
            } catch {
                show(Toast(message: String(localized: "Couldn't read their message: \(String(describing: error))"), symbol: "exclamationmark.triangle"))
                return
            }
            guard let method = methods.first else {
                show(Toast(message: String(localized: "\(message.senderDisplay) doesn't offer a way to unsubscribe"), symbol: "xmark.circle"))
                return
            }
            let inbox = ((try? store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)) ?? [])
                .filter { $0.latest.fromAddress.lowercased() == address.lowercased() }
            unsubscribeCandidate = UnsubscribeRequest(address: address, name: message.senderDisplay, accountID: message.accountID,
                                                      method: method, inboxCount: inbox.count)
        }
    }

    func confirmUnsubscribe(_ request: UnsubscribeRequest, archiveInbox: Bool) {
        unsubscribeCandidate = nil
        Task {
            var methodName = ""
            switch request.method {
            case .oneClick(let url):
                do {
                    try await Unsubscribe.postOneClick(url)
                    methodName = "oneClick"
                } catch {
                    show(Toast(message: String(localized: "Their server didn't accept it. Try their unsubscribe link in the message."),
                               symbol: "exclamationmark.triangle"))
                    return
                }
            case .web(let url):
                Platform.openExternally(url)
                methodName = "web"
            case .mail(let to, let subject, let body):
                guard let sync = syncs[request.accountID],
                      let from = accounts.first(where: { $0.id == request.accountID })?.identities?.first?.mailAddress else { return }
                let message = OutgoingMessage(from: from, to: [MailAddress(name: nil, address: to)], subject: subject,
                                              text: body.isEmpty ? "unsubscribe" : body)
                do {
                    _ = try await sync.queue(message)
                    reloadOutbox()
                    methodName = "mail"
                } catch {
                    lastError = String(localized: "Couldn't send the unsubscribe email: \(String(describing: error))")
                    return
                }
            }
            try? store.recordUnsubscribe(address: request.address, method: methodName)
            if archiveInbox { archiveInboxMail(from: request.address) }
            show(Toast(message: String(localized: "Unsubscribed from \(request.name)"), symbol: "hand.raised"))
            sendersRevision &+= 1
        }
    }

    /// Done for every Inbox conversation whose newest message is from this sender.
    func archiveInboxMail(from address: String) {
        let threads = ((try? store.threads(mailbox: "INBOX", ownAddresses: ownAddresses)) ?? [])
            .filter { $0.latest.fromAddress.lowercased() == address.lowercased() }
        guard !threads.isEmpty else { return }
        for (accountID, group) in Dictionary(grouping: threads, by: \.latest.accountID) {
            guard let sync = syncs[accountID] else { continue }
            Task {
                _ = try? await sync.perform(.done, threadIDs: group.map(\.threadID))
                reload()
                sendersRevision &+= 1
            }
        }
    }

    /// All mail from a sender, in search.
    func showMail(from address: String) {
        isSendersShown = false
        searchText = "from:\(address)"
    }
}

extension StoredMessage {
    /// Bulk mail from a list or with an unsubscribe link (as classified).
    var isList: Bool {
        guard let reason = classificationReason.flatMap(ClassificationReason.init(encoded:)) else { return false }
        switch reason {
        case .mailingListUnsubscribe, .mailingList: return true
        default: return false
        }
    }
}
