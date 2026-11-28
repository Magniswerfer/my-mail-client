import Foundation

/// Your free time for "Share Availability": working hours minus busy calendar events.
public enum Availability {
    public struct Slot: Sendable, Hashable {
        public var start: Date
        public var end: Date
    }

    public struct Options: Sendable {
        public var days: Int = 5
        public var dayStartHour = 9
        public var dayEndHour = 17
        public var minimumMinutes = 30
        public var skipWeekends = true
        /// Don't offer times starting sooner than this.
        public var leadMinutes = 60
        public var maxSlotsPerDay = 3
        public init() {}
    }

    /// Free slots, earliest first, each at least `minimumMinutes` long, snapped to the quarter hour.
    public static func freeSlots(busy: [DateInterval], from now: Date, calendar: Calendar = .current,
                                 options: Options = Options()) -> [Slot] {
        let busy = busy.sorted { $0.start < $1.start }
        let earliest = quarter(now.addingTimeInterval(TimeInterval(options.leadMinutes) * 60), calendar: calendar, up: true)
        var result: [Slot] = []
        var day = calendar.startOfDay(for: now)
        var counted = 0
        while counted < options.days {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            if options.skipWeekends, calendar.isDateInWeekend(day) { continue }
            guard let dayStart = calendar.date(bySettingHour: options.dayStartHour, minute: 0, second: 0, of: day),
                  let dayEnd = calendar.date(bySettingHour: options.dayEndHour, minute: 0, second: 0, of: day) else { continue }
            let start = max(dayStart, earliest)
            // A working day that's already over doesn't count towards `days`.
            guard start < dayEnd else { continue }
            counted += 1
            result += longestFreeSlots(from: start, to: dayEnd, busy: busy, calendar: calendar, options: options)
        }
        return result
    }

    /// The gaps between busy events in one working day: the longest `maxSlotsPerDay`, in time order.
    static func longestFreeSlots(from start: Date, to dayEnd: Date, busy: [DateInterval], calendar: Calendar,
                                 options: Options) -> [Slot] {
        let minimumLength = TimeInterval(options.minimumMinutes) * 60
        var cursor = start
        var slots: [Slot] = []
        for event in busy where event.end > cursor && event.start < dayEnd {
            let freeEnd = quarter(min(event.start, dayEnd), calendar: calendar, up: false)
            if freeEnd.timeIntervalSince(cursor) >= minimumLength {
                slots.append(Slot(start: cursor, end: freeEnd))
            }
            cursor = max(cursor, quarter(event.end, calendar: calendar, up: true))
        }
        if dayEnd.timeIntervalSince(cursor) >= minimumLength {
            slots.append(Slot(start: cursor, end: dayEnd))
        }
        return slots.sorted { $0.end.timeIntervalSince($0.start) > $1.end.timeIntervalSince($1.start) }
            .prefix(options.maxSlotsPerDay).sorted { $0.start < $1.start }
    }

    static let slotStepSeconds = 15 * 60

    static func quarter(_ date: Date, calendar: Calendar, up: Bool) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let secondsIntoHour = (c.minute ?? 0) * 60 + (c.second ?? 0)
        let step = slotStepSeconds
        let rounded = up ? ((secondsIntoHour + step - 1) / step) * step : (secondsIntoHour / step) * step
        var d = c
        d.minute = 0
        d.second = 0
        guard let hour = calendar.date(from: d) else { return date }
        return hour.addingTimeInterval(Double(rounded))
    }
}
