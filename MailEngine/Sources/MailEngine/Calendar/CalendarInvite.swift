import Foundation

/// A meeting invitation, update, cancellation or reply carried in a `text/calendar` part
/// (iTIP, RFC 5546), as sent by Apple Calendar, Google Calendar, Outlook/Exchange, Zoom, etc.
public struct CalendarInvite: Sendable, Codable, Hashable {
    public enum Method: String, Sendable, Codable {
        case request = "REQUEST"            // an invitation or an update to one
        case cancel = "CANCEL"
        case reply = "REPLY"                // an attendee's answer
        case counter = "COUNTER"            // an attendee proposes a new time
        case declineCounter = "DECLINECOUNTER"
        case publish = "PUBLISH"            // "add this to your calendar", no RSVP
        case add = "ADD"
        case refresh = "REFRESH"
    }

    public enum ParticipationStatus: String, Sendable, Codable, CaseIterable {
        case needsAction = "NEEDS-ACTION"
        case accepted = "ACCEPTED"
        case tentative = "TENTATIVE"
        case declined = "DECLINED"
        case delegated = "DELEGATED"
    }

    public struct Person: Sendable, Codable, Hashable {
        public var name: String?
        public var address: String
        public var status: ParticipationStatus
        public var isOptional: Bool
        public var wantsReply: Bool
        public var isResource: Bool

        public var mailAddress: MailAddress { MailAddress(name: name, address: address) }
        public var display: String { (name?.isEmpty == false ? name : nil) ?? address }
    }

    public var method: Method
    /// The event's iCalendar UID; all updates and cancellations of one event share it.
    public var uid: String
    public var sequence: Int
    /// Set when this concerns one occurrence of a repeating event. Raw value + params, echoed in replies.
    public var recurrenceID: RawProperty?
    public var summary: String
    public var start: Date
    public var end: Date?
    /// All-day events: `start`/`end` are midnight UTC of the calendar day (end exclusive, as in
    /// iCalendar). Format them in UTC, never in the local zone.
    public var isAllDay: Bool
    /// The organizer's time zone, when known (IANA identifier).
    public var timeZoneID: String?
    public var location: String?
    public var notes: String?
    public var organizer: Person?
    public var attendees: [Person]
    public var isCancelled: Bool
    /// The raw RRULE, e.g. `FREQ=WEEKLY;BYDAY=TU`.
    public var recurrenceRule: String?
    /// A join link for an online meeting (Meet, Teams, Zoom, Webex, FaceTime), if one was found.
    public var conferenceURL: String?
    public var url: String?
    /// Who changed their answer, for `.reply` messages.
    public var replyFrom: Person? { method == .reply ? attendees.first : nil }

    public struct RawProperty: Sendable, Codable, Hashable {
        public var parameters: [String: String]
        public var value: String
    }

    /// Whether this message expects an answer from you.
    public func needsResponse(from addresses: Set<String>) -> Bool {
        guard method == .request, !isCancelled, let me = attendee(matching: addresses) else { return false }
        return me.wantsReply || me.status == .needsAction
    }

    /// You, among the attendees.
    public func attendee(matching addresses: Set<String>) -> Person? {
        let lowered = Set(addresses.map { $0.lowercased() })
        return attendees.first { lowered.contains($0.address.lowercased()) }
    }

    public func isOrganized(by addresses: Set<String>) -> Bool {
        guard let organizer else { return false }
        return addresses.contains { $0.caseInsensitiveCompare(organizer.address) == .orderedSame }
    }

    /// Everyone but the organizer and resources (rooms).
    public var guests: [Person] {
        attendees.filter { !$0.isResource && $0.address.caseInsensitiveCompare(organizer?.address ?? "") != .orderedSame }
    }
}

// MARK: - Parsing

extension CalendarInvite {
    /// Reads the first event out of an iCalendar document. Returns nil for anything that isn't
    /// a VEVENT (to-dos, free/busy) or lacks the essentials (UID, DTSTART).
    public static func parse(_ ics: String) -> CalendarInvite? {
        guard let calendar = ICalendar.parse(ics).first(where: { $0.name == "VCALENDAR" }) else { return nil }
        let events = calendar.children("VEVENT")
        // A series plus exceptions: describe the series (the one without RECURRENCE-ID).
        guard let event = events.first(where: { $0.property("RECURRENCE-ID") == nil }) ?? events.first,
              let uid = event.property("UID")?.value.trimmingCharacters(in: .whitespaces), !uid.isEmpty,
              let startProperty = event.property("DTSTART") else { return nil }
        let zones = TimeZoneResolver(calendar.children("VTIMEZONE"))
        guard let start = zones.time(startProperty) else { return nil }

        var end = event.property("DTEND").flatMap(zones.time)?.date
        if end == nil, let duration = event.property("DURATION").flatMap({ ICalDuration.seconds($0.value) }) {
            end = start.date.addingTimeInterval(duration)
        }
        if end == nil, start.isAllDay { end = start.date.addingTimeInterval(ICalDuration.secondsPerDay) }

        let methodName = calendar.property("METHOD")?.value.uppercased().trimmingCharacters(in: .whitespaces)
        let method = methodName.flatMap(Method.init(rawValue:)) ?? .publish
        let status = event.property("STATUS")?.value.uppercased()
        // A title: one line. It goes into the reply's Subject ("Accepted: …").
        let summary = HeaderText.singleLine(event.property("SUMMARY")?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let location = event.property("LOCATION")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = event.property("DESCRIPTION")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = event.property("URL")?.value.trimmingCharacters(in: .whitespaces)

        var invite = CalendarInvite(
            method: method, uid: uid,
            sequence: Int(event.property("SEQUENCE")?.value.trimmingCharacters(in: .whitespaces) ?? "") ?? 0,
            recurrenceID: event.property("RECURRENCE-ID").map { RawProperty(parameters: $0.parameters, value: $0.value) },
            summary: summary, start: start.date, end: end, isAllDay: start.isAllDay,
            timeZoneID: start.timeZone?.identifier,
            location: location?.isEmpty == false ? location : nil,
            notes: notes?.isEmpty == false ? notes : nil,
            organizer: event.property("ORGANIZER").flatMap(person),
            attendees: event.properties("ATTENDEE").compactMap(person),
            isCancelled: method == .cancel || status == "CANCELLED",
            recurrenceRule: event.property("RRULE")?.value,
            conferenceURL: nil,
            url: url?.isEmpty == false ? url : nil
        )
        invite.conferenceURL = ConferenceLink.find(in: [
            event.property("X-GOOGLE-CONFERENCE")?.value,
            event.property("X-MICROSOFT-SKYPETEAMSMEETINGURL")?.value,
            event.property("X-MICROSOFT-ONLINEMEETINGCONFLINK")?.value,
            invite.location, invite.url, invite.notes,
        ])
        return invite
    }

    static func person(_ p: ICalProperty) -> Person? {
        var value = p.value.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("mailto:") { value = String(value.dropFirst(7)) }
        // Some servers put the address in EMAIL= and an opaque URN in the value.
        if !value.contains("@"), let email = p.parameter("EMAIL") { value = email }
        value = HeaderText.token(value)
        guard value.contains("@") else { return nil }
        // The organizer's name becomes the reply's To: display name: one line.
        let name = p.parameter("CN").map { HeaderText.singleLine(ICalendar.unescape($0)) }?.trimmingCharacters(in: .whitespaces)
        let cutype = p.parameter("CUTYPE")?.uppercased()
        return Person(
            name: name?.isEmpty == false && name != value ? name : nil,
            address: value,
            status: p.parameter("PARTSTAT").flatMap { ParticipationStatus(rawValue: $0.uppercased()) } ?? .needsAction,
            isOptional: p.parameter("ROLE")?.uppercased() == "OPT-PARTICIPANT" || p.parameter("ROLE")?.uppercased() == "NON-PARTICIPANT",
            wantsReply: p.parameter("RSVP")?.uppercased() == "TRUE",
            isResource: cutype == "ROOM" || cutype == "RESOURCE"
        )
    }
}

// MARK: - Times

struct ICalTime {
    var date: Date
    var isAllDay: Bool
    var timeZone: TimeZone?
}

/// Turns DTSTART-style values into dates, honouring TZID (IANA, Windows names as Outlook sends
/// them, or the calendar's own VTIMEZONE as a last resort), UTC (`Z`) and floating times.
struct TimeZoneResolver {
    let definitions: [String: ICalComponent]

    init(_ vtimezones: [ICalComponent]) {
        var d: [String: ICalComponent] = [:]
        for tz in vtimezones { if let id = tz.property("TZID")?.value { d[id] = tz } }
        definitions = d
    }

    func time(_ p: ICalProperty) -> ICalTime? {
        let value = p.value.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber)
        if p.parameter("VALUE")?.uppercased() == "DATE" || (value.count == 8 && digits.count == 8) {
            guard let date = Self.components(value, time: false).flatMap({ Self.utc.date(from: $0) }) else { return nil }
            return ICalTime(date: date, isAllDay: true, timeZone: nil)
        }
        guard var c = Self.components(value, time: true) else { return nil }
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            c.timeZone = TimeZone(identifier: "UTC")
            return Self.utc.date(from: c).map { ICalTime(date: $0, isAllDay: false, timeZone: TimeZone(identifier: "UTC")) }
        }
        if let tzid = p.parameter("TZID") {
            if let zone = Self.zone(named: tzid) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                return cal.date(from: c).map { ICalTime(date: $0, isAllDay: false, timeZone: zone) }
            }
            if let definition = definitions[tzid], let offset = Self.offset(of: definition, at: c) {
                guard let utcDate = Self.utc.date(from: c) else { return nil }
                return ICalTime(date: utcDate.addingTimeInterval(-TimeInterval(offset)), isAllDay: false,
                                timeZone: TimeZone(secondsFromGMT: offset))
            }
        }
        // Floating time: the same wall-clock time wherever you are.
        return Calendar(identifier: .gregorian).date(from: c).map { ICalTime(date: $0, isAllDay: false, timeZone: nil) }
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func components(_ value: String, time: Bool) -> DateComponents? {
        let chars = Array(value)
        func int(_ from: Int, _ length: Int) -> Int? {
            guard chars.count >= from + length else { return nil }
            return Int(String(chars[from..<(from + length)]))
        }
        guard let y = int(0, 4), let m = int(4, 2), let d = int(6, 2), (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents(year: y, month: m, day: d, hour: 0, minute: 0, second: 0)
        if time {
            guard chars.count >= 15, chars[8] == "T" || chars[8] == "t",
                  let h = int(9, 2), let mi = int(11, 2) else { return nil }
            c.hour = h; c.minute = mi; c.second = int(13, 2) ?? 0
        }
        return c
    }

    /// IANA names, `/mozilla.org/…/Europe/Copenhagen`-style prefixes, and Windows names.
    static func zone(named raw: String) -> TimeZone? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let z = TimeZone(identifier: name) { return z }
        if let windows = windowsZones[name], let z = TimeZone(identifier: windows) { return z }
        // Try the last two or one path components ("…/Europe/Copenhagen", "…/UTC").
        let parts = name.split(separator: "/")
        if parts.count >= 2, let z = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) { return z }
        if let last = parts.last, let z = TimeZone(identifier: String(last)) { return z }
        // Outlook sometimes sends "(UTC+01:00) Amsterdam, Berlin, …" display names.
        for (key, id) in displayNameHints where name.contains(key) { return TimeZone(identifier: id) }
        return nil
    }

    /// The UTC offset (seconds) of a VTIMEZONE at a local wall-clock time, from its STANDARD and
    /// DAYLIGHT rules (RRULE with BYMONTH and BYDAY like `-1SU` or `2SU`).
    static func offset(of tz: ICalComponent, at local: DateComponents) -> Int? {
        let observances = tz.children.filter { $0.name == "STANDARD" || $0.name == "DAYLIGHT" }
        guard !observances.isEmpty, let year = local.year, let localDate = utc.date(from: local) else { return nil }
        // Find the observance whose most recent onset (this year or last) is latest before the time.
        var best: (onset: Date, offset: Int)?
        var fallback: Int?
        for o in observances {
            guard let to = o.property("TZOFFSETTO").flatMap({ parseOffset($0.value) }) else { continue }
            fallback = fallback ?? to
            guard let startValue = o.property("DTSTART")?.value, let start = components(startValue, time: true) else { continue }
            for y in [year - 1, year] {
                guard let onset = onset(of: o, start: start, year: y), onset <= localDate else { continue }
                if best == nil || onset > best!.onset { best = (onset, to) }
            }
        }
        return best?.offset ?? fallback
    }

    static func onset(of observance: ICalComponent, start: DateComponents, year: Int) -> Date? {
        guard let rule = observance.property("RRULE")?.value else {
            return start.year.map { $0 <= year } == true ? utc.date(from: start) : nil
        }
        let parts = ruleParts(rule)
        guard let month = parts["BYMONTH"].flatMap({ Int($0) }) ?? start.month, (1...12).contains(month) else { return nil }
        guard let byday = parts["BYDAY"], let weekday = weekdays[String(byday.suffix(2)).uppercased()] else {
            return utc.date(from: DateComponents(year: year, month: month, day: start.day, hour: start.hour, minute: start.minute))
        }
        let ordinal = Int(byday.dropLast(2)) ?? 1
        // RFC 5545 allows at most 53 weeks either way; a crafted value must not overflow below.
        guard (-maxWeekdayOrdinal...maxWeekdayOrdinal).contains(ordinal) else { return nil }
        if ordinal < 0 {
            return nthLastWeekday(weekday, fromEnd: -ordinal, month: month, year: year, hour: start.hour, minute: start.minute)
        }
        return utc.date(from: DateComponents(year: year, month: month, hour: start.hour, minute: start.minute,
                                             weekday: weekday, weekdayOrdinal: ordinal))
    }

    static let maxWeekdayOrdinal = 53

    /// `FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU` → ["FREQ": "YEARLY", "BYMONTH": "10", "BYDAY": "-1SU"].
    static func ruleParts(_ rule: String) -> [String: String] {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        return parts
    }

    /// `-1SU` (the last Sunday), `-2SU` (the one before): walked back from the month's end.
    static func nthLastWeekday(_ weekday: Int, fromEnd n: Int, month: Int, year: Int, hour: Int?, minute: Int?) -> Date? {
        guard let firstOfNext = utc.date(from: DateComponents(year: year, month: month + 1, day: 1)) else { return nil }
        let day = ICalDuration.secondsPerDay
        var date = firstOfNext.addingTimeInterval(-day)
        while utc.component(.weekday, from: date) != weekday { date.addTimeInterval(-day) }
        date.addTimeInterval(-TimeInterval((n - 1) * 7) * day)
        var components = utc.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        return utc.date(from: components)
    }

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    static func parseOffset(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst()
        guard digits.count >= 4, let h = Int(digits.prefix(2)), let m = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let seconds = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 0 : 0
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60 + seconds)
    }

    /// The Windows time zone names Outlook/Exchange put in TZID, for the zones people are most
    /// likely to meet. (A VTIMEZONE is always included too, so anything missing still resolves.)
    static let windowsZones: [String: String] = [
        "Romance Standard Time": "Europe/Paris",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "FLE Standard Time": "Europe/Helsinki",
        "E. Europe Standard Time": "Europe/Chisinau",
        "GTB Standard Time": "Europe/Bucharest",
        "Russian Standard Time": "Europe/Moscow",
        "Turkey Standard Time": "Europe/Istanbul",
        "UTC": "UTC",
        "Coordinated Universal Time": "UTC",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles",
        "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Atlantic Standard Time": "America/Halifax",
        "Canada Central Standard Time": "America/Regina",
        "E. South America Standard Time": "America/Sao_Paulo",
        "SA Pacific Standard Time": "America/Bogota",
        "Arabian Standard Time": "Asia/Dubai",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Africa Standard Time": "Africa/Johannesburg",
        "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "E. Australia Standard Time": "Australia/Brisbane",
        "W. Australia Standard Time": "Australia/Perth",
        "New Zealand Standard Time": "Pacific/Auckland",
    ]

    static let displayNameHints: [(String, String)] = [
        ("Copenhagen", "Europe/Copenhagen"), ("Amsterdam", "Europe/Amsterdam"), ("Brussels", "Europe/Brussels"),
        ("Stockholm", "Europe/Stockholm"), ("Dublin", "Europe/Dublin"), ("London", "Europe/London"),
        ("Helsinki", "Europe/Helsinki"), ("Eastern Time", "America/New_York"), ("Pacific Time", "America/Los_Angeles"),
        ("Central Time", "America/Chicago"), ("Mountain Time", "America/Denver"),
    ]
}

enum ICalDuration {
    static let secondsPerDay: TimeInterval = 86_400

    /// ISO 8601 / RFC 5545 durations: `PT1H30M`, `P1D`, `P2W`, `-PT15M`.
    static func seconds(_ raw: String) -> TimeInterval? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: TimeInterval = 1
        if s.first == "-" { sign = -1; s = s.dropFirst() } else if s.first == "+" { s = s.dropFirst() }
        guard s.first == "P" else { return nil }
        s = s.dropFirst()
        var total: TimeInterval = 0
        var number = ""
        for c in s {
            if c.isNumber { number.append(c); continue }
            if c == "T" { continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "W": total += n * 7 * secondsPerDay
            case "D": total += n * secondsPerDay
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
            number = ""
        }
        return number.isEmpty ? sign * total : nil
    }
}

/// Finds an online-meeting join link.
enum ConferenceLink {
    static let hosts = [
        "meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "zoomgov.com",
        "webex.com", "facetime.apple.com", "whereby.com", "meet.jit.si", "gotomeeting.com", "chime.aws",
    ]

    static func find(in fields: [String?]) -> String? {
        for case let field? in fields {
            for url in urls(in: field) {
                guard let host = URL(string: url)?.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    static func urls(in text: String) -> [String] {
        var result: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: "https://", options: .caseInsensitive, range: searchRange) {
            var end = r.upperBound
            while end < text.endIndex, !text[end].isWhitespace, !"<>\"'()[]{}|\\^`".contains(text[end]) {
                end = text.index(after: end)
            }
            var url = String(text[r.lowerBound..<end])
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            result.append(url)
            searchRange = end..<text.endIndex
        }
        return result
    }
}
