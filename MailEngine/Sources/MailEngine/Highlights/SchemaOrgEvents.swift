import Foundation

/// schema.org JSON-LD in HTML mail (the markup airlines, hotels, ticket shops and booking sites
/// embed for Gmail and Apple Mail): `Event` and its subtypes, `EventReservation`,
/// `FlightReservation`, `LodgingReservation` and `FoodEstablishmentReservation`.
enum SchemaOrgEvents {
    static func extract(html: String, zone: TimeZone) -> [EventSuggestion] {
        var found: [EventSuggestion] = []
        for block in scripts(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            for node in flatten(json) {
                if let suggestion = suggestion(from: node, zone: zone),
                   !found.contains(where: { $0.id == suggestion.id }) {
                    found.append(suggestion)
                }
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    // MARK: Markup

    static let scriptPattern = try! NSRegularExpression(
        pattern: #"<script[^>]*type\s*=\s*["']?application/ld\+json["']?[^>]*>(.*?)</script\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func scripts(in html: String) -> [String] {
        let ns = html as NSString
        return scriptPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            var text = ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Some senders wrap it in an HTML comment or CDATA.
            for (open, close) in [("<!--", "-->"), ("<![CDATA[", "]]>")] where text.hasPrefix(open) && text.hasSuffix(close) {
                text = String(text.dropFirst(open.count).dropLast(close.count))
            }
            return text
        }
    }

    /// Every object, from top-level arrays and `@graph` lists.
    static func flatten(_ json: Any) -> [[String: Any]] {
        if let array = json as? [Any] { return array.flatMap(flatten) }
        guard let object = json as? [String: Any] else { return [] }
        if let graph = object["@graph"] { return flatten(graph) }
        return [object]
    }

    static func types(_ node: [String: Any]) -> [String] {
        let raw: [String] = (node["@type"] as? String).map { [$0] } ?? (node["@type"] as? [String]) ?? []
        return raw.map { $0.components(separatedBy: "/").last ?? $0 }
    }

    // MARK: Types

    /// What a booking shares whatever it books.
    struct Booking {
        var number: String?
        var url: String?
    }

    /// A restaurant booking without an end time takes this long.
    static let defaultRestaurantDuration: TimeInterval = 2 * 3_600
    static let maxSourceTextLength = 240

    static func suggestion(from node: [String: Any], zone: TimeZone) -> EventSuggestion? {
        let kinds = types(node)
        if let status = string(node["reservationStatus"]) ?? string(node["eventStatus"]),
           status.localizedCaseInsensitiveContains("cancel") { return nil }
        let booking = Booking(number: string(node["reservationNumber"]) ?? string(node["confirmationNumber"]),
                              url: string(node["url"]) ?? string(node["modifyReservationUrl"]))
        if kinds.contains("FlightReservation") { return flight(node, booking: booking, zone: zone) }
        if kinds.contains("LodgingReservation") { return lodging(node, booking: booking, zone: zone) }
        if kinds.contains("FoodEstablishmentReservation") { return restaurant(node, booking: booking, zone: zone) }
        return event(node, kinds: kinds, booking: booking, zone: zone)
    }

    static func flight(_ node: [String: Any], booking: Booking, zone: TimeZone) -> EventSuggestion? {
        let flight = object(node["reservationFor"]) ?? [:]
        guard let start = time(flight["departureTime"], zone: zone) else { return nil }
        let airline = object(flight["airline"])
        let code = string(airline?["iataCode"]) ?? ""
        var flightNumber = string(flight["flightNumber"]) ?? ""
        if !code.isEmpty, !flightNumber.uppercased().hasPrefix(code.uppercased()) { flightNumber = code + flightNumber }
        let from = airport(flight["departureAirport"])
        let to = airport(flight["arrivalAirport"])
        let route = [from.code, to.code].compactMap { $0 }.joined(separator: " → ")
        let title = [flightNumber.isEmpty ? (string(airline?["name"]) ?? "") : flightNumber, route]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let end = time(flight["arrivalTime"], zone: zone)
        return EventSuggestion(kind: .flight, source: .schemaOrg, title: title, start: start.date,
                               end: end.map(\.date).flatMap { $0 > start.date ? $0 : nil },
                               timeZoneID: start.zone.identifier, location: from.name ?? from.code,
                               sourceText: title, confidence: .high, titleIsGuess: title.isEmpty,
                               reservationNumber: booking.number, url: booking.url)
    }

    static func lodging(_ node: [String: Any], booking: Booking, zone: TimeZone) -> EventSuggestion? {
        let place = object(node["reservationFor"]) ?? [:]
        guard let checkIn = time(node["checkinTime"] ?? node["checkinDate"], zone: zone) else { return nil }
        let checkOut = time(node["checkoutTime"] ?? node["checkoutDate"], zone: zone)
        let name = string(place["name"]) ?? ""
        return EventSuggestion(kind: .lodging, source: .schemaOrg, title: name, start: checkIn.date,
                               end: checkOut.map(\.date).flatMap { $0 > checkIn.date ? $0 : nil },
                               isAllDay: checkIn.isAllDay, timeZoneID: checkIn.isAllDay ? nil : checkIn.zone.identifier,
                               location: address(place["address"]) ?? name, sourceText: name, confidence: .high,
                               titleIsGuess: name.isEmpty, reservationNumber: booking.number, url: booking.url)
    }

    static func restaurant(_ node: [String: Any], booking: Booking, zone: TimeZone) -> EventSuggestion? {
        let place = object(node["reservationFor"]) ?? [:]
        guard let start = time(node["startTime"] ?? node["startDate"], zone: zone) else { return nil }
        let end = time(node["endTime"] ?? node["endDate"], zone: zone)?.date
        let name = string(place["name"]) ?? ""
        let defaultEnd = start.isAllDay ? nil : start.date.addingTimeInterval(defaultRestaurantDuration)
        return EventSuggestion(kind: .restaurant, source: .schemaOrg, title: name, start: start.date,
                               end: end.flatMap { $0 > start.date ? $0 : nil } ?? defaultEnd,
                               isAllDay: start.isAllDay, timeZoneID: start.isAllDay ? nil : start.zone.identifier,
                               location: [name, address(place["address"])].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                               sourceText: name, confidence: .high, titleIsGuess: name.isEmpty,
                               reservationNumber: booking.number, url: booking.url)
    }

    /// An event, or a ticket for one.
    static func event(_ node: [String: Any], kinds: [String], booking: Booking, zone: TimeZone) -> EventSuggestion? {
        var event = node
        if kinds.contains("EventReservation") || kinds.contains("Reservation"), let target = object(node["reservationFor"]) {
            event = target
        } else if !kinds.contains(where: { $0.hasSuffix("Event") }) {
            return nil
        }
        if let status = string(event["eventStatus"]), status.localizedCaseInsensitiveContains("cancel") { return nil }
        guard let start = time(event["startDate"], zone: zone) else { return nil }
        let name = string(event["name"]) ?? ""
        var endDate = time(event["endDate"], zone: zone)?.date
        if start.isAllDay, let e = endDate { endDate = e.addingTimeInterval(ICalDuration.secondsPerDay) }   // endDate is inclusive
        return EventSuggestion(kind: .event, source: .schemaOrg, title: name, start: start.date,
                               end: endDate.flatMap { $0 > start.date ? $0 : nil },
                               isAllDay: start.isAllDay, timeZoneID: start.isAllDay ? nil : start.zone.identifier,
                               location: place(event["location"]),
                               sourceText: string(event["description"]).map { String($0.prefix(maxSourceTextLength)) } ?? name,
                               confidence: .high, titleIsGuess: name.isEmpty, reservationNumber: booking.number,
                               url: string(event["url"]) ?? booking.url)
    }

    // MARK: Values

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber: return n.stringValue
        case let o as [String: Any]: return string(o["name"]) ?? string(o["@id"])
        case let a as [Any]: return a.lazy.compactMap(string).first
        default: return nil
        }
    }

    static func object(_ value: Any?) -> [String: Any]? {
        if let o = value as? [String: Any] { return o }
        return (value as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first
    }

    static func airport(_ value: Any?) -> (code: String?, name: String?) {
        guard let o = object(value) else { return (string(value), nil) }
        return (string(o["iataCode"]), string(o["name"]))
    }

    static func address(_ value: Any?) -> String? {
        if let s = value as? String { return string(s) }
        guard let o = object(value) else { return nil }
        let locality = [string(o["postalCode"]), string(o["addressLocality"])].compactMap { $0 }.joined(separator: " ")
        let parts = [string(o["streetAddress"]), locality.isEmpty ? nil : locality, string(o["addressCountry"])].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func place(_ value: Any?) -> String? {
        if let s = value as? String { return string(s) }
        guard let o = object(value) else { return nil }
        if types(o).contains("VirtualLocation") { return string(o["url"]) }
        let name = string(o["name"])
        let addr = address(o["address"])
        let parts = [name, addr].compactMap { $0 }
        return parts.isEmpty ? string(o["url"]) : parts.joined(separator: ", ")
    }

    struct Time { var date: Date; var isAllDay: Bool; var zone: TimeZone }

    static let isoPattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#)

    /// ISO 8601 as schema.org uses it: with an offset (absolute), without (the sender's wall
    /// clock) or a bare date (all day).
    static func time(_ value: Any?, zone: TimeZone) -> Time? {
        guard let raw = string(value) else { return nil }
        let ns = raw as NSString
        guard let m = isoPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int) -> Int? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
        guard let y = int(1), let mo = int(2), let d = int(3) else { return nil }
        guard let h = int(4), let mi = int(5) else {
            return TimeZoneResolver.utc.date(from: DateComponents(year: y, month: mo, day: d)).map { Time(date: $0, isAllDay: true, zone: zone) }
        }
        let components = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: int(6) ?? 0)
        var cal = Calendar(identifier: .gregorian)
        let offsetRange = m.range(at: 7)
        if offsetRange.location != NSNotFound {
            let raw = ns.substring(with: offsetRange)
            guard let seconds = raw == "Z" ? 0 : TimeZoneResolver.parseOffset(raw.replacingOccurrences(of: ":", with: "")),
                  let fixed = TimeZone(secondsFromGMT: seconds) else { return nil }
            cal.timeZone = fixed
            guard let date = cal.date(from: components) else { return nil }
            // Keep the sender's named zone when it agrees on that date (so the calendar shows
            // it in Europe/Copenhagen, not "GMT+1"); otherwise the stated offset.
            return Time(date: date, isAllDay: false, zone: zone.secondsFromGMT(for: date) == seconds ? zone : fixed)
        }
        cal.timeZone = zone
        return cal.date(from: components).map { Time(date: $0, isAllDay: false, zone: zone) }
    }
}
