import Foundation

/// A date `NSDataDetector` found in text.
struct DetectedDate {
    var range: NSRange
    var date: Date?
    var timeZone: TimeZone?
    var duration: TimeInterval
}

/// `NSDataDetector` where Foundation has it (Apple platforms). On Linux (the push server,
/// ADR 0007) it finds nothing, so date suggestions are a device-only feature.
enum DataDetection {
    /// False on Linux, where nothing is detected.
    static var isAvailable: Bool {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    private static let dateDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let addressDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
    #endif

    static func dates(in text: String) -> [DetectedDate] {
        #if canImport(Darwin)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return dateDetector.matches(in: text, range: range).map {
            DetectedDate(range: $0.range, date: $0.date, timeZone: $0.timeZone, duration: $0.duration)
        }
        #else
        return []
        #endif
    }

    static func firstAddress(in text: String) -> NSRange? {
        #if canImport(Darwin)
        return addressDetector.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
        #else
        return nil
        #endif
    }
}
