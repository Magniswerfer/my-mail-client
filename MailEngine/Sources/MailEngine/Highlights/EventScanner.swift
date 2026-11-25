import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A second opinion on a date found in a sentence (layer 3): is it a plan, and what's a good
/// calendar title? Used only for uncertain candidates and fallback titles.
public protocol EventJudge: Sendable {
    func review(_ candidate: EventSuggestion, subject: String, sender: String, context: String) async -> EventReview?
}

public struct EventReview: Sendable, Hashable {
    public var isEvent: Bool
    public var title: String
    public var location: String?

    public init(isEvent: Bool, title: String, location: String? = nil) {
        self.isEvent = isEvent
        self.title = title
        self.location = location
    }
}

/// Finds event suggestions in new mail after each sync, so the reader never waits (SPEC §5).
/// Deterministic layers for everything; the on-device model for at most a handful per pass.
public actor EventScanner {
    public struct Report: Sendable { public var scanned = 0, found = 0, reviewed = 0 }

    let store: MailStore
    let judge: (any EventJudge)?
    /// The raw message when it's on disk (the cache tier); never fetched from the server here.
    let raw: @Sendable (StoredMessage) -> Data?
    /// How far back to look: older mail rarely has plans still ahead.
    public var window: TimeInterval = 45 * 86_400
    public var maxReviewsPerPass = 12

    public init(store: MailStore, judge: (any EventJudge)?, raw: @escaping @Sendable (StoredMessage) -> Data?) {
        self.store = store
        self.judge = judge
        self.raw = raw
    }

    /// The real stack: Foundation Models when Apple Intelligence is on, else deterministic only.
    public static func onDevice(store: MailStore, cache: MessageCache) -> EventScanner {
        EventScanner(store: store, judge: FoundationModelsEventJudge(), raw: { cache.cachedRaw(for: $0, store: store) })
    }

    @discardableResult
    public func run(ownAddresses: Set<String>, limit: Int = 300, now: Date = Date()) async throws -> Report {
        var report = Report()
        for message in try store.messagesNeedingEventScan(since: now.addingTimeInterval(-window), limit: limit) {
            try Task.checkCancellation()
            let record = scan(message, ownAddresses: ownAddresses)
            try store.saveEventSuggestions(record)
            report.scanned += 1
            report.found += record.suggestions.isEmpty ? 0 : 1
        }
        report.reviewed = try await reviewPending()
        return report
    }

    /// One message now (the reader opened something the background pass hasn't reached).
    @discardableResult
    public func scanNow(_ message: StoredMessage, ownAddresses: Set<String>) async throws -> EventSuggestionRecord {
        if let existing = try store.eventSuggestions(for: message) { return existing }
        var record = scan(message, ownAddresses: ownAddresses)
        if record.awaitingReview, judge != nil { record = await review(record, message: message) }
        try store.saveEventSuggestions(record)
        return record
    }

    /// The deterministic layers, plus what to do without a model.
    func scan(_ message: StoredMessage, ownAddresses: Set<String>) -> EventSuggestionRecord {
        let own = Set(ownAddresses.map { $0.lowercased() })
        // Your own mail, invites (M4.6 has a card for those) and ads aren't scanned.
        let skip = message.invite != nil || own.contains(message.fromAddress.lowercased()) || message.category == .advertising
        var suggestions: [EventSuggestion] = []
        if !skip {
            let input: EventExtractor.Input
            if let data = raw(message) {
                let parsed = MIMEParser.parse(data)
                if parsed.invite != nil { return EventSuggestionRecord(accountID: message.accountID, messageKey: message.eventKey, suggestions: []) }
                input = EventExtractor.Input(parsed: parsed, fallbackDate: message.date)
            } else {
                input = EventExtractor.Input(subject: message.subject, text: message.plainText ?? message.preview,
                                             sent: message.date, timeZone: .current)
            }
            suggestions = EventExtractor.extract(input)
        }
        let needsModel = suggestions.contains { Self.needsReview($0) }
        if needsModel && judge == nil {
            // No model: uncertain ones only from people you'd hear from personally.
            suggestions = suggestions.compactMap { s in
                guard s.confidence == .medium else { return s }
                guard message.category == .primary else { return nil }
                var kept = s
                kept.confidence = .high
                return kept
            }
        }
        return EventSuggestionRecord(accountID: message.accountID, messageKey: message.eventKey, suggestions: suggestions,
                                     awaitingReview: needsModel && judge != nil)
    }

    static func needsReview(_ s: EventSuggestion) -> Bool {
        !s.reviewedByModel && s.source == .text && (s.confidence == .medium || s.titleIsGuess)
    }

    func reviewPending() async throws -> Int {
        guard judge != nil else { return 0 }
        var reviewed = 0
        for record in try store.eventSuggestionsAwaitingReview(limit: maxReviewsPerPass) {
            try Task.checkCancellation()
            guard let message = try store.message(accountID: record.accountID, eventKey: record.messageKey) else {
                var done = record
                done.awaitingReview = false
                try store.saveEventSuggestions(done)
                continue
            }
            let updated = await review(record, message: message)
            try store.saveEventSuggestions(updated)
            reviewed += 1
        }
        return reviewed
    }

    /// Medium candidates are kept only if the model agrees; guessed titles get a better one.
    func review(_ record: EventSuggestionRecord, message: StoredMessage) async -> EventSuggestionRecord {
        guard let judge else { return record }
        var out = record
        out.suggestions = []
        let sender = message.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? message.fromAddress
        let context = String(MailStore.ownText(message.plainText ?? message.preview).prefix(700))
        for var s in record.suggestions {
            guard Self.needsReview(s) else { out.suggestions.append(s); continue }
            guard let verdict = await judge.review(s, subject: message.subject, sender: sender, context: context) else {
                // The model failed: keep confident ones with their fallback title.
                if s.confidence == .high { s.reviewedByModel = true; out.suggestions.append(s) }
                continue
            }
            if s.confidence == .medium && !verdict.isEvent { continue }
            let title = verdict.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.")))
            if !title.isEmpty, title.count <= 80 { s.title = title; s.titleIsGuess = false }
            if s.location == nil, let place = verdict.location?.trimmingCharacters(in: .whitespacesAndNewlines),
               !place.isEmpty, place.count <= 120, context.localizedCaseInsensitiveContains(place),
               place.contains(where: { $0.isUppercase || $0.isNumber }) {   // a name or an address, not "hos os"
                s.location = place
            }
            s.reviewedByModel = true
            out.suggestions.append(s)
        }
        out.awaitingReview = false
        return out
    }
}

extension MessageCache {
    /// The raw message from the cache tier only (no network), or nil.
    public func cachedRaw(for message: StoredMessage, store: MailStore) -> Data? {
        guard let state = try? store.mailboxStates(accountID: message.accountID).first(where: { $0.path == message.mailbox }) else { return nil }
        return read(account: message.accountID, mailbox: message.mailbox, validity: UInt32(state.uidValidity ?? 0), uid: message.uid)
    }
}

// MARK: - Foundation Models

public struct FoundationModelsEventJudge: EventJudge {
    public init?() {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        #else
        return nil
        #endif
    }

    static let instructions = """
        You read one sentence from an email and a date and time found in it. Emails may be Danish or English.
        Say what the date is about. Only meetings, appointments, social plans, bookings, tickets, classes, talks \
        and webinars are things the reader attends. Sending, finishing or delivering something by a time is a \
        deadline or task; parcels are deliveries; sales and offers are offers; dates mentioned in passing are other.
        Write a calendar title of 2 to 6 words in the same language as the sentence: a Danish sentence gets a \
        Danish title ("Middag hos Anna", "Frokost med Bo"), an English sentence an English one ("Call with Sofie", \
        "Swift webinar"). If the plan is at the sender's home ("hos os", "at our place"), say whose: "Middag hos Anna". \
        Don't repeat words or copy filler like "hos os". The location is a place name or address the email gives, or empty.
        """

    public func review(_ candidate: EventSuggestion, subject: String, sender: String, context: String) async -> EventReview? {
        #if canImport(FoundationModels)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = candidate.isAllDay ? TimeZone(identifier: "UTC") : (candidate.timeZone ?? .current)
        formatter.dateFormat = candidate.isAllDay ? "EEEE d MMMM yyyy" : "EEEE d MMMM yyyy, HH:mm"
        let prompt = """
            From: \(sender)
            Subject: \(subject)
            Sentence: \(candidate.sourceText)
            Date found: \(formatter.string(from: candidate.start))\(candidate.isAllDay ? " (all day)" : "")

            The email:
            \(context)
            """
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: prompt, generating: EventVerdict.self)
            let v = response.content
            return EventReview(isEvent: EventVerdict.eventKinds.contains(v.kind), title: v.title,
                               location: v.location.isEmpty ? nil : v.location)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct EventVerdict {
    /// Picking a kind is more reliable for the small model than a bare yes/no.
    static let eventKinds: Set<String> = ["meeting or appointment", "social plan", "booking or ticket", "class, talk or webinar"]

    @Guide(description: "What the sentence's date is about", .anyOf([
        "meeting or appointment", "social plan", "booking or ticket", "class, talk or webinar",
        "deadline or task", "delivery or pickup", "offer or sale", "something that happened", "other mention",
    ]))
    var kind: String
    @Guide(description: "A calendar title, 2 to 6 words, in the sentence's language")
    var title: String
    @Guide(description: "A place name or address from the email, or an empty string")
    var location: String
}
#endif
