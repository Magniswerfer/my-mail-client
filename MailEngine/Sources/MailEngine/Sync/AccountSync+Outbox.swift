import Foundation

extension AccountSync {
    /// The undo-send window (SPEC §9: default 10 s).
    public static let defaultUndoSendDelay: TimeInterval = 10

    /// Does the server file its own copy of sent mail into Sent? Learned on the first send.
    enum SentCopyPolicy: String { case server, client }
    static let sentCopyKey = "sentCopyPolicy"

    // MARK: Queueing

    /// Queues a message. It sends at `sendAt` (now + the undo window by default), so until then
    /// `cancelSend` can take it back.
    @discardableResult
    public func queue(_ message: OutgoingMessage, sendAt: Date? = nil, kind: ComposeKind = .new,
                      originalLocalID: Int64? = nil, replacingDraft draftID: Int64? = nil) throws -> OutboxItem {
        var item = OutboxItem(accountID: account.id, message: message, state: .queued,
                              sendAt: sendAt ?? Date().addingTimeInterval(Self.defaultUndoSendDelay),
                              kind: kind, originalLocalID: originalLocalID)
        item.id = draftID
        item = try store.save(item)
        signalWork()
        return item
    }

    /// Undo send: back to a draft, if it hasn't started sending. Returns the draft.
    public func cancelSend(id: Int64) throws -> OutboxItem? {
        guard var item = try store.outboxItem(id: id), item.state == .queued || item.state == .failed || item.state == .remote else { return nil }
        item.state = .draft
        item.sendAt = nil
        item.lastError = nil
        return try store.save(item)
    }

    /// Handed to the push server (ADR 0007): it sends from there, so this device never does.
    /// `cancelSend` takes it back once the server has let go of it.
    public func markHandedOff(id: Int64) throws {
        guard var item = try store.outboxItem(id: id), item.state == .queued else { return }
        item.state = .remote
        _ = try store.save(item)
    }

    /// Retry a failed message now.
    public func retrySend(id: Int64) throws {
        guard var item = try store.outboxItem(id: id) else { return }
        item.state = .queued
        item.sendAt = Date()
        item.attempts = 0
        item.lastError = nil
        try store.save(item)
        signalWork()
    }

    // MARK: Sending

    var smtpEndpoint: SMTPEndpoint {
        account.smtp ?? .iCloud(address: account.endpoint.username)
    }

    /// Sends everything that's due. Runs on the sync loop's IMAP session (for the Sent copy and
    /// the \Answered flag); SMTP gets its own short-lived connection per message.
    func sendDue(_ session: MailSession) async throws {
        for listed in try store.dueOutbox(accountID: account.id) {
            // Re-read each one: while the previous message was being sent (an await), this one
            // may have been undone, edited or handed to the push server. Nothing awaits between
            // this check and the save below, so the actor makes the two one step.
            guard let id = listed.id, var item = try store.outboxItem(id: id), item.state == .queued,
                  let sendAt = item.sendAt, sendAt <= Date(), let message = item.message else { continue }
            item.state = .sending
            item = try store.save(item)
            emit(.sending(outboxID: id))

            let raw = MIMEBuilder.build(message)
            let sentPath = try path(for: .sent) ?? "Sent Messages"
            let policy = (try store.setting(Self.sentCopyKey, accountID: account.id)).flatMap(SentCopyPolicy.init)
            let sentBefore = policy == nil ? try? await session.select(sentPath, readOnly: true).uidNext : nil

            do {
                try await SMTPClient.send(endpoint: smtpEndpoint, password: password, from: message.from.address,
                                          recipients: message.envelopeRecipients, message: raw)
            } catch {
                // SMTP 4xx, timeouts and network errors (refused, offline) are retried with
                // backoff; 5xx and auth errors wait for the user.
                let smtpError = error as? SMTPError
                let transient = smtpError?.isTransient ?? true
                item.attempts += 1
                item.lastError = smtpError?.description ?? error.localizedDescription
                if transient, item.attempts < 6 {
                    item.state = .queued
                    item.sendAt = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(item.attempts - 1))))
                } else {
                    item.state = .failed
                }
                try store.save(item)
                emit(.sendFailed(outboxID: id, message: item.lastError ?? ""))
                continue
            }

            // Sent. From here on nothing may re-send it: drop it from the outbox first.
            try store.deleteOutboxItem(id: id)
            emit(.sent(outboxID: id))
            try await fileSentCopy(raw: raw, messageID: message.messageID, sentPath: sentPath, policy: policy,
                                   uidNextBefore: sentBefore ?? nil, session: session)
            try markOriginal(item)
        }
    }

    /// Puts a copy in Sent unless the server already does (learned once, then remembered).
    func fileSentCopy(raw: Data, messageID: String, sentPath: String, policy: SentCopyPolicy?,
                      uidNextBefore: UInt32?, session: MailSession) async throws {
        var policy = policy
        if policy == nil {
            policy = .client
            if let from = uidNextBefore {
                for delay in [2, 4, 6] {   // give the server ~12 s to file its own copy
                    try await Task.sleep(for: .seconds(delay))
                    _ = try await session.select(sentPath, readOnly: true)
                    let ids = try await session.fetchHeaderField("Message-ID", fromUID: from)
                    if ids.values.contains(where: { $0.contains(messageID) }) { policy = .server; break }
                }
            }
            try store.setSetting(Self.sentCopyKey, policy!.rawValue, accountID: account.id)
        }
        if policy == .client {
            try await session.ensureMailbox(sentPath)
            try await session.append(to: sentPath, message: raw, flags: ["\\Seen"])
        }
    }

    /// Replied → \Answered, forwarded → $Forwarded, through the normal triage queue.
    func markOriginal(_ item: OutboxItem) throws {
        guard let original = item.originalLocalID, item.kind != .new else { return }
        // A reply sent from another account's address: the original isn't ours to flag (its
        // local id means nothing on this account's server).
        guard (try? store.message(id: original))?.accountID == account.id else { return }
        let flag = item.kind == .forward ? "$Forwarded" : "\\Answered"
        try store.db.write { db in
            try store.applyLocalFlags(localIDs: [original], add: [flag], remove: [], in: db)
            try store.enqueue(.flags(localIDs: [original], add: [flag], remove: []),
                              accountID: account.id, changeID: UUID().uuidString, in: db)
        }
        signalWork()
    }

    /// Sends what's due on a fresh connection (when the sync loop isn't running, e.g. tests).
    public func processOutbox() async throws {
        try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            try await self.sendDue(session)
            try await self.drain(session)
        }
    }
}
