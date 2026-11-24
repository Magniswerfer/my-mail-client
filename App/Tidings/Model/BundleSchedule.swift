import Foundation
import MailEngine

/// When a bundle's mail shows up in the Inbox (SPEC §4: bundle delivery schedules).
enum BundleSchedule: Codable, Hashable {
    case immediately
    case daily(hour: Int, minute: Int)

    /// Newsletters and advertising arrive once a day by default; everything else straight away.
    static func defaultFor(_ category: MailCategory) -> BundleSchedule {
        switch category {
        case .newsletters, .advertising: .daily(hour: 17, minute: 0)
        default: .immediately
        }
    }

    /// The most recent delivery moment at or before `now` (nil for immediate).
    func lastDelivery(before now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard case .daily(let hour, let minute) = self else { return nil }
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
    }

    func nextDelivery(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let last = lastDelivery(before: now, calendar: calendar) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: last)
    }
}

enum BundleScheduleStorage {
    static let key = "bundleSchedules.v1"

    static func load() -> [MailCategory: BundleSchedule] {
        var result = Dictionary(uniqueKeysWithValues: MailCategory.allCases.map { ($0, BundleSchedule.defaultFor($0)) })
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: BundleSchedule].self, from: data) {
            for (raw, schedule) in saved { if let c = MailCategory(rawValue: raw) { result[c] = schedule } }
        }
        return result
    }

    static func save(_ schedules: [MailCategory: BundleSchedule]) {
        let raw = Dictionary(uniqueKeysWithValues: schedules.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: key)
    }
}
