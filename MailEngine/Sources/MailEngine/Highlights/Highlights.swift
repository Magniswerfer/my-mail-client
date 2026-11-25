import Foundation
import GRDB

/// The useful bit of a transactional mail (SPEC §5 Highlights): a login code, a parcel, a flight,
/// a receipt, a reservation or a bill, each with an action in the app.
public struct Highlight: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable { case code, package, flight, receipt, reservation, bill }

    public var kind: Kind
    /// "Login code", "PostNord parcel", "SK 1234 CPH → OSL", "Zalando order", "Noma", "Electricity bill"
    public var title: String
    /// The thing to copy or show: the code, tracking number, amount, booking reference.
    public var value: String?
    public var detail: String?
    /// Track, manage booking, pay…
    public var url: String?
    public var date: Date?
    public var endDate: Date?
    public var location: String?

    public init(kind: Kind, title: String, value: String? = nil, detail: String? = nil, url: String? = nil,
                date: Date? = nil, endDate: Date? = nil, location: String? = nil) {
        self.kind = kind; self.title = title; self.value = value; self.detail = detail
        self.url = url; self.date = date; self.endDate = endDate; self.location = location
    }
}

public enum HighlightExtractor {
    /// schema.org JSON-LD first (airlines, shops and carriers embed it), then text patterns.
    public static func extract(_ message: ParsedMessage) -> [Highlight] {
        var found = message.html.map(jsonLD) ?? []
        let text = MailStore.ownText(message.plainText)
        let subject = message.subject
        if !found.contains(where: { $0.kind == .code }), let code = loginCode(subject: subject, text: text) {
            found.append(Highlight(kind: .code, title: message.from.first?.name ?? message.from.first?.address ?? "", value: code))
        }
        if !found.contains(where: { $0.kind == .package }), let parcel = parcel(subject: subject, text: text) {
            found.append(parcel)
        }
        if !found.contains(where: { $0.kind == .bill || $0.kind == .receipt }),
           let money = moneyHighlight(subject: subject, text: text, sender: message.from.first) {
            found.append(money)
        }
        return found
    }

    // MARK: JSON-LD

    static func jsonLD(_ html: String) -> [Highlight] {
        var results: [Highlight] = []
        for match in html.matches(of: /(?is)<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>(.*?)<\/script>/) {
            let json = HTMLText.decodeEntities(String(match.output.1))
            guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            for item in flatten(object) { if let h = highlight(item) { results.append(h) } }
        }
        return results
    }

    static func flatten(_ object: Any) -> [[String: Any]] {
        if let array = object as? [Any] { return array.flatMap(flatten) }
        guard let dict = object as? [String: Any] else { return [] }
        if let graph = dict["@graph"] { return flatten(graph) }
        return [dict]
    }

    static func types(_ d: [String: Any]) -> [String] {
        if let t = d["@type"] as? String { return [t] }
        return (d["@type"] as? [String]) ?? []
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any] { return string(d["name"]) ?? string(d["iataCode"]) ?? string(d["@id"]) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = string(v) else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
                                                      [.withFullDate]] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        // "2026-12-01T14:00:00" without a zone: local time.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    static func highlight(_ d: [String: Any]) -> Highlight? {
        let t = types(d)
        let target = d["reservationFor"] as? [String: Any]
        if t.contains("FlightReservation"), let flight = target {
            let airline = string((flight["airline"] as? [String: Any])?["iataCode"]) ?? string(flight["airline"]) ?? ""
            let number = string(flight["flightNumber"]) ?? ""
            let from = string((flight["departureAirport"] as? [String: Any])?["iataCode"]) ?? string(flight["departureAirport"]) ?? ""
            let to = string((flight["arrivalAirport"] as? [String: Any])?["iataCode"]) ?? string(flight["arrivalAirport"]) ?? ""
            let flightName = [airline, number].filter { !$0.isEmpty }.joined(separator: " ")
            return Highlight(kind: .flight, title: "\(flightName) \(from) → \(to)".trimmingCharacters(in: .whitespaces),
                             value: string(d["reservationNumber"]), url: string(d["checkinUrl"]) ?? string(d["url"]),
                             date: date(flight["departureTime"]), endDate: date(flight["arrivalTime"]), location: from)
        }
        if t.contains("ParcelDelivery") {
            let carrier = string(d["carrier"]) ?? string(d["provider"]) ?? ""
            return Highlight(kind: .package, title: carrier, value: string(d["trackingNumber"]),
                             url: string(d["trackingUrl"]), date: date(d["expectedArrivalUntil"]))
        }
        if t.contains("Order") {
            let price = (d["acceptedOffer"] as? [String: Any]).flatMap { string($0["price"]) } ?? string(d["price"])
            let currency = (d["acceptedOffer"] as? [String: Any]).flatMap { string($0["priceCurrency"]) } ?? string(d["priceCurrency"]) ?? ""
            return Highlight(kind: .receipt, title: string(d["merchant"]) ?? string(d["seller"]) ?? "",
                             value: price.map { "\($0) \(currency)".trimmingCharacters(in: .whitespaces) },
                             detail: string(d["orderNumber"]), url: string(d["url"]))
        }
        if t.contains("Invoice") {
            let due = d["totalPaymentDue"] as? [String: Any]
            let amount = due.flatMap { [string($0["price"]), string($0["priceCurrency"])].compactMap { $0 }.joined(separator: " ") }
            return Highlight(kind: .bill, title: string(d["provider"]) ?? string(d["broker"]) ?? "", value: amount,
                             url: string(d["url"]), date: date(d["paymentDueDate"]))
        }
        if t.contains(where: { $0.hasSuffix("Reservation") }), let place = target {
            let start = date(d["checkinTime"]) ?? date(d["startTime"]) ?? date(place["startDate"])
            let end = date(d["checkoutTime"]) ?? date(d["endTime"])
            let address = (place["address"] as? [String: Any]).map {
                [string($0["streetAddress"]), string($0["addressLocality"])].compactMap { $0 }.joined(separator: ", ")
            } ?? string(place["address"])
            return Highlight(kind: .reservation, title: string(place["name"]) ?? "", value: string(d["reservationNumber"]),
                             detail: string(d["partySize"]).map { "\($0)" }, url: string(d["modifyReservationUrl"]) ?? string(d["url"]),
                             date: start, endDate: end, location: address)
        }
        return nil
    }

    // MARK: Text patterns

    static let codeWords = ["code", "kode", "verification", "verify", "bekræft", "engangskode", "one-time", "one time",
                            "otp", "2fa", "two-factor", "login", "log ind", "sign in", "sikkerhedskode", "pin"]

    /// 4–8 digits (or a 6-character code like "A1B2C3") next to a code word.
    public static func loginCode(subject: String, text: String) -> String? {
        let head = subject + "\n" + text.prefix(600)
        let lower = head.lowercased()
        guard codeWords.contains(where: lower.contains) else { return nil }
        // Prefer a code on its own line or right after "code:"/"kode:".
        if let m = head.firstMatch(of: /(?i)(?:code|kode|otp)[^\n\d]{0,20}?([0-9]{4,8}|[A-Z0-9]{6})\b/) {
            let code = String(m.output.1)
            if code.contains(where: \.isNumber) { return code }
        }
        for line in head.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            if (4...8).contains(t.count), t.allSatisfy(\.isNumber) { return t }
        }
        if let m = head.firstMatch(of: /\b(\d{3}[ -]\d{3}|\d{6})\b/) { return String(m.output.1).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") }
        return nil
    }

    struct Carrier { var name: String; var words: [String]; var pattern: Regex<Substring>; var url: String }

    nonisolated(unsafe) static let carriers: [Carrier] = [
        Carrier(name: "UPS", words: ["ups"], pattern: /\b1Z[0-9A-Z]{16}\b/, url: "https://www.ups.com/track?tracknum="),
        Carrier(name: "PostNord", words: ["postnord", "post nord"], pattern: /\b[A-Z]{2}\d{9}[A-Z]{2}\b|\b00\d{16}\b/,
                url: "https://tracking.postnord.com/da/?id="),
        Carrier(name: "GLS", words: ["gls"], pattern: /\b\d{11,12}\b/, url: "https://gls-group.com/DK/da/find-pakke?match="),
        Carrier(name: "DAO", words: ["dao"], pattern: /\b\d{14,15}\b/, url: "https://www.dao.as/privat/find-min-pakke?stregkode="),
        Carrier(name: "Bring", words: ["bring"], pattern: /\b\d{17,18}\b|\b[A-Z]{2}\d{9}[A-Z]{2}\b/,
                url: "https://tracking.bring.dk/tracking/"),
        Carrier(name: "DHL", words: ["dhl"], pattern: /\b\d{10}\b|\bJJD\d{18}\b/, url: "https://www.dhl.com/dk-da/home/tracking.html?tracking-id="),
        Carrier(name: "FedEx", words: ["fedex"], pattern: /\b\d{12}\b/, url: "https://www.fedex.com/fedextrack/?trknbr="),
    ]

    static let parcelWords = ["track", "tracking", "pakke", "parcel", "package", "shipped", "afsendt", "levering", "delivery",
                              "forsendelse", "sporing", "shipment"]

    static func parcel(subject: String, text: String) -> Highlight? {
        let body = subject + "\n" + text
        let lower = body.lowercased()
        guard parcelWords.contains(where: lower.contains) else { return nil }
        for carrier in carriers where carrier.words.contains(where: lower.contains) {
            if let m = body.firstMatch(of: carrier.pattern) {
                let number = String(m.output)
                return Highlight(kind: .package, title: carrier.name, value: number, url: carrier.url + number)
            }
        }
        // UPU (S10) and UPS numbers are distinctive enough without the carrier's name.
        if let m = body.firstMatch(of: /\b1Z[0-9A-Z]{16}\b/) {
            return Highlight(kind: .package, title: "UPS", value: String(m.output), url: "https://www.ups.com/track?tracknum=\(m.output)")
        }
        if let m = body.firstMatch(of: /\b[A-Z]{2}\d{9}[A-Z]{2}\b/) {
            return Highlight(kind: .package, title: "", value: String(m.output))
        }
        return nil
    }

    static let receiptWords = ["receipt", "kvittering", "order", "ordre", "bestilling", "invoice", "faktura", "payment", "betaling"]
    static let billWords = ["due", "forfald", "betales senest", "betalingsfrist", "pay by", "amount due", "skyldigt beløb"]

    /// "Total 1.234,50 kr." → a receipt, or a bill when a due date is mentioned.
    static func moneyHighlight(subject: String, text: String, sender: MailAddress?) -> Highlight? {
        let body = subject + "\n" + text
        let lower = body.lowercased()
        let isBill = billWords.contains(where: lower.contains)
        guard isBill || receiptWords.contains(where: lower.contains) else { return nil }
        guard let amount = totalAmount(in: body) else { return nil }
        return Highlight(kind: isBill ? .bill : .receipt, title: sender?.name ?? sender?.address ?? "", value: amount)
    }

    /// The amount on a "total"/"i alt" line, else the largest amount mentioned.
    static func totalAmount(in text: String) -> String? {
        let money = /(?i)(?:(kr\.?|dkk|eur|€|usd|\$|sek|nok|£)\s?(\d[\d.,]*\d|\d))|(?:(\d[\d.,]*\d|\d)\s?(kr\.?|dkk|eur|€|usd|\$|sek|nok|£))/
        func amounts(_ s: Substring) -> [(String, Double)] {
            s.matches(of: money).compactMap { m in
                let number = String(m.output.2 ?? m.output.3 ?? "")
                let currency = String(m.output.1 ?? m.output.4 ?? "").uppercased().replacingOccurrences(of: ".", with: "")
                guard let value = parse(number) else { return nil }
                let shown = ["KR": "kr.", "€": "€", "$": "$", "£": "£"][currency] ?? currency
                return (shown == "€" || shown == "$" || shown == "£" ? "\(shown)\(number)" : "\(number) \(shown)", value)
            }
        }
        for line in text.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("total") || l.contains("i alt") || l.contains("at betale") || l.contains("amount due") || l.contains("beløb"),
               let first = amounts(line).first {
                return first.0
            }
        }
        return amounts(Substring(text)).max { $0.1 < $1.1 }?.0
    }

    /// "1.234,50" (Danish) or "1,234.50" (English) → 1234.5
    static func parse(_ s: String) -> Double? {
        var t = s
        if let comma = t.lastIndex(of: ","), let dot = t.lastIndex(of: ".") {
            if comma > dot { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { t = t.replacingOccurrences(of: ",", with: "") }
        } else if let comma = t.lastIndex(of: ",") {
            t = t.distance(from: comma, to: t.endIndex) == 3 ? t.replacingOccurrences(of: ",", with: ".") : t.replacingOccurrences(of: ",", with: "")
        } else if let dot = t.lastIndex(of: "."), t.distance(from: dot, to: t.endIndex) == 4 {
            t = t.replacingOccurrences(of: ".", with: "")
        }
        return Double(t)
    }
}

// MARK: - Storage

extension MailStore {
    static func registerHighlightMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v17-highlights") { db in
            try db.alter(table: "message") { t in
                t.add(column: "highlights", .text)
            }
        }
    }

    /// The newest login code from the last `minutes` (for "Copy Latest Code").
    public func latestLoginCode(within minutes: Double = 20, now: Date = Date()) throws -> (code: String, message: StoredMessage)? {
        let since = now.addingTimeInterval(-minutes * 60)
        let candidates = try db.read { db in
            try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE highlights LIKE '%"code"%' AND date >= ? ORDER BY date DESC LIMIT 5
                """, arguments: [since])
        }
        for m in candidates {
            if let code = m.highlights?.first(where: { $0.kind == .code })?.value { return (code, m) }
        }
        return nil
    }
}
