import Foundation

/// A `text/calendar` part on an outgoing message (an iTIP reply).
public struct OutgoingCalendar: Codable, Sendable, Hashable {
    public var method: CalendarInvite.Method
    public var ics: String

    public init(method: CalendarInvite.Method, ics: String) {
        self.method = method
        self.ics = ics
    }
}

extension CalendarInvite {
    /// The iTIP REPLY (RFC 5546 §3.2.3) that tells the organizer your answer. Echoes UID,
    /// SEQUENCE and RECURRENCE-ID exactly, which is what Google, Outlook and Apple match on.
    public func replyICS(as attendee: MailAddress, status: ParticipationStatus, comment: String? = nil,
                         now: Date = Date(), productID: String = "-//Tidings//Tidings Mail//EN") -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:\(productID)",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(Self.utcStamp(now))",
        ]
        if sequence > 0 { lines.append("SEQUENCE:\(sequence)") }
        if let recurrenceID { lines.append(Self.property("RECURRENCE-ID", recurrenceID.parameters, recurrenceID.value)) }
        if let organizer {
            var params: [String: String] = [:]
            if let name = organizer.name { params["CN"] = name }
            lines.append(Self.property("ORGANIZER", params, "mailto:\(organizer.address)"))
        }
        // Keep the attendee's address exactly as the organizer wrote it so the match succeeds.
        let invited = attendees.first { $0.address.caseInsensitiveCompare(attendee.address) == .orderedSame }
        var params = ["PARTSTAT": status.rawValue]
        if let name = attendee.name ?? invited?.name, !name.isEmpty { params["CN"] = name }
        lines.append(Self.property("ATTENDEE", params, "mailto:\(invited?.address ?? attendee.address)"))
        if !summary.isEmpty { lines.append("SUMMARY:\(ICalendar.escape(summary))") }
        if isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(Self.dayStamp(start))")
            if let end { lines.append("DTEND;VALUE=DATE:\(Self.dayStamp(end))") }
        } else {
            lines.append("DTSTART:\(Self.utcStamp(start))")
            if let end { lines.append("DTEND:\(Self.utcStamp(end))") }
        }
        if let comment, !comment.isEmpty { lines.append("COMMENT:\(ICalendar.escape(comment))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(ICalendar.fold).joined(separator: "\r\n") + "\r\n"
    }

    /// A ready-to-queue reply to the organizer. Subject and text come from the caller so the
    /// app can localize them ("Accepted: …" / "Accepteret: …").
    public func replyMessage(from identity: MailAddress, status: ParticipationStatus, subject: String, text: String,
                             comment: String? = nil, inReplyTo: String? = nil, references: [String] = [],
                             now: Date = Date()) -> OutgoingMessage? {
        guard let organizer else { return nil }
        var message = OutgoingMessage(
            from: identity, to: [organizer.mailAddress], subject: subject, text: text,
            inReplyTo: inReplyTo, references: references, date: now)
        message.calendar = OutgoingCalendar(method: .reply, ics: replyICS(as: identity, status: status, comment: comment, now: now))
        return message
    }

    /// One content line. Parameters can come from the invite (RECURRENCE-ID's are echoed), so
    /// names are reduced to iCalendar name characters and values kept on one line.
    static func property(_ name: String, _ parameters: [String: String], _ value: String) -> String {
        var line = name
        for rawKey in parameters.keys.sorted() {
            let key = String(rawKey.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
                .map(Character.init))
            guard !key.isEmpty else { continue }
            let v = HeaderText.singleLine(parameters[rawKey] ?? "")
            let needsQuotes = v.contains { ":;,".contains($0) } || v.contains(" ")
            line += ";\(key)=" + (needsQuotes ? "\"\(v.replacingOccurrences(of: "\"", with: "'"))\"" : v)
        }
        return line + ":" + HeaderText.singleLine(value)
    }

    static func utcStamp(_ date: Date) -> String {
        let c = TimeZoneResolver.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func dayStamp(_ date: Date) -> String {
        let c = TimeZoneResolver.utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
