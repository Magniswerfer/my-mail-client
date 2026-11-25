import Foundation

/// Something in a message that could go in your calendar: a plan in a sentence ("Middag hos os
/// fredag kl. 19"), a webinar time, or a booking described in schema.org markup (SPEC §5
/// Highlights). Found on device; nothing leaves the Mac.
public struct EventSuggestion: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case event, flight, lodging, restaurant
    }

    /// Where it was found: structured markup is trusted, sentences are read.
    public enum Source: String, Sendable, Codable {
        case schemaOrg, text
    }

    public enum Confidence: Int, Sendable, Codable, Comparable {
        /// Needs a second opinion (the on-device model) before it's shown.
        case medium = 1
        case high = 2
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable within a message (kind + start), so dismissing or adding survives a re-scan.
    public var id: String
    public var kind: Kind
    public var source: Source
    /// A short calendar title; empty when nothing better than "Event" was found.
    public var title: String
    public var start: Date
    /// Exclusive. Nil: one hour for timed events, the one day for all-day ones.
    public var end: Date?
    /// All-day events use midnight UTC of the calendar day(s), as `CalendarInvite` does.
    public var isAllDay: Bool
    /// The zone the time was written in (IANA, or a fixed offset like "GMT+0100").
    public var timeZoneID: String?
    public var location: String?
    /// The sentence (or the markup's description) it came from, shown under the suggestion.
    public var sourceText: String
    public var confidence: Confidence
    /// The title is a fallback (subject or keyword) that the on-device model may improve.
    public var titleIsGuess: Bool
    /// Set once the on-device model has looked at it.
    public var reviewedByModel: Bool
    /// Booking or confirmation number, for the event's notes.
    public var reservationNumber: String?
    public var url: String?

    public init(id: String? = nil, kind: Kind = .event, source: Source, title: String, start: Date, end: Date? = nil,
                isAllDay: Bool = false, timeZoneID: String? = nil, location: String? = nil, sourceText: String,
                confidence: Confidence, titleIsGuess: Bool = false, reviewedByModel: Bool = false,
                reservationNumber: String? = nil, url: String? = nil) {
        self.id = id ?? "\(kind.rawValue)-\(Int(start.timeIntervalSince1970))"
        self.kind = kind
        self.source = source
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.location = location
        self.sourceText = sourceText
        self.confidence = confidence
        self.titleIsGuess = titleIsGuess
        self.reviewedByModel = reviewedByModel
        self.reservationNumber = reservationNumber
        self.url = url
    }

    public var timeZone: TimeZone? { timeZoneID.flatMap(TimeZone.init(identifier:)) }

    /// The effective end: the stated one, else an hour (timed) or the day (all-day).
    public var effectiveEnd: Date { end ?? start.addingTimeInterval(isAllDay ? 86_400 : 3_600) }

    /// Still worth suggesting at `now`: hasn't ended yet.
    public func isUpcoming(at now: Date = Date()) -> Bool {
        if isAllDay {
            // All-day dates are UTC midnights: compare calendar days, not instants.
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let today = Calendar.current.dateComponents([.year, .month, .day], from: now)
            guard let todayUTC = utc.date(from: today) else { return effectiveEnd > now }
            return effectiveEnd > todayUTC
        }
        return effectiveEnd > now
    }

    /// As a calendar event the EventKit bridge can save (a PUBLISH: nobody to answer). `uid`
    /// links the calendar copy back to this suggestion.
    public func calendarInvite(uid: String, notes: String? = nil) -> CalendarInvite {
        .calendarEvent(uid: uid, summary: title, start: start, end: end ?? (isAllDay ? start.addingTimeInterval(86_400) : nil),
                       isAllDay: isAllDay, timeZoneID: timeZoneID, location: location, notes: notes,
                       conferenceURL: ConferenceLink.find(in: [location, url, sourceText]), url: url)
    }
}

extension CalendarInvite {
    /// An event for your own calendar only (PUBLISH): no organizer, no guests, nobody to answer.
    /// All-day dates are UTC midnights, `end` exclusive.
    public static func calendarEvent(uid: String, summary: String, start: Date, end: Date?, isAllDay: Bool,
                                     timeZoneID: String?, location: String?, notes: String?,
                                     conferenceURL: String? = nil, url: String? = nil) -> CalendarInvite {
        CalendarInvite(
            method: .publish, uid: uid, sequence: 0, recurrenceID: nil, summary: summary, start: start, end: end,
            isAllDay: isAllDay, timeZoneID: isAllDay ? nil : timeZoneID, location: location, notes: notes,
            organizer: nil, attendees: [], isCancelled: false, recurrenceRule: nil, conferenceURL: conferenceURL, url: url
        )
    }
}

extension StoredMessage {
    /// What event suggestions are stored under: the Message-ID, so a message keeps its
    /// suggestions (and your Dismiss) when it moves between mailboxes.
    public var eventKey: String { messageID ?? "uid:\(mailbox)/\(uid)" }
}
