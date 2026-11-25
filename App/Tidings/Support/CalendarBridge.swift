import EventKit
import Foundation
import MailEngine

/// Puts accepted invitations in the user's calendar, keeps them in step with updates, removes
/// them on cancellation and finds clashes. Access is asked for the first time it's needed
/// (accepting, or "Add to Calendar"), never at launch.
///
/// Tidings answers the organizer itself (an iTIP REPLY by mail), so the calendar copy carries no
/// organizer/attendees and Calendar never sends a second answer.
@MainActor final class CalendarBridge {
    static let shared = CalendarBridge()

    /// Recreated once access is granted: a store made before that can't see events.
    private var store = EKEventStore()
    /// Event UID → `eventIdentifier` of the copy we made, so updates and cancellations find it.
    private var links: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "calendarLinks") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "calendarLinks") }
    }

    /// Off in the dev copy (`-TidingsDevServer`): it shares the user's real calendar and
    /// reminders, so it must neither read nor write them. Set once at launch.
    var isEnabled = true

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var hasAccess: Bool { isEnabled && status == .fullAccess }
    var wasDenied: Bool { status == .denied || status == .restricted || status == .writeOnly }

    func requestAccess() async -> Bool {
        guard isEnabled else { return false }
        if hasAccess { return true }
        guard status == .notDetermined else { return false }
        // A fresh store for the request: it can be handed to EventKit without sharing ours.
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        if granted { store = EKEventStore() }
        return granted
    }

    /// The calendar copy of this event: one we made, or one already there (e.g. the invite came
    /// to an address your calendar server handles itself).
    func existingEvent(for invite: CalendarInvite) -> EKEvent? {
        guard hasAccess else { return nil }
        if let id = links[invite.uid], let event = store.event(withIdentifier: id) { return event }
        let (start, end) = localRange(invite)
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86_400),
                                                 end: end.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first { $0.calendarItemExternalIdentifier == invite.uid }
    }

    /// Busy events that overlap the invite (not the invite itself, not all-day, not "free").
    func conflicts(for invite: CalendarInvite) -> [EKEvent] {
        guard hasAccess, !invite.isAllDay, !invite.isCancelled else { return [] }
        let (start, end) = localRange(invite)
        let own = existingEvent(for: invite)?.eventIdentifier
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { event in
            !event.isAllDay && event.availability != .free && event.status != .canceled
                && event.eventIdentifier != own && event.calendarItemExternalIdentifier != invite.uid
                && event.endDate > start && event.startDate < end
        }
        .sorted { $0.startDate < $1.startDate }
    }

    // MARK: Reminders

    enum Failure: Error { case noAccess, noList, devCopy }

    /// A reminder in the default list, with an optional due date (and an alert then).
    /// A plain event (flights, reservations from Highlights).
    func addEvent(title: String, start: Date, end: Date, location: String?, url: URL?) throws {
        guard hasAccess else { throw Failure.noAccess }
        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(900))
        event.location = location
        event.url = url
        try store.save(event, span: .thisEvent, commit: true)
    }

    func addReminder(title: String, notes: String?, url: URL?, due: Date?) async throws {
        guard isEnabled else { throw Failure.devCopy }
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined,
                  (try? await EKEventStore().requestFullAccessToReminders()) == true else { throw Failure.noAccess }
            store = EKEventStore()
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title.isEmpty ? String(localized: "Follow up on email") : title
        reminder.notes = [notes, url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
        reminder.url = url
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
    }

    /// Times you're busy (for Share Availability): timed events that aren't free or cancelled.
    func busyIntervals(from start: Date, to end: Date) -> [DateInterval] {
        guard hasAccess, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && $0.status != .canceled && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }

    /// Adds the event, or updates our copy (new time, place, title) when the invite changed.
    @discardableResult
    func save(_ invite: CalendarInvite, tentative: Bool = false) throws -> EKEvent {
        guard isEnabled else { throw Failure.devCopy }
        let event = existingEvent(for: invite) ?? EKEvent(eventStore: store)
        if event.calendar == nil { event.calendar = store.defaultCalendarForNewEvents }
        // Never rewrite an event the calendar server owns; it's already up to date there.
        if event.calendarItemExternalIdentifier == invite.uid, links[invite.uid] == nil { return event }
        let (start, end) = localRange(invite)
        event.title = invite.summary.isEmpty ? String(localized: "Meeting") : invite.summary
        event.isAllDay = invite.isAllDay
        event.startDate = start
        event.endDate = invite.isAllDay ? end.addingTimeInterval(-1) : end
        event.timeZone = invite.isAllDay ? nil : invite.timeZoneID.flatMap(TimeZone.init(identifier:))
        event.location = invite.location
        event.notes = invite.notes
        event.url = (invite.conferenceURL ?? invite.url).flatMap(URL.init(string:))
        event.availability = tentative ? .tentative : .busy
        event.recurrenceRules = invite.recurrenceRule.flatMap(Self.recurrence).map { [$0] }
        try store.save(event, span: .futureEvents, commit: true)
        if let id = event.eventIdentifier { links[invite.uid] = id }
        return event
    }

    /// Removes our copy (declined or cancelled). Events the server put there are left alone.
    func remove(_ invite: CalendarInvite) throws {
        guard let id = links[invite.uid], hasAccess else { return }
        if let event = store.event(withIdentifier: id) {
            try store.remove(event, span: .futureEvents, commit: true)
        }
        links[invite.uid] = nil
    }

    func isLinked(_ invite: CalendarInvite) -> Bool { links[invite.uid] != nil }

    /// Wall-clock range in this Mac's time zone. All-day dates are stored as UTC midnight.
    func localRange(_ invite: CalendarInvite) -> (Date, Date) {
        let end = invite.end ?? invite.start.addingTimeInterval(invite.isAllDay ? 86_400 : 3_600)
        guard invite.isAllDay else { return (invite.start, end) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func local(_ d: Date) -> Date {
            Calendar.current.date(from: utc.dateComponents([.year, .month, .day], from: d)) ?? d
        }
        return (local(invite.start), local(end))
    }

    /// The common RRULEs (FREQ, INTERVAL, COUNT/UNTIL, weekly BYDAY). Anything fancier adds
    /// just the first occurrence rather than a wrong series.
    static func recurrence(_ rule: String) -> EKRecurrenceRule? {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]).uppercased() }
        }
        let frequency: EKRecurrenceFrequency
        switch parts["FREQ"] {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: return nil
        }
        let supported: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "WKST"]
        guard Set(parts.keys).isSubset(of: supported) else { return nil }
        var days: [EKRecurrenceDayOfWeek]?
        if let byday = parts["BYDAY"] {
            guard frequency == .weekly else { return nil }
            let map: [String: EKWeekday] = ["SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
                                            "TH": .thursday, "FR": .friday, "SA": .saturday]
            days = byday.split(separator: ",").compactMap { code in
                map[String(code)].map { EKRecurrenceDayOfWeek($0) }
            }
        }
        var end: EKRecurrenceEnd?
        if let count = parts["COUNT"].flatMap(Int.init) { end = EKRecurrenceEnd(occurrenceCount: count) }
        if let until = parts["UNTIL"], let date = untilDate(until) { end = EKRecurrenceEnd(end: date) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: parts["INTERVAL"].flatMap(Int.init) ?? 1,
                                daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                daysOfTheYear: nil, setPositions: nil, end: end)
    }

    private static func untilDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = raw.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: raw)
    }
}
