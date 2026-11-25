import Foundation

// MARK: - Signature details (Contact sidebar)

/// Links and phone numbers from the bottom of someone's latest message: their signature.
public struct SignatureInfo: Sendable, Hashable {
    public enum LinkKind: String, Sendable, Hashable { case linkedIn, x, github, mastodon, bluesky, website }

    public struct Link: Sendable, Hashable {
        public var kind: LinkKind
        public var url: String
        public var label: String
    }

    public var links: [Link] = []
    public var phones: [String] = []

    static let webmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "yahoo.com", "yahoo.dk", "aol.com", "proton.me", "protonmail.com",
        "hey.com", "fastmail.com", "gmx.com", "gmx.net", "mail.dk", "jubii.dk", "hotmail.dk", "live.dk",
    ]

    public static func looksAutomated(_ address: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let normalized = local.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        return SignalClassifier.automatedLocalParts.contains { normalized == $0 || normalized.hasPrefix($0 + "-") }
    }

    /// Reads the last lines of what the sender wrote (quotes removed) — where signatures live.
    public static func extract(from body: String) -> SignatureInfo {
        let lines = MailStore.ownLines(body).map(String.init)
        let tail = lines.suffix(14).joined(separator: "\n")
        var info = SignatureInfo()
        var seen = Set<String>()
        for raw in urls(in: tail) {
            let url = raw.hasPrefix("http") ? raw : "https://" + raw
            guard let host = URL(string: url)?.host?.lowercased(), seen.insert(url.lowercased()).inserted else { continue }
            let path = URL(string: url)?.path ?? ""
            let kind: LinkKind
            switch true {
            case host.hasSuffix("linkedin.com"): kind = .linkedIn
            case host == "x.com" || host.hasSuffix("twitter.com"): kind = .x
            case host.hasSuffix("github.com"): kind = .github
            case host.hasSuffix("bsky.app"): kind = .bluesky
            case path.hasPrefix("/@"): kind = .mastodon
            default: kind = .website
            }
            // Tracking redirects and images aren't anyone's website.
            if kind == .website, host.contains("safelinks") || host.contains("urldefense") || path.hasSuffix(".png") || path.hasSuffix(".jpg") { continue }
            let label = kind == .website ? host.replacingOccurrences(of: "www.", with: "") : String(path.split(separator: "/").last ?? Substring(host))
            info.links.append(Link(kind: kind, url: url, label: label))
        }
        for match in tail.matches(of: /(?:\+|00)?\d[\d \-().]{6,}\d/) {
            let number = String(match.output).trimmingCharacters(in: .whitespaces)
            let digits = number.filter(\.isNumber)
            // 8–15 digits, and not a date or an order number in disguise.
            guard (8...15).contains(digits.count), !number.contains("."), seen.insert(digits).inserted else { continue }
            info.phones.append(number)
        }
        return info
    }

    static func urls(in text: String) -> [String] {
        let full = text.matches(of: /(?:https?:\/\/|www\.)[^\s<>"'()\[\]]+/).map { m in
            var s = String(m.output)
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            return s
        }
        // "linkedin.com/in/anna" written without https://
        let bare = text.matches(of: /(?:linkedin\.com\/in\/|github\.com\/)[\w\-]+/).map { String($0.output) }
            .filter { b in !full.contains { $0.contains(b) } }
        return full + bare
    }
}

// MARK: - Share Availability

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
        var result: [Slot] = []
        var day = calendar.startOfDay(for: now)
        var counted = 0
        while counted < options.days {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            if options.skipWeekends, calendar.isDateInWeekend(day) { continue }
            guard var cursor = calendar.date(bySettingHour: options.dayStartHour, minute: 0, second: 0, of: day),
                  let dayEnd = calendar.date(bySettingHour: options.dayEndHour, minute: 0, second: 0, of: day) else { continue }
            cursor = max(cursor, quarter(now.addingTimeInterval(Double(options.leadMinutes) * 60), calendar: calendar, up: true))
            // A working day that's already over doesn't count towards `days`.
            guard cursor < dayEnd else { continue }
            counted += 1
            var slots: [Slot] = []
            for event in busy where event.end > cursor && event.start < dayEnd {
                let freeEnd = quarter(min(event.start, dayEnd), calendar: calendar, up: false)
                if freeEnd.timeIntervalSince(cursor) >= Double(options.minimumMinutes) * 60 {
                    slots.append(Slot(start: cursor, end: freeEnd))
                }
                cursor = max(cursor, quarter(event.end, calendar: calendar, up: true))
            }
            if dayEnd.timeIntervalSince(cursor) >= Double(options.minimumMinutes) * 60 {
                slots.append(Slot(start: cursor, end: dayEnd))
            }
            // The longest few of the day, in time order.
            let best = slots.sorted { $0.end.timeIntervalSince($0.start) > $1.end.timeIntervalSince($1.start) }
                .prefix(options.maxSlotsPerDay).sorted { $0.start < $1.start }
            result += best
        }
        return result
    }

    static func quarter(_ date: Date, calendar: Calendar, up: Bool) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let minutes = (c.minute ?? 0) * 60 + (c.second ?? 0)
        let step = 15 * 60
        let rounded = up ? ((minutes + step - 1) / step) * step : (minutes / step) * step
        var d = c
        d.minute = 0
        d.second = 0
        guard let hour = calendar.date(from: d) else { return date }
        return hour.addingTimeInterval(Double(rounded))
    }
}

// MARK: - Instant Intro

/// "Alice, meet Bob": reply to everyone the introducer brought in, and move the introducer to
/// Bcc so they see you followed up but drop out of the rest of the thread.
public enum IntroReply {
    public struct Plan: Sendable, Hashable {
        public var introducer: MailAddress
        public var to: [MailAddress]
        public var cc: [MailAddress]
        public var bcc: [MailAddress]
    }

    /// Nil when there's nobody to reply to besides the introducer.
    public static func plan(for message: ParsedMessage, ownAddresses: Set<String>) -> Plan? {
        let own = Set(ownAddresses.map { $0.lowercased() })
        guard let introducer = (message.replyTo.first ?? message.from.first),
              !own.contains(introducer.address.lowercased()) else { return nil }
        var seen: Set<String> = own.union([introducer.address.lowercased()])
        message.from.forEach { seen.insert($0.address.lowercased()) }
        let to = message.to.filter { seen.insert($0.address.lowercased()).inserted }
        let cc = message.cc.filter { seen.insert($0.address.lowercased()).inserted }
        guard !to.isEmpty || !cc.isEmpty else { return nil }
        // Everyone introduced goes on To; the introducer's own Cc'd colleagues stay on Cc.
        return to.isEmpty ? Plan(introducer: introducer, to: cc, cc: [], bcc: [introducer])
                          : Plan(introducer: introducer, to: to, cc: cc, bcc: [introducer])
    }

    /// "Anna" from "Anna Holm", "anna.holm@firma.dk" → "Anna".
    public static func firstName(_ address: MailAddress) -> String {
        if let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // "Holm, Anna" → "Anna"
            if let comma = name.firstIndex(of: ",") {
                return name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? name
            }
            return name.split(separator: " ").first.map(String.init) ?? name
        }
        let local = address.address.split(separator: "@").first.map(String.init) ?? address.address
        let first = local.split(whereSeparator: { ".-_".contains($0) }).first.map(String.init) ?? local
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}

// MARK: - Needs a reply? (Auto Drafts for incoming mail)

/// Cheap signals that a message asks the reader something: a question, or a request phrase,
/// in the sender's own words (quotes and signature ignored). Danish and English.
public enum NeedsReply {
    static let requests = [
        "could you", "can you", "would you", "will you", "please", "let me know", "what do you think",
        "are you available", "do you have time", "any thoughts", "when can", "please confirm",
        "kan du", "vil du", "kunne du", "har du mulighed", "venligst", "lad mig vide", "giv lyd",
        "hvad synes du", "hvad siger du", "passer det", "har du tid", "bekræft",
    ]

    public static func likely(subject: String, text: String) -> Bool {
        let own = SendCheck.ownText(text)
        guard own.count >= 15 else { return false }
        let lower = own.lowercased()
        // Questions near the end of the message are the strongest signal.
        if own.contains("?") { return true }
        return requests.contains { lower.contains($0) } || subject.trimmingCharacters(in: .whitespaces).hasSuffix("?")
    }
}
