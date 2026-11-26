import Foundation

/// Finds calendar-worthy dates and times in a message, cheapest layer first (SPEC §5):
/// 1. schema.org JSON-LD in the HTML (bookings, tickets, flights): trusted as is;
/// 2. `NSDataDetector` over what the sender wrote themselves (quotes stripped), with relative
///    dates ("i morgen", "næste tirsdag", "on Friday") re-anchored to when the message was sent
///    and times read in the sender's time zone unless the text names one ("14:00 CET").
/// Layer 3 (the on-device model) only reviews what this leaves uncertain; see `EventScanner`.
public enum EventExtractor {
    public struct Input: Sendable {
        public var subject: String
        /// The plain-text body (quoted history is stripped here).
        public var text: String
        public var html: String?
        /// When the message was sent: relative dates count from here.
        public var sent: Date
        /// The sender's time zone: times without a zone are read in it.
        public var timeZone: TimeZone

        public init(subject: String, text: String, html: String? = nil, sent: Date, timeZone: TimeZone) {
            self.subject = subject
            self.text = text
            self.html = html
            self.sent = sent
            self.timeZone = timeZone
        }

        /// From a parsed message: the sender's zone comes from the offset in its Date header.
        public init(parsed: ParsedMessage, fallbackDate: Date, localZone: TimeZone = .current) {
            let sent = parsed.date ?? fallbackDate
            self.init(subject: parsed.subject, text: parsed.plainText, html: parsed.html, sent: sent,
                      timeZone: EventExtractor.senderZone(dateHeader: parsed.header("Date"), sent: sent, local: localZone))
        }
    }

    public static let maxSuggestions = 3

    public static func extract(_ input: Input) -> [EventSuggestion] {
        if let html = input.html, html.range(of: "ld+json", options: .caseInsensitive) != nil {
            let structured = SchemaOrgEvents.extract(html: html, zone: input.timeZone)
            if !structured.isEmpty { return Array(structured.prefix(maxSuggestions)) }
        }
        return TextDates(input: input).suggestions()
    }

    /// The zone a sender's wall-clock times are in. A Date header only carries an offset
    /// (`+0100`): when it matches this Mac's zone at that moment, assume the same named zone (so
    /// a date across a DST change still comes out right); otherwise the fixed offset.
    public static func senderZone(dateHeader: String?, sent: Date, local: TimeZone = .current) -> TimeZone {
        guard let header = dateHeader else { return local }
        var s = header
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        let ns = s as NSString
        guard let m = offsetPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let seconds = TimeZoneResolver.parseOffset(ns.substring(with: m.range(at: 1))) else {
            return local
        }
        if local.secondsFromGMT(for: sent) == seconds { return local }
        if seconds == 0, s.uppercased().contains("GMT") || s.uppercased().contains("UT") { return TimeZone(identifier: "UTC")! }
        return TimeZone(secondsFromGMT: seconds) ?? local
    }

    static let offsetPattern = try! NSRegularExpression(pattern: #"([+-]\d{4})\s*$"#)
}

// MARK: - The text layer

struct TextDates {
    let input: EventExtractor.Input

    static let maxText = 8_000

    enum Day: Equatable {
        case explicit(yearGiven: Bool)
        case relative(days: Int)
        /// Calendar weekday (1 = Sunday); `next` for "next Friday" / "næste fredag".
        case weekday(Int, next: Bool)
        case none
    }

    struct Hit {
        var range: NSRange
        var text: String
        var components: DateComponents
        var zone: TimeZone?
        var duration: TimeInterval
        var day: Day
        var time: (hour: Int, minute: Int)?
        var inSubject: Bool
    }

    func suggestions() -> [EventSuggestion] {
        let body = String(MailStore.ownText(input.text).prefix(Self.maxText))
        var results: [EventSuggestion] = []
        for (text, isSubject) in [(body, false), (Self.cleanSubject(input.subject), true)] where !text.isEmpty {
            for hit in hits(in: text, isSubject: isSubject) {
                if let suggestion = suggestion(for: hit, in: text, body: body) { results.append(suggestion) }
            }
        }
        return Self.deduplicated(results)
    }

    // MARK: Detection

    func hits(in text: String, isSubject: Bool) -> [Hit] {
        let ns = text as NSString
        var hits: [Hit] = DataDetection.dates(in: text).compactMap { match in
            guard let date = match.date else { return nil }
            let matched = ns.substring(with: match.range)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = match.timeZone ?? .current
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let time = Self.statedTime(in: matched, matching: c)
            return Hit(range: match.range, text: matched, components: c, zone: match.timeZone, duration: match.duration,
                       day: Self.day(in: matched, components: c, time: time), time: time, inSubject: isSubject)
        }
        // "frokost onsdag 12:00-13:00" comes back as a date and a separate time: join them.
        var merged: [Hit] = []
        var i = 0
        while i < hits.count {
            var hit = hits[i]
            if hit.day != .none, hit.time == nil, i + 1 < hits.count {
                let next = hits[i + 1]
                let gapStart = hit.range.location + hit.range.length
                let gap = next.range.location - gapStart
                if next.day == .none, let t = next.time, gap >= 0, gap <= 12,
                   !ns.substring(with: NSRange(location: gapStart, length: gap)).contains(where: { ".!?\n".contains($0) }) {
                    hit.time = t
                    hit.duration = next.duration
                    hit.range = NSUnionRange(hit.range, next.range)
                    hit.text = ns.substring(with: hit.range)
                    i += 1
                }
            } else if hit.day == .none, hit.time != nil, i + 1 < hits.count {
                // "kl. 19 på fredag": the time first.
                let next = hits[i + 1]
                let gapStart = hit.range.location + hit.range.length
                let gap = next.range.location - gapStart
                if next.day != .none, next.time == nil, gap >= 0, gap <= 8 {
                    var joined = next
                    joined.time = hit.time
                    joined.duration = hit.duration
                    joined.range = NSUnionRange(hit.range, next.range)
                    joined.text = ns.substring(with: joined.range)
                    hit = joined
                    i += 1
                }
            }
            merged.append(hit)
            i += 1
        }
        hits = merged.filter { $0.day != .none }
        return hits
    }

    // MARK: Building a suggestion

    func suggestion(for hit: Hit, in text: String, body: String) -> EventSuggestion? {
        let zone = hit.zone ?? input.timeZone
        guard let (year, month, day) = resolveDay(hit, zone: zone) else { return nil }

        let start: Date
        var end: Date?
        let isAllDay = hit.time == nil
        if let t = hit.time {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            guard let s = cal.date(from: DateComponents(year: year, month: month, day: day, hour: t.hour, minute: t.minute)) else { return nil }
            start = s
            if hit.duration > 0, hit.duration <= 14 * 86_400 { end = s.addingTimeInterval(hit.duration) }
        } else {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let s = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            start = s
        }

        // Past (relative to the message) or implausibly far ahead: not a plan.
        let sentDayStart: Date = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = isAllDay ? TimeZone(identifier: "UTC")! : zone
            var c = Calendar(identifier: .gregorian)
            c.timeZone = zone
            let d = c.dateComponents([.year, .month, .day], from: input.sent)
            return cal.date(from: d) ?? input.sent
        }()
        if isAllDay ? start < sentDayStart : start < input.sent.addingTimeInterval(-3 * 3_600) { return nil }
        if start > input.sent.addingTimeInterval(500 * 86_400) { return nil }

        let (sentence, sentenceRange) = Self.sentence(around: hit.range, in: text)
        let lower = sentence.lowercased()
        let subjectLower = input.subject.lowercased()
        let keyword = Keywords.firstEvent(in: lower) ?? Keywords.firstEvent(in: subjectLower)
        if Keywords.hardNegative(in: lower) { return nil }
        if keyword == nil, Keywords.softNegative(in: lower) { return nil }

        var score = 0
        if hit.time != nil { score += 2 }
        if keyword != nil { score += 2 }
        if end != nil { score += 1 }
        if isAllDay && keyword == nil { return nil }
        guard score >= 2 else { return nil }
        let confidence: EventSuggestion.Confidence = score >= 4 ? .high : .medium

        let (title, guessed) = Self.title(sentence: sentence, hitRange: NSRange(location: hit.range.location - sentenceRange.location,
                                                                                 length: hit.range.length),
                                          subject: input.subject, keyword: keyword)
        return EventSuggestion(
            kind: .event, source: .text, title: title, start: start, end: end, isAllDay: isAllDay,
            timeZoneID: isAllDay ? nil : zone.identifier,
            location: Self.location(sentence: sentence, body: body),
            sourceText: String(sentence.prefix(240)), confidence: confidence, titleIsGuess: guessed
        )
    }

    /// The calendar day the hit means, anchored to the sent date (in the event's zone).
    func resolveDay(_ hit: Hit, zone: TimeZone) -> (Int, Int, Int)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let sentStart = cal.startOfDay(for: input.sent)
        func ymd(_ d: Date) -> (Int, Int, Int)? {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            guard let y = c.year, let m = c.month, let dd = c.day else { return nil }
            return (y, m, dd)
        }
        switch hit.day {
        case .explicit(let yearGiven):
            guard let m = hit.components.month, let d = hit.components.day else { return nil }
            if yearGiven, let y = hit.components.year { return (y, m, d) }
            // No year: the occurrence nearest after the message (allowing for a recap of last week).
            let sentYear = cal.component(.year, from: input.sent)
            guard let candidate = cal.date(from: DateComponents(year: sentYear, month: m, day: d)) else { return nil }
            return (candidate < sentStart.addingTimeInterval(-60 * 86_400) ? sentYear + 1 : sentYear, m, d)
        case .relative(let days):
            return cal.date(byAdding: .day, value: days, to: sentStart).flatMap(ymd)
        case .weekday(let weekday, let next):
            let today = cal.component(.weekday, from: input.sent)
            var delta = (weekday - today + 7) % 7
            // "fredag" said on a Friday is next week's; so is "next Thursday" said on a
            // Wednesday (tomorrow would be "tomorrow").
            if delta == 0 || (next && delta == 1) { delta += 7 }
            return cal.date(byAdding: .day, value: delta, to: sentStart).flatMap(ymd)
        case .none:
            return nil
        }
    }

    // MARK: Reading the matched text

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static let clockPattern = regex(#"(?<![\d.,:])(\d{1,2})[:.](\d{2})(?!\d)(?!\.\d)\s*(a\.?m\.?|p\.?m\.?)?"#)
    static let klPattern = regex(#"\bkl\.?\s*(\d{1,2})(?![\d])(?![:.]\d)"#)
    static let rangePattern = regex(#"\b(?:fra|from|mellem|between)\s+(\d{1,2})\s*(?:[-–]|til|to|og|and)\s*\d{1,2}\b"#)
    static let meridiemPattern = regex(#"(?<![\d.:])(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#)
    static let noonPattern = regex(#"\b(noon|midday|midnight|midnat)\b"#)

    /// A time actually written in the text (not the detector's default noon), when it agrees
    /// with what the detector understood.
    static func statedTime(in text: String, matching c: DateComponents) -> (hour: Int, minute: Int)? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var stated: [(hour: Int, minute: Int, meridiem: Bool)] = []
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        func twentyFour(_ h: Int, _ meridiem: String?) -> Int {
            guard let mer = meridiem?.lowercased() else { return h }
            if mer.hasPrefix("p") { return h < 12 ? h + 12 : h }
            return h == 12 ? 0 : h
        }
        for m in clockPattern.matches(in: text, range: all) {
            if let h = group(m, 1).flatMap(Int.init), let mi = group(m, 2).flatMap(Int.init) {
                stated.append((twentyFour(h, group(m, 3)), mi, group(m, 3) != nil))
            }
        }
        for m in klPattern.matches(in: text, range: all) {
            if let h = group(m, 1).flatMap(Int.init) { stated.append((h, 0, false)) }
        }
        for m in rangePattern.matches(in: text, range: all) {
            if let h = group(m, 1).flatMap(Int.init) { stated.append((h, 0, false)) }
        }
        for m in meridiemPattern.matches(in: text, range: all) {
            if let h = group(m, 1).flatMap(Int.init) { stated.append((twentyFour(h, group(m, 2)), 0, true)) }
        }
        for m in noonPattern.matches(in: text, range: all) {
            let word = group(m, 1)?.lowercased() ?? ""
            stated.append(word == "midnight" || word == "midnat" ? (0, 0, true) : (12, 0, true))
        }
        guard let h = c.hour, let mi = c.minute else { return nil }
        if stated.contains(where: { $0.hour == h && $0.minute == mi }) { return (h, mi) }
        // The detector sometimes guesses the wrong half of the day ("frokost kl. 12" as
        // midnight, "frokost" being breakfast in Norwegian). A bare "kl. 12" is noon; for other
        // hours trust its reading of the context ("dinner at 7" → 19:00).
        if let match = stated.first(where: { !$0.meridiem && $0.hour % 12 == h % 12 && $0.minute == mi }) {
            return (match.hour == 12 ? 12 : h, mi)
        }
        return nil
    }

    static let monthPattern = regex(#"\b(jan(uar|uary)?|feb(ruar|ruary)?|mar(ts|ch)?|apr(il)?|maj|may|jun[ei]?|jul[iy]?|aug(ust)?|sep(t|tember)?|o[ck]t(ober)?|nov(ember)?|dec(ember)?)\b\.?"#)
    static let numericDatePattern = regex(#"(?<![\d:])(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?(?![\d:])"#)
    static let isoDatePattern = regex(#"\b\d{4}-\d{2}-\d{2}\b"#)
    static let yearPattern = regex(#"\b(19|20)\d{2}\b"#)
    static let nextPattern = regex(#"\b(next|næste|kommende|coming)\b"#)
    static let pastPattern = regex(#"\b(last|previous|past|sidste|forrige|yesterday|i\s*går|i\s*forgårs|ago|siden)\b"#)
    static let inDaysPattern = regex(#"\b(?:in|om)\s+(\d{1,2})\s+(?:days|dage)\b"#)
    static let relativeWords: [(NSRegularExpression, Int)] = [
        (regex(#"\b(i\s+overmorgen|overmorgen|day\s+after\s+tomorrow)\b"#), 2),
        (regex(#"\b(i\s*morgen|tomorrow)\b"#), 1),
        (regex(#"\b(i\s*dag|today|tonight|this\s+evening|i\s*aften|i\s+nat)\b"#), 0),
    ]
    static let weekdayWords: [(NSRegularExpression, Int)] = [
        (regex(#"\b(sun(day)?|søn(dag)?)\b"#), 1),
        (regex(#"\b(mon(day)?|man(dag)?)\b"#), 2),
        (regex(#"\b(tue(s|sday)?|tirs(dag)?)\b"#), 3),
        (regex(#"\b(wed(nesday)?|ons(dag)?)\b"#), 4),
        (regex(#"\b(thu(r|rs|rsday)?|tors(dag)?)\b"#), 5),
        (regex(#"\b(fri(day)?|fre(dag)?)\b"#), 6),
        (regex(#"\b(sat(urday)?|lør(dag)?)\b"#), 7),
    ]

    static func day(in text: String, components c: DateComponents, time: (hour: Int, minute: Int)?) -> Day {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        // "last Monday", "sidste fredag", "i går": already happened.
        if pastPattern.firstMatch(in: text, range: all) != nil { return .none }
        let yearGiven = yearPattern.firstMatch(in: text, range: all) != nil
        if isoDatePattern.firstMatch(in: text, range: all) != nil || monthPattern.firstMatch(in: text, range: all) != nil {
            return .explicit(yearGiven: yearGiven)
        }
        for m in numericDatePattern.matches(in: text, range: all) {
            let a = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let b = Int(ns.substring(with: m.range(at: 2))) ?? 0
            if let t = time, t.hour == a, t.minute == b { continue }        // "10.30" is a time
            if (a == c.day && b == c.month) || (a == c.month && b == c.day) {
                return .explicit(yearGiven: yearGiven || m.range(at: 3).location != NSNotFound)
            }
        }
        if let m = inDaysPattern.firstMatch(in: text, range: all), let n = Int(ns.substring(with: m.range(at: 1))) {
            return .relative(days: n)
        }
        for (pattern, days) in relativeWords where pattern.firstMatch(in: text, range: all) != nil {
            return .relative(days: days)
        }
        for (pattern, weekday) in weekdayWords where pattern.firstMatch(in: text, range: all) != nil {
            return .weekday(weekday, next: nextPattern.firstMatch(in: text, range: all) != nil)
        }
        return .none
    }

    // MARK: Context

    static let abbreviations: Set<String> = ["kl", "d", "ca", "nr", "tlf", "mr", "mrs", "ms", "dr", "st", "no", "bl.a", "f.eks", "evt", "inkl", "jf", "vs", "etc", "e.g", "i.e"]

    /// The sentence around a range: within its line, cut at ". " / "! " / "? " except after
    /// abbreviations like "kl." and "d.".
    static func sentence(around range: NSRange, in text: String) -> (String, NSRange) {
        let ns = text as NSString
        let line = ns.lineRange(for: range)
        var start = line.location
        var end = line.location + line.length
        var i = line.location
        while i < line.location + line.length - 1 {
            let ch = ns.character(at: i)
            if ch == 0x2E || ch == 0x21 || ch == 0x3F, i + 1 < end, CharacterSet.whitespaces.contains(Unicode.Scalar(ns.character(at: i + 1)) ?? " ") {
                // The word before the punctuation.
                var w = i
                while w > line.location, let s = Unicode.Scalar(ns.character(at: w - 1)), CharacterSet.letters.contains(s) || s == "." { w -= 1 }
                let word = ns.substring(with: NSRange(location: w, length: i - w)).lowercased()
                let isAbbreviation = ch == 0x2E && (abbreviations.contains(word) || word.count == 1 || word.allSatisfy(\.isNumber))
                if !isAbbreviation {
                    if i < range.location { start = i + 1 } else if i >= range.location + range.length { end = i + 1; break }
                }
            }
            i += 1
        }
        let r = NSRange(location: start, length: max(0, end - start))
        let raw = ns.substring(with: r)
        let leading = raw.prefix { $0.isWhitespace }.utf16.count
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, NSRange(location: start + leading, length: (trimmed as NSString).length))
    }

    static func cleanSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        while let m = replyPrefix.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            s = (s as NSString).substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
        }
        return s == "(no subject)" ? "" : s
    }

    static let replyPrefix = regex(#"^(re|sv|aw|fw|fwd|vs|vb|wg)(\[\d+\])?\s*:\s*"#)
    static let genericSubjects: Set<String> = ["hej", "hi", "hello", "hey", "info", "spørgsmål", "question", "update", "opdatering",
                                               "news", "nyheder", "nyhedsbrev", "newsletter", "reminder", "påmindelse", "invitation", "fyi"]
    static let leadingFiller = regex(#"^(?:(?:hej|hi|hello|hey|kære|dear)\b[^,!.]*[,!.]\s*)?(?:(?:the|a|an|our|my|your|this|vores|min|mit|mine|din|dit|jeres|en|et|der|det|så|og|and|so|just|bare|husk|remember|reminder|påmindelse)\s+)*"#)
    /// "Vil I komme til …", "Join us for …": the plan is what follows.
    static let invitationLeadIn = regex(#"^(?:(?:vil|kan|skal)\s+(?:du|i|vi)\s+(?:komme|med|være\s+med|tage\s+med)|kom|vi\s+ses|vi\s+inviterer(?:\s+(?:dig|jer))?|(?:du|i)\s+er\s+inviteret|join\s+(?:us|me)|come|would\s+you\s+like\s+to\s+come|you(?:'re|\s+are)\s+invited|we\s+invite\s+you|see\s+you|save\s+the\s+date|(?:kan|skal)\s+vi\s+(?:flytte|rykke)|can\s+we\s+(?:move|reschedule)|(?:are|is)\s+you\s+free\s+for)\b(?:\s+(?:for|to|til|at|på|in|i|with|med))?(?:\s+(?:our|vores|the|a|an|en|et))?\s*"#)
    /// "Vi holder åbent hus" → "åbent hus".
    static let hostLeadIn = regex(#"^(?:vi\s+holder|vi\s+har|der\s+er|we(?:'re|\s+are)\s+(?:having|hosting|holding)|we\s+have|there(?:'s|\s+is))\s+"#)
    static let trailingFiller = regex(#"(?:\s+(?:is|are|will|be|takes|take|place|happens|on|at|from|starting|starts|begins|er|bliver|finder|sted|på|den|d\.?|kl\.?|om|i|fra|til|for|this|next|næste|denne|coming|kommende|the|og|and|confirmed|bekræftet|booket|booked|reserveret|scheduled|planlagt|[-–—:]))+\s*[-–—:,]?$"#)

    /// A short title: the words before the date when they name the plan ("Middag hos os"),
    /// else a meaningful subject, else the event word itself. `guessed` when it's a fallback.
    static func title(sentence: String, hitRange: NSRange, subject: String, keyword: String?) -> (String, Bool) {
        let ns = sentence as NSString
        if hitRange.location > 0, hitRange.location <= ns.length {
            var before = ns.substring(to: hitRange.location).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:—–-")))
            // Only the last clause before the date.
            if let cut = before.lastIndex(where: { ",;:!?\n".contains($0) }) { before = String(before[before.index(after: cut)...]) }
            for pattern in [leadingFiller, invitationLeadIn, leadingFiller, hostLeadIn, trailingFiller] {
                before = pattern.stringByReplacingMatches(in: before, range: NSRange(location: 0, length: (before as NSString).length), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var words = before.split(whereSeparator: \.isWhitespace)
            if words.count > 4, let first = Keywords.event.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) {
                // "at vi skal til tandlæge" → "tandlæge"
                before = (before as NSString).substring(from: first.range.location)
                words = before.split(whereSeparator: \.isWhitespace)
            }
            if (1...7).contains(words.count), Keywords.firstEvent(in: before.lowercased()) != nil {
                let question = questionStart.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
                return (capitalized(before), question)
            }
        }
        if let head = head(of: sentence), Keywords.firstEvent(in: head.lowercased()) != nil {
            return (capitalized(head), false)
        }
        let cleaned = cleanSubject(subject)
        if !cleaned.isEmpty, cleaned.count <= 60, !genericSubjects.contains(cleaned.lowercased()),
           Keywords.firstEvent(in: cleaned.lowercased()) != nil {
            // The subject names it; drop a trailing date ("Middag fredag kl. 19" → "Middag").
            let ns = cleaned as NSString
            if let first = DataDetection.dates(in: cleaned).first, first.range.location > 0 {
                var head = ns.substring(to: first.range.location)
                head = trailingFiller.stringByReplacingMatches(in: head, range: NSRange(location: 0, length: (head as NSString).length), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty { return (capitalized(head), false) }
            }
            return (cleaned, false)
        }
        if let keyword { return (capitalized(keyword), true) }
        return (cleaned.count <= 60 ? cleaned : "", true)
    }

    /// "Skal vi ses igen", "Can we meet": usable, but the model may find a better title.
    static let questionStart = regex(#"^(kan|skal|vil|må|can|shall|will|could|would|should|are|is|do|does)\b"#)
    static let dateWord = regex(#"^(kl\.?|at|on|den|d\.|om|in|i|by|from|fra|next|næste|this|på|\d.*|(?:to|i)?morgen|today|tonight|tomorrow|dag|aften|overmorgen|(?:man|tirs|ons|tors|fre|lør|søn)(?:dag)?|(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(?:day)?|jan.*|feb.*|mar.*|apr.*|maj|may|jun.*|jul.*|aug.*|sep.*|o[ck]t.*|nov.*|dec.*)[,.]?$"#)

    /// The words a sentence starts with, up to its first date word: "Middag fredag kl. 19" → "Middag".
    static func head(of sentence: String) -> String? {
        var stripped = sentence
        for pattern in [leadingFiller, invitationLeadIn, leadingFiller, hostLeadIn] {
            stripped = pattern.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
        }
        var words: [Substring] = []
        for word in stripped.split(whereSeparator: \.isWhitespace) {
            let w = String(word)
            if dateWord.firstMatch(in: w, range: NSRange(location: 0, length: (w as NSString).length)) != nil { break }
            words.append(word)
        }
        guard (1...6).contains(words.count) else { return nil }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",:;-–— "))
    }

    static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static let locationLabel = regex(#"^\s*(?:location|where|venue|place|address|sted|hvor|adresse|lokation|lokale|mødested)\s*:\s*(.{2,120})$"#)

    /// "Sted: …" / "Location: …" lines, else a postal address in the sentence.
    static func location(sentence: String, body: String) -> String? {
        for line in body.split(separator: "\n").prefix(200) {
            let l = String(line)
            let lns = l as NSString
            if let m = locationLabel.firstMatch(in: l, range: NSRange(location: 0, length: lns.length)) {
                let value = lns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        if let range = DataDetection.firstAddress(in: sentence) {
            return (sentence as NSString).substring(with: range)
        }
        return nil
    }

    /// One per start time; a timed one beats an all-day one on the same day; best first.
    static func deduplicated(_ all: [EventSuggestion]) -> [EventSuggestion] {
        var kept: [EventSuggestion] = []
        for s in all {
            if let i = kept.firstIndex(where: { $0.id == s.id }) {
                if s.confidence > kept[i].confidence { kept[i] = s }
                continue
            }
            kept.append(s)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let timedOnes = kept.filter { !$0.isAllDay }
        kept.removeAll { allDay in
            guard allDay.isAllDay else { return false }
            let day = utc.dateComponents([.year, .month, .day], from: allDay.start)
            return timedOnes.contains { timed in
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = timed.timeZone ?? .current
                return cal.dateComponents([.year, .month, .day], from: timed.start) == day
            }
        }
        let ordered = kept.enumerated().sorted { a, b in
            a.element.confidence != b.element.confidence ? a.element.confidence > b.element.confidence : a.offset < b.offset
        }.map(\.element)
        return Array(ordered.prefix(EventExtractor.maxSuggestions))
    }
}

// MARK: - Words

/// Danish and English words that make a date a plan, or make it clearly not one.
enum Keywords {
    static func pattern(_ words: [String]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:" + words.joined(separator: "|") + ")", options: [.caseInsensitive])
    }

    /// Prefix matches (Danish inflects: "mødet", "middagen", "festen"); `\b` where a prefix would be too greedy.
    static let event = pattern([
        // English
        "meeting", "meet\\b", "meet up", "meetup", "call\\b", "video call", "dinner", "lunch", "breakfast", "brunch", "drinks",
        "coffee", "party", "birthday", "wedding", "concert", "gig\\b", "match\\b", "game\\b", "webinar", "workshop", "seminar",
        "conference", "summit", "event", "appointment", "interview", "reservation", "booking", "table for", "check-in",
        "check in", "flight", "departure", "boarding", "doors open", "kick-?off", "session", "lecture", "training",
        "rehearsal", "ceremony", "reception", "gathering", "celebration", "see you", "join us", "join me", "invited",
        "invite you", "rsvp", "tour\\b", "viewing", "screening", "premiere", "festival", "hangout", "catch up", "catch-up",
        "demo\\b", "stand-?up", "presentation", "class\\b", "course", "dentist", "doctor", "haircut", "game night",
        "get-together", "get together", "open house", "save the date", "live stream", "livestream", "q&a", "town hall", "all-hands", "offsite", "retreat",
        // Danish
        "møde", "mødes", "ses\\b", "vi ses", "middag", "frokost", "morgenmad", "aftensmad", "kaffe", "fest", "fødselsdag",
        "bryllup", "koncert", "forestilling", "kamp\\b", "kampen", "arrangement", "begivenhed", "aftale", "tid hos",
        "samtale", "jobsamtale", "bord til", "indtjekning", "fly\\b", "flyet", "afgang", "dørene åbner", "kursus",
        "foredrag", "træning", "øvning", "ceremoni", "sammenkomst", "fejring", "inviter", "tilmeld", "besøg", "rundvisning",
        "fremvisning", "julefrokost", "komsammen", "spisning", "generalforsamling", "forældremøde", "tandlæge", "læge\\b",
        "lægen", "frisør", "opkald", "videomøde", "teams-møde", "zoom", "konfirmation", "barnedåb",
        "workshoppen", "undervisning", "eksamen", "prøve\\b", "forelæsning", "messe\\b", "loppemarked", "banko", "quiz",
        "åbent hus", "sankthans", "julefest", "nytårsfest", "grill", "picnic", "picnik", "udflugt", "tur\\b", "turen",
    ])

    /// Dates that are never plans: history, paperwork, deliveries, opening hours.
    static let hard = pattern([
        "ago\\b", "updated", "last updated", "posted", "published", "shipped", "delivered", "dispatched", "invoice",
        "receipt", "paid\\b", "payment", "due date", "due on", "expires", "expiry", "expiration", "valid until",
        "valid through", "wrote:", "copyright", "unsubscribe", "statement", "renews", "renewal",
        "trial ends", "opening hours", "office hours", "mon-fri", "mon–fri",
        "parcel", "package", "pick up your", "collect your",
        "opdateret", "udgivet", "afsendt", "leveret", "levering", "forsendelse", "pakke", "afhent", "pakkeshop", "faktura", "kvittering",
        "betalt", "betaling", "betales", "forfald", "udløber", "gyldig til", "skrev:", "fornyes",
        "åbningstid", "telefontid", "kontortid", "man-fre", "man–fre", "abonnement", "tilbuddet gælder", "gælder til",
        "sale ends", "offer ends", "udsalg",
    ])

    /// Dates that usually aren't plans, unless the sentence also names one.
    static let soft = pattern([
        "order", "ordered", "placed", "since", "notes", "minutes from", "recap", "referat", "tidligere", "earlier", "deadline", "submit", "reply by", "respond by", "no later than",
        "ordre", "bestilt", "bestilling", "siden", "frist", "senest", "svar",
    ])

    /// Danish compounds end in the word that matters: "sommerfest", "forældremøde", "julemarked".
    static let compound = try! NSRegularExpression(
        pattern: "\\p{L}+(?:fest|festen|frokost|frokosten|møde|mødet|koncert|koncerten|marked|markedet|træning|kursus|foredrag|(?<!efter)middag|middagen)\\b",
        options: [.caseInsensitive])

    static func firstEvent(in text: String) -> String? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        return (event.firstMatch(in: text, range: all) ?? compound.firstMatch(in: text, range: all)).map { ns.substring(with: $0.range) }
    }

    /// Header-like lines ("Sent: …", "Dato: …") of a pasted or forwarded message.
    static let headerLine = try! NSRegularExpression(pattern: "^\\s*(?:sent|date|dato|sendt|modtaget|received)\\s*:", options: [.caseInsensitive])

    static func hardNegative(in text: String) -> Bool {
        let all = NSRange(location: 0, length: (text as NSString).length)
        return hard.firstMatch(in: text, range: all) != nil || headerLine.firstMatch(in: text, range: all) != nil
    }

    static func softNegative(in text: String) -> Bool {
        soft.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
