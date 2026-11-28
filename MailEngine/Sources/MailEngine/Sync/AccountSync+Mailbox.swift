import Foundation

/// What one mailbox pass found on the server, before anything is applied locally.
private struct MailboxDelta {
    /// New messages and messages whose flags changed (on a full pass: every message).
    var summaries: [MessageSummary]
    /// Stored UID → flags, for the UIDs the pass compares against.
    var known: [UInt32: String]
    /// Stored UIDs the server no longer has.
    var vanished: [UInt32]
}

/// Per-pass inputs to `makeMessage` that don't change from one message to the next.
struct MessageContext {
    /// Domains you correspond with: protected from look-alikes, never flagged themselves.
    var trustedDomains: Set<String>
    var highlightTraining: HighlightTraining
}

extension AccountSync {
    /// Shown for a message that has no subject.
    static let noSubjectPlaceholder = "(no subject)"

    /// Syncs one mailbox, reading as little as the server allows (RFC 7162):
    /// - **unchanged** (same UIDNEXT, MESSAGES and HIGHESTMODSEQ as last time, and the local copy
    ///   agrees on the count): nothing is fetched;
    /// - **QRESYNC**: `UID FETCH 1:* (…) (CHANGEDSINCE n VANISHED)` brings new mail, flag changes and
    ///   expunges in one round trip;
    /// - **CONDSTORE**: the same without VANISHED; when the counts say something was expunged,
    ///   a `UID SEARCH` finds what;
    /// - otherwise, or the first time, or after a UIDVALIDITY change: the full message list.
    func syncMailbox(_ session: MailSession, path: String, role: MailboxRole?) async throws {
        let selected = try await session.select(path, readOnly: true)
        try readAllAfterKeywordPolicyChange()
        let (saved, firstSync) = try savedState(of: path, selected: selected)

        // Leave alone whatever a queued triage action is about to change: its source message is
        // still on the server here, and its local row already shows the result.
        let inFlight = try store.inFlight(accountID: account.id, mailbox: path)
        let inFlightUIDs = try store.uids(localIDs: inFlight.localIDs, mailbox: path)

        let since = modSeqToSyncFrom(saved: saved, selected: selected, firstSync: firstSync, session: session)
        if let since, let saved, try isUnchanged(path, saved: saved, since: since, selected: selected, inFlight: inFlight) {
            try recordSkippedPass(path, saved: saved, since: since)
            return
        }

        var delta: MailboxDelta
        if let since {
            delta = try await fetchChanges(session, path: path, since: since, selected: selected, inFlight: inFlight)
        } else {
            delta = try await fetchFullList(session, path: path)
        }
        // An in-flight message changed on the server: look at it again next time.
        var heldBack = delta.summaries.contains { inFlightUIDs.contains($0.uid) }
        if delta.vanished.contains(where: inFlightUIDs.contains) {
            heldBack = true
            delta.vanished.removeAll(where: inFlightUIDs.contains)
        }
        if !delta.vanished.isEmpty { try store.deleteMessages(accountID: account.id, mailbox: path, uids: delta.vanished) }
        try applyFlagChanges(delta, path: path, skipping: inFlightUIDs)
        let newCount = try await storeNewMessages(delta, session, path: path, validity: selected.uidValidity, inFlight: inFlight)
        if firstSync {
            try store.markRulesChecked(accountID: account.id, mailbox: path)
        }

        // The state is from the SELECT, before anything above: whatever changed since then is
        // fetched again next time, never missed. A held-back message keeps the old MODSEQ.
        try store.save(MailboxState(
            accountID: account.id, path: path, role: role,
            uidValidity: selected.uidValidity.map(Int64.init), uidNext: selected.uidNext.map(Int64.init),
            highestModSeq: heldBack ? saved?.highestModSeq : selected.highestModSeq.map { Int64(bitPattern: $0) },
            messageCount: selected.exists, lastSync: Date()
        ))
        emit(.mailboxSynced(mailbox: path, newMessages: newCount))
    }

    // MARK: Deciding the pass

    /// The saved sync state, and whether this is the mailbox's first sync. A mailbox's first sync
    /// (a new account or device, or the server reset its UIDs) brings in mail that was already
    /// there, not mail that just arrived: rules don't run on it.
    private func savedState(of path: String, selected: SelectedMailbox) throws -> (state: MailboxState?, firstSync: Bool) {
        let saved = try store.mailboxStates(accountID: account.id).first { $0.path == path }
        let firstSync = saved?.uidValidity == nil || saved?.uidValidity != selected.uidValidity.map(Int64.init)
        if let savedValidity = saved?.uidValidity, let validity = selected.uidValidity, savedValidity != Int64(validity) {
            // UIDs are meaningless after a UIDVALIDITY change: start over for this mailbox.
            try store.deleteMailbox(accountID: account.id, mailbox: path)
            return (nil, firstSync)
        }
        return (saved, firstSync)
    }

    /// The MODSEQ to fetch changes since; nil means a full pass.
    private func modSeqToSyncFrom(saved: MailboxState?, selected: SelectedMailbox, firstSync: Bool,
                                  session: MailSession) -> UInt64? {
        guard session.resyncMode != .none, !firstSync, let saved, let old = saved.highestModSeq,
              let now = selected.highestModSeq, selected.uidValidity != nil else { return nil }
        let oldModSeq = UInt64(bitPattern: old)
        return oldModSeq <= now ? oldModSeq : nil
    }

    private func isUnchanged(_ path: String, saved: MailboxState, since: UInt64, selected: SelectedMailbox,
                             inFlight: InFlightChanges) throws -> Bool {
        guard since == selected.highestModSeq, saved.uidNext == selected.uidNext.map(Int64.init),
              saved.messageCount == selected.exists else { return false }
        return try expectedServerCount(path: path, inFlight: inFlight) == selected.exists
    }

    private func recordSkippedPass(_ path: String, saved: MailboxState, since: UInt64) throws {
        var touched = saved
        touched.lastSync = Date()
        try store.save(touched)
        SyncLog.info("sync \(path): unchanged (modseq \(since)), skipped")
        lastPass[path] = .skipped
        emit(.mailboxSynced(mailbox: path, newMessages: 0))
    }

    static let keywordPolicySyncedKey = "keepsKeywordsAtLastSync"

    /// Whether a sync keeps our keywords against the server (`serverKeepsKeywords`) decides the
    /// flags of messages that didn't change on the server, which an incremental sync never looks
    /// at again: when that changes, every mailbox is read in full once.
    func readAllAfterKeywordPolicyChange() throws {
        let now = serverKeepsKeywords().map { $0 ? "true" : "false" } ?? ""
        let synced = try store.setting(Self.keywordPolicySyncedKey, accountID: account.id)
        guard synced != now else { return }
        if synced != nil {
            try store.forgetModSeq(accountID: account.id, mailboxes: Set(try store.mailboxStates(accountID: account.id).map(\.path)))
        }
        try store.setSetting(Self.keywordPolicySyncedKey, now, accountID: account.id)
    }

    /// How many messages the server should hold in this mailbox if the local copy is right:
    /// the stored ones, plus those a queued move is about to take out (their rows already left).
    func expectedServerCount(path: String, inFlight: InFlightChanges) throws -> Int {
        try store.serverMessageCount(accountID: account.id, mailbox: path) + inFlight.serverSourceUIDs.count
    }

    // MARK: Reading the server

    private func fetchFullList(_ session: MailSession, path: String) async throws -> MailboxDelta {
        let summaries = try await session.fetchSummaries()
        lastPass[path] = .full
        let known = try store.knownFlags(accountID: account.id, mailbox: path)
        let serverUIDs = Set(summaries.map(\.uid))
        let vanished = known.keys.filter { !serverUIDs.contains($0) && $0 < provisionalUIDBase }
        return MailboxDelta(summaries: summaries, known: known, vanished: vanished)
    }

    private func fetchChanges(_ session: MailSession, path: String, since: UInt64, selected: SelectedMailbox,
                              inFlight: InFlightChanges) async throws -> MailboxDelta {
        let changes = try await fetchChanges(session, path: path, since: since)
        var delta = MailboxDelta(
            summaries: changes.summaries,
            known: try store.knownFlags(accountID: account.id, mailbox: path, uids: changes.summaries.map(\.uid)),
            vanished: try changes.vanished.map { try store.knownUIDs(accountID: account.id, mailbox: path, in: $0) } ?? []
        )

        // Does the server's count match what we'd have after applying this? If not, something
        // was expunged that we weren't told about (CONDSTORE has no VANISHED), or the local copy
        // drifted: compare UID sets, which also brings back anything missing.
        let stored = try store.serverMessageCount(accountID: account.id, mailbox: path)
        let arriving = delta.summaries.filter { delta.known[$0.uid] == nil && !inFlight.sourceUIDs.contains($0.uid) }.count
        let leaving = inFlight.serverSourceUIDs.filter { changes.vanished?.contains($0) != true }.count
        let expected = stored - delta.vanished.count + arriving + leaving
        let serverCount = changes.exists ?? selected.exists
        var how = changes.vanished == nil ? "CONDSTORE" : "QRESYNC"
        lastPass[path] = .changes(vanished: changes.vanished != nil, uidCheck: expected != serverCount)
        if expected != serverCount {
            delta = try await compareUIDSets(session, path: path, found: delta.summaries, inFlight: inFlight)
            how += " + UID check (expected \(expected), server has \(serverCount))"
        }
        SyncLog.info("sync \(path): \(how) since \(since): \(delta.summaries.count) changed, \(delta.vanished.count) gone")
        return delta
    }

    /// `CHANGEDSINCE`, with VANISHED where QRESYNC is on.
    private func fetchChanges(_ session: MailSession, path: String, since: UInt64) async throws -> MailboxChanges {
        guard session.resyncMode == .qresync else {
            return try await session.fetchChanges(since: since, vanished: false)
        }
        do {
            return try await session.fetchChanges(since: since, vanished: true)
        } catch let error as MailSessionError {
            // A server that advertises QRESYNC but refuses VANISHED: use CONDSTORE from now on.
            SyncLog.info("sync \(path): VANISHED refused (\(error.description)), using CONDSTORE")
            session.resyncMode = .condStore
            return try await session.fetchChanges(since: since, vanished: false)
        }
    }

    /// Every UID on the server against every stored one: what's gone, and summaries of what's
    /// missing here, on top of the changes already `found`.
    private func compareUIDSets(_ session: MailSession, path: String, found: [MessageSummary],
                                inFlight: InFlightChanges) async throws -> MailboxDelta {
        let onServer = try await session.allUIDs()
        let local = try store.knownFlags(accountID: account.id, mailbox: path)
        let gone = local.keys.filter { $0 < provisionalUIDBase && !onServer.contains($0) }
        let seen = Set(found.map(\.uid))
        let missing = onServer.ranges.lazy.flatMap { $0 }.filter {
            local[$0] == nil && !seen.contains($0) && !inFlight.sourceUIDs.contains($0)
        }
        var summaries = found
        if !missing.isEmpty {
            summaries += try await session.fetchSummaries(uids: Array(missing))
        }
        return MailboxDelta(summaries: summaries, known: local, vanished: gone)
    }

    // MARK: Applying

    private func applyFlagChanges(_ delta: MailboxDelta, path: String, skipping inFlightUIDs: Set<UInt32>) throws {
        var flagChanges: [UInt32: String] = [:]
        // On a server that doesn't store our keywords, its flags never have them: keep ours.
        let keepOurKeywords = serverKeepsKeywords() == false
        for summary in delta.summaries where !inFlightUIDs.contains(summary.uid) {
            guard let old = delta.known[summary.uid] else { continue }
            var serverFlags = summary.flags
            let ours = old.split(separator: " ").map(String.init).filter { Self.isOwnKeyword($0) && !serverFlags.contains($0) }
            if !ours.isEmpty {
                if keepOurKeywords {
                    serverFlags += ours
                } else {
                    SyncLog.info("server dropped \(ours) on \(path) uid \(summary.uid): was [\(old)] now [\(summary.flags.sorted().joined(separator: " "))] modseq \(summary.modSeq.map(String.init) ?? "-")")
                }
            }
            let flags = serverFlags.sorted().joined(separator: " ")
            if old != flags { flagChanges[summary.uid] = flags }
        }
        if !flagChanges.isEmpty { try store.updateFlags(accountID: account.id, mailbox: path, changes: flagChanges) }
    }

    /// Fetches, parses and stores the messages the pass found new, newest first so the top of
    /// the stream fills in immediately. Returns how many there were.
    private func storeNewMessages(_ delta: MailboxDelta, _ session: MailSession, path: String, validity: UInt32?,
                                  inFlight: InFlightChanges) async throws -> Int {
        let new = delta.summaries.filter { delta.known[$0.uid] == nil && !inFlight.sourceUIDs.contains($0.uid) }
            .sorted { $0.uid > $1.uid }
        guard !new.isEmpty else { return 0 }
        let context = MessageContext(
            trustedDomains: (try? store.correspondentDomains(ownAddresses: Set(account.addresses))) ?? [],
            highlightTraining: (try? store.highlightTraining()) ?? HighlightTraining()
        )
        var done = 0
        for batch in new.chunks(of: batchSize) {
            try Task.checkCancellation()
            let raw = try await fetchBodies(of: batch, session)
            var items: [(message: StoredMessage, plainText: String)] = []
            for summary in batch {
                guard let data = raw[summary.uid] else { continue }
                let item = try makeMessage(summary: summary, data: data, mailbox: path, validity: validity, context: context)
                items.append(item)
                if isCompletelyFetched(summary), Date().timeIntervalSince(item.message.date) < offlineWindow {
                    // The cache is an optimization: a failed write only means a fetch when the message is opened.
                    try? cache.write(data, account: account.id, mailbox: path, validity: validity ?? 0, uid: summary.uid)
                }
            }
            try store.upsert(items)
            done += batch.count
            emit(.mailboxProgress(mailbox: path, done: done, total: new.count))
        }
        return new.count
    }

    private func isCompletelyFetched(_ summary: MessageSummary) -> Bool { summary.size <= largeMessageThreshold }

    /// Whole messages, except that big ones bring only their first `largeMessagePrefix` bytes
    /// (enough to index them).
    private func fetchBodies(of batch: ArraySlice<MessageSummary>, _ session: MailSession) async throws -> [UInt32: Data] {
        let small = batch.filter { isCompletelyFetched($0) }.map(\.uid)
        let large = batch.filter { !isCompletelyFetched($0) }.map(\.uid)
        var raw = try await session.fetchRaw(uids: small)
        if !large.isEmpty {
            raw.merge(try await session.fetchRaw(uids: large, maxBytes: largeMessagePrefix)) { a, _ in a }
        }
        return raw
    }

    // MARK: Building a stored message

    func makeMessage(summary: MessageSummary, data: Data, mailbox: String, validity: UInt32?,
                     context: MessageContext) throws -> (message: StoredMessage, plainText: String) {
        let parsed = MIMEParser.parse(data)
        let (category, reason) = MessageClassifier(store: store).classify(parsed, userAddresses: Set(account.addresses.map { $0.lowercased() }))
        let from = parsed.from.first
        let threadID = try store.threadID(for: parsed, fallback: "\(account.id)/\(mailbox)/\(validity ?? 0)/\(summary.uid)",
                                          accountID: account.id)
        var message = StoredMessage(
            accountID: account.id, mailbox: mailbox, uid: summary.uid, messageID: parsed.messageID,
            threadID: threadID, subject: parsed.subject.isEmpty ? Self.noSubjectPlaceholder : parsed.subject,
            fromName: from?.name, fromAddress: from?.address ?? "",
            recipients: (parsed.to + parsed.cc).map(\.description).joined(separator: ", "),
            date: parsed.date ?? summary.internalDate ?? Date(),
            flags: summary.flags.sorted().joined(separator: " "), size: summary.size,
            hasAttachments: parsed.attachments.contains { !$0.isInline },
            category: category
        )
        message.inReplyTo = parsed.inReplyTo.first
        if let reaction = parsed.reaction {
            message.reactionTo = reaction.target
            message.reactionEmoji = reaction.emoji
        }
        message.reactionsDisallowed = parsed.reactionsDisallowed
        message.attachmentList = parsed.attachments.filter { !$0.isInline }
        let highlights = HighlightExtractor.extract(parsed, training: context.highlightTraining)
        message.highlights = highlights.isEmpty ? nil : highlights
        if let invite = parsed.invite {
            message.invite = invite
            message.inviteUID = invite.uid
            recordOwnInviteAnswer(invite, in: parsed)
        }
        message.classificationReason = reason.encoded
        (message.isSnoozed, message.snoozedUntil) = SnoozeKeywords.parse(summary.flags)
        let sender = from?.address ?? ""
        if !isOwnAddress(sender), !(try store.isTrustedSender(sender)) {
            let risk = PhishingCheck.evaluate(parsed, trustedDomains: context.trustedDomains)
            message.riskLevel = risk.level
            message.riskReasons = risk.reasons.isEmpty ? nil : risk.encodedReasons
        }
        return (message, parsed.plainText)
    }

    /// Your own answer to an invitation, sent from here or any other client, shows on the invite.
    private func recordOwnInviteAnswer(_ invite: CalendarInvite, in parsed: ParsedMessage) {
        guard invite.method == .reply, let sender = parsed.from.first?.address, isOwnAddress(sender),
              let answer = invite.attendees.first else { return }
        // Best effort: the invite itself is stored either way.
        try? store.recordInviteResponse(InviteResponse(
            accountID: account.id, uid: invite.uid, sequence: invite.sequence,
            status: answer.status, respondedAt: parsed.date ?? Date()))
    }

    private func isOwnAddress(_ address: String) -> Bool {
        account.addresses.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    // MARK: Reading

    /// The raw message for the reading pane: from the cache tier, else fetched (read-only) and cached.
    public func rawMessage(_ message: StoredMessage) async throws -> Data {
        let state = try store.mailboxStates(accountID: account.id).first { $0.path == message.mailbox }
        let validity = UInt32(state?.uidValidity ?? 0)
        if let cached = cache.read(account: account.id, mailbox: message.mailbox, validity: validity, uid: message.uid) {
            return cached
        }
        let data = try await MailSession.open(endpoint: account.endpoint, password: password, profile: profile) { session in
            _ = try await session.select(message.mailbox, readOnly: true)
            return try await session.fetchRaw(uids: [message.uid])[message.uid]
        }
        guard let data else { throw MailSessionError.commandFailed(command: "FETCH", detail: "message is gone from the server") }
        try? cache.write(data, account: account.id, mailbox: message.mailbox, validity: validity, uid: message.uid)
        return data
    }
}
