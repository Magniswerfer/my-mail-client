import Foundation

extension AccountSync {
    /// The undo-send window (SPEC §9: default 10 s).
    public static let defaultUndoSendDelay: TimeInterval = 10

    /// Does the server file its own copy of sent mail into Sent? Learned on the first send.
    enum SentCopyPolicy: String { case server, client }
    static let sentCopyKey = "sentCopyPolicy"

    /// Where a copy of sent mail goes when the account has no Sent folder yet (iCloud's name).
    static let fallbackSentFolder = "Sent Messages"

    /// Transient SMTP failures are retried this many times in all, with exponential backoff.
    static let maxSendAttempts = 6
    static let firstRetryDelay: TimeInterval = 30
    static let maxRetryDelay: TimeInterval = 3600

    /// The pauses while watching Sent for the server's own copy on the first send (~12 s in all).
    static let serverCopyChecks: [Duration] = [.seconds(2), .seconds(4), .seconds(6)]

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
            let sentPath = try path(for: .sent) ?? Self.fallbackSentFolder
            let policy = (try store.setting(Self.sentCopyKey, accountID: account.id)).flatMap(SentCopyPolicy.init)
            let sentBefore = policy == nil ? try? await session.select(sentPath, readOnly: true).uidNext : nil

            do {
                try await SMTPClient.send(endpoint: smtpEndpoint, password: password, from: message.from.address,
                                          recipients: message.envelopeRecipients, message: raw)
            } catch {
                try recordSendFailure(error, of: &item)
                emit(.sendFailed(outboxID: id, message: item.lastError ?? ""))
                continue
            }

            // Sent. From here on nothing may re-send it: drop it from the outbox first.
            try store.deleteOutboxItem(id: id)
            emit(.sent(outboxID: id))
            do {
                try await fileSentCopy(raw: raw, messageID: message.messageID, sentPath: sentPath, policy: policy,
                                       uidNextBefore: sentBefore ?? nil, session: session)
            } catch is CancellationError {
                try markOriginal(item)
                throw CancellationError()
            } catch let error as MailSessionError {
                // The server refused the copy (a full or missing Sent). The mail is out: a missing
                // Sent copy mustn't also lose the \Answered mark, or hold up the rest of the queue.
                SyncLog.info("sent \(id), but the server refused the Sent copy: \(error)")
            } catch {
                // The connection itself failed: reconnect before the next item goes out, so it
                // doesn't lose its Sent copy too.
                SyncLog.info("sent \(id), but filing the Sent copy failed: \(error)")
                try markOriginal(item)
                throw error
            }
            try markOriginal(item)
        }
    }

    /// SMTP 4xx, timeouts and network errors (refused, offline) are retried with backoff; 5xx
    /// and auth errors wait for the user.
    private func recordSendFailure(_ error: any Error, of item: inout OutboxItem) throws {
        let smtpError = error as? SMTPError
        let transient = smtpError?.isTransient ?? true
        item.attempts += 1
        item.lastError = smtpError?.description ?? error.localizedDescription
        if transient, item.attempts < Self.maxSendAttempts {
            item.state = .queued
            let delay = min(Self.maxRetryDelay, Self.firstRetryDelay * pow(2, Double(item.attempts - 1)))
            item.sendAt = Date().addingTimeInterval(delay)
        } else {
            item.state = .failed
        }
        try store.save(item)
    }

    /// Puts a copy in Sent unless the server already does (learned once, then remembered).
    func fileSentCopy(raw: Data, messageID: String, sentPath: String, policy: SentCopyPolicy?,
                      uidNextBefore: UInt32?, session: MailSession) async throws {
        let policy = if let policy { policy } else {
            try await learnSentCopyPolicy(messageID: messageID, sentPath: sentPath, uidNextBefore: uidNextBefore, session: session)
        }
        if policy == .client {
            try await session.ensureMailbox(sentPath)
            _ = try await session.append(to: sentPath, message: raw, flags: ["\\Seen"])
        }
    }

    /// Watches Sent for the server's own copy of the message just sent, and remembers the answer.
    private func learnSentCopyPolicy(messageID: String, sentPath: String, uidNextBefore: UInt32?,
                                     session: MailSession) async throws -> SentCopyPolicy {
        var learned = SentCopyPolicy.client
        if let from = uidNextBefore {
            for delay in Self.serverCopyChecks {
                try await Task.sleep(for: delay)
                _ = try await session.select(sentPath, readOnly: true)
                let ids = try await session.fetchHeaderField("Message-ID", fromUID: from)
                if ids.values.contains(where: { $0.contains(messageID) }) { learned = .server; break }
            }
        }
        try store.setSetting(Self.sentCopyKey, learned.rawValue, accountID: account.id)
        return learned
    }

    /// The keyword other clients (Apple Mail, Thunderbird) show as "forwarded".
    static let forwardedKeyword = "$Forwarded"

    /// Replied → \Answered, forwarded → $Forwarded, through the normal triage queue.
    func markOriginal(_ item: OutboxItem) throws {
        guard let original = item.originalLocalID, item.kind != .new else { return }
        // A reply sent from another account's address: the original isn't ours to flag (its
        // local id means nothing on this account's server).
        guard (try? store.message(id: original))?.accountID == account.id else { return }
        let flag = item.kind == .forward ? Self.forwardedKeyword : "\\Answered"
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
