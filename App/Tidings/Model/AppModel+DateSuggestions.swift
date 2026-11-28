import Foundation
import MailEngine
import SwiftUI

/// An event about to go in the calendar, as the editor sheet shows it. Times are absolute;
/// all-day dates are local midnights while editing.
struct EventDraft: Identifiable {
    let id = UUID()
    /// Links the calendar copy to the suggestion it came from.
    var uid: String
    var message: StoredMessage
    var kind: EventSuggestion.Kind
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    /// The zone the time was written in, kept on the calendar event.
    var timeZoneID: String?
    var url: String?

    private static let day: TimeInterval = 86_400
    private static let minimumLength: TimeInterval = 60

    /// As a calendar event for the EventKit bridge.
    var calendarInvite: CalendarInvite {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func utcMidnight(_ d: Date) -> Date {
            utc.date(from: Calendar.current.dateComponents([.year, .month, .day], from: d)) ?? d
        }
        let start = isAllDay ? utcMidnight(start) : start
        let end = isAllDay ? utcMidnight(end).addingTimeInterval(Self.day) : max(end, start.addingTimeInterval(Self.minimumLength))
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlace = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return .calendarEvent(
            uid: uid, summary: trimmedTitle.isEmpty ? DateSuggestionFormat.fallbackTitle(kind) : trimmedTitle,
            start: start, end: end, isAllDay: isAllDay, timeZoneID: timeZoneID,
            location: trimmedPlace.isEmpty ? nil : trimmedPlace, notes: trimmedNotes.isEmpty ? nil : trimmedNotes, url: url
        )
    }
}

/// State for date suggestions that has no place among the model's stored properties: the
/// background scanner and the editor sheet.
@MainActor @Observable final class DateSuggestionCenter {
    static let shared = DateSuggestionCenter()
    /// The event open in the editor sheet.
    var editing: EventDraft?
    @ObservationIgnored var scanner: EventScanner?
    @ObservationIgnored var task: Task<Void, Never>?
    /// Conversations already checked on opening, so the reader scans each only once.
    @ObservationIgnored var checkedThreads: Set<String> = []
}

/// Dates and times in mail become calendar suggestions (SPEC §5 Highlights): found on device
/// after each sync, shown as a quiet card in the reader, added through the editable sheet.
extension AppModel {
    private var center: DateSuggestionCenter { .shared }
    /// Opening older mail scans this many of the conversation's newest messages.
    private static let messagesScannedOnOpen = 5

    private func eventScanner() -> EventScanner {
        if let scanner = center.scanner { return scanner }
        let scanner = EventScanner.onDevice(store: store, cache: cache)
        center.scanner = scanner
        return scanner
    }

    /// After each sync: scan what's new (and let the on-device model review a few), never two
    /// passes at once.
    func scheduleEventScan() {
        guard center.task == nil else { return }
        let scanner = eventScanner()
        let own = ownAddresses
        center.task = Task { [weak self] in
            let report = try? await scanner.run(ownAddresses: own)
            DateSuggestionCenter.shared.task = nil
            if (report?.found ?? 0) > 0 || (report?.reviewed ?? 0) > 0 { self?.revision &+= 1 }
        }
    }

    /// Opening a conversation the background pass hasn't reached (older mail): scan it now.
    func scanThreadIfNeeded(_ threadID: String) async {
        guard center.checkedThreads.insert(threadID).inserted else { return }
        let scanner = eventScanner()
        let own = ownAddresses
        var found = false
        for message in messages(inThread: threadID).suffix(Self.messagesScannedOnOpen) where message.invite == nil {
            guard (try? store.eventSuggestions(for: message)) == nil else { continue }
            if let record = try? await scanner.scanNow(message, ownAddresses: own), !record.visible().isEmpty { found = true }
        }
        if found { revision &+= 1 }
    }

    /// The newest message in a conversation with something upcoming to suggest.
    /// Read once per thread and revision (every change to suggestions bumps it): the reader, the
    /// Mac menu and ⌘K all ask on each redraw or selection change.
    func dateSuggestions(inThread threadID: String) -> (message: StoredMessage, record: EventSuggestionRecord)? {
        if let cached = dateSuggestionCache, cached.threadID == threadID, cached.revision == revision { return cached.found }
        let found = findDateSuggestions(inThread: threadID)
        dateSuggestionCache = (threadID, revision, found)
        return found
    }

    private func findDateSuggestions(inThread threadID: String) -> (message: StoredMessage, record: EventSuggestionRecord)? {
        for message in messages(inThread: threadID).reversed() {
            // A flight or reservation Highlight already offers Add to Calendar for this booking.
            if message.highlights?.contains(where: { ($0.kind == .flight || $0.kind == .reservation) && $0.date != nil }) == true {
                continue
            }
            if let record = try? store.eventSuggestions(for: message), !record.visible().isEmpty { return (message, record) }
        }
        return nil
    }

    /// The selected conversation's first suggestion not yet in the calendar (for ⌘K and the menu).
    var selectedDateSuggestion: (message: StoredMessage, suggestion: EventSuggestion)? {
        guard let thread = targetThreads.first, let found = dateSuggestions(inThread: thread.threadID) else { return nil }
        guard let suggestion = found.record.visible().first(where: { !isInCalendar($0, message: found.message) }) else { return nil }
        return (found.message, suggestion)
    }

    var selectedDateSuggestionMessage: StoredMessage? {
        targetThreads.first.flatMap { dateSuggestions(inThread: $0.threadID)?.message }
    }

    func calendarUID(for suggestion: EventSuggestion, message: StoredMessage) -> String {
        "tidings-suggestion:\(message.accountID):\(message.eventKey):\(suggestion.id)"
    }

    func isInCalendar(_ suggestion: EventSuggestion, message: StoredMessage) -> Bool {
        let invite = suggestion.calendarInvite(uid: calendarUID(for: suggestion, message: message))
        return CalendarBridge.shared.isLinked(invite)
    }

    // MARK: Actions

    /// Opens the editor with the suggestion filled in.
    func editEvent(_ suggestion: EventSuggestion, message: StoredMessage) {
        let invite = suggestion.calendarInvite(uid: calendarUID(for: suggestion, message: message))
        let (start, end) = CalendarBridge.shared.localRange(invite)
        var notes: [String] = []
        if suggestion.source == .text { notes.append(suggestion.sourceText) }
        if let number = suggestion.reservationNumber { notes.append(String(localized: "Booking reference: \(number)")) }
        if let link = link(for: message) { notes.append(link.absoluteString) }
        center.editing = EventDraft(
            uid: invite.uid, message: message, kind: suggestion.kind, title: suggestion.title,
            start: start, end: suggestion.isAllDay ? end.addingTimeInterval(-86_400) : end,
            isAllDay: suggestion.isAllDay, location: suggestion.location ?? "",
            notes: notes.joined(separator: "\n\n"), timeZoneID: suggestion.timeZoneID, url: suggestion.url
        )
    }

    func addSelectedDateToCalendar() {
        guard let found = selectedDateSuggestion else { return }
        editEvent(found.suggestion, message: found.message)
    }

    /// Saves the edited event in the default calendar. Undo takes it out again.
    func saveEvent(_ draft: EventDraft) {
        let invite = draft.calendarInvite
        let message = draft.message
        Task { [weak self] in
            guard let self else { return }
            let calendar = CalendarBridge.shared
            guard await calendar.requestAccess() else {
                show(Toast(message: Platform.calendarSettingsHint, symbol: "calendar.badge.exclamationmark"))
                return
            }
            do {
                try calendar.save(invite)
            } catch {
                lastError = String(localized: "Couldn't add it to your calendar: \(error.localizedDescription)")
                return
            }
            try? store.setEventSuggestionState(.added, for: message)
            revision &+= 1
            let undo: @MainActor () -> Void = { [weak self] in
                try? CalendarBridge.shared.remove(invite)
                try? self?.store.setEventSuggestionState(.open, for: message)
                self?.revision &+= 1
            }
            let undoToken = offerUndo(named: String(localized: "Add to Calendar"), undo)
            show(Toast(message: String(localized: "Added to your calendar"), symbol: "calendar.badge.plus", undo: undoToken))
        }
    }

    /// "Not interested": the suggestions for this message don't come back.
    func dismissDateSuggestions(for message: StoredMessage) {
        let previous = (try? store.eventSuggestions(for: message))?.state ?? .open
        try? store.setEventSuggestionState(.dismissed, for: message)
        revision &+= 1
        let undo: @MainActor () -> Void = { [weak self] in
            try? self?.store.setEventSuggestionState(previous, for: message)
            self?.revision &+= 1
        }
        let undoToken = offerUndo(named: String(localized: "Dismiss Suggestion"), undo)
        show(Toast(message: String(localized: "Suggestion dismissed"), symbol: "calendar.badge.minus", undo: undoToken))
    }

    func dismissSelectedDateSuggestions() {
        guard let message = selectedDateSuggestionMessage else { return }
        dismissDateSuggestions(for: message)
    }

    /// ⌘K entries.
    var dateSuggestionCommands: [AppCommand] {
        let canAdd = selectedDateSuggestion != nil
        return [
            AppCommand(id: "dateAdd", title: String(localized: "Add Date to Calendar…"), symbol: "calendar.badge.plus", keys: "⌃⌘E",
                       isEnabled: canAdd) { self.addSelectedDateToCalendar() },
            AppCommand(id: "dateDismiss", title: String(localized: "Dismiss Date Suggestion"), symbol: "calendar.badge.minus", keys: nil,
                       isEnabled: selectedDateSuggestionMessage != nil) { self.dismissSelectedDateSuggestions() },
        ]
    }
}

enum DateSuggestionFormat {
    static func fallbackTitle(_ kind: EventSuggestion.Kind) -> String {
        switch kind {
        case .event: String(localized: "Event")
        case .flight: String(localized: "Flight")
        case .lodging: String(localized: "Hotel stay")
        case .restaurant: String(localized: "Table reservation")
        }
    }

    static func title(_ s: EventSuggestion) -> String {
        s.title.isEmpty ? fallbackTitle(s.kind) : s.title
    }

    static func symbol(_ kind: EventSuggestion.Kind) -> String {
        switch kind {
        case .event: "calendar.badge.plus"
        case .flight: "airplane"
        case .lodging: "bed.double"
        case .restaurant: "fork.knife"
        }
    }

    /// "fre. 27. nov. 19.00", "fre. 27. nov. 19.00–21.00", "lør. 12. dec." (all day), in your zone.
    static func when(_ s: EventSuggestion) -> String {
        if s.isAllDay {
            let utc = TimeZone(identifier: "UTC")!
            let day = Date.FormatStyle(timeZone: utc).weekday(.abbreviated).day().month(.abbreviated)
            let last = s.effectiveEnd.addingTimeInterval(-1)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = utc
            if cal.isDate(s.start, inSameDayAs: last) { return s.start.formatted(day) }
            return "\(s.start.formatted(day)) – \(last.formatted(day))"
        }
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        let time = Date.FormatStyle.dateTime.hour().minute()
        guard let end = s.end else { return "\(s.start.formatted(day)) \(s.start.formatted(time))" }
        if Calendar.current.isDate(s.start, inSameDayAs: end.addingTimeInterval(-1)) {
            return "\(s.start.formatted(day)) \(s.start.formatted(time))–\(end.formatted(time))"
        }
        return "\(s.start.formatted(day)) \(s.start.formatted(time)) – \(end.formatted(day)) \(end.formatted(time))"
    }

    /// "14:00 in Paris" when the time was written in another zone than yours.
    static func writtenTime(_ s: EventSuggestion) -> String? {
        guard !s.isAllDay, let zone = s.timeZone, zone.secondsFromGMT(for: s.start) != TimeZone.current.secondsFromGMT(for: s.start) else {
            return nil
        }
        let time = Date.FormatStyle(timeZone: zone).hour().minute()
        let id = zone.identifier
        let place = id.contains("/") ? (id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
            : (zone.abbreviation(for: s.start) ?? id)
        return String(localized: "\(s.start.formatted(time)) in \(place)")
    }
}
