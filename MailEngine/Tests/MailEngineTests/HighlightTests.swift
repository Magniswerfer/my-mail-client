import Foundation
import Testing
@testable import MailEngine

@Suite struct HighlightTests {
    func mail(_ subject: String, _ body: String, html: String? = nil, from: String = "Shop <shop@x.dk>") -> ParsedMessage {
        var raw = "From: \(from)\nSubject: \(subject)\n"
        if let html {
            raw += "Content-Type: multipart/alternative; boundary=b\n\n--b\nContent-Type: text/plain; charset=utf-8\n\n\(body)\n--b\nContent-Type: text/html; charset=utf-8\n\n\(html)\n--b--\n"
        } else {
            raw += "Content-Type: text/plain; charset=utf-8\n\n\(body)"
        }
        return MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    @Test func loginCodes() {
        #expect(HighlightExtractor.loginCode(subject: "Din engangskode", text: "Din kode er 482913. Den udløber om 10 minutter.") == "482913")
        #expect(HighlightExtractor.loginCode(subject: "Verify your sign-in", text: "Use this code:\n\n  731 044\n\nIf this wasn't you…") == "731044")
        #expect(HighlightExtractor.loginCode(subject: "Your order 123456 has shipped", text: "Track it here.") == nil,
                "a number without code words isn't a code")
    }

    @Test func parcels() {
        let ups = HighlightExtractor.extract(mail("Your package has shipped", "UPS tracking number: 1Z999AA10123456784"))
        #expect(ups.first { $0.kind == .package }?.title == "UPS")
        #expect(ups.first { $0.kind == .package }?.url == "https://www.ups.com/track?tracknum=1Z999AA10123456784")
        let postnord = HighlightExtractor.extract(mail("Din pakke er på vej", "PostNord forsendelse RR123456789DK afsendt i dag."))
        #expect(postnord.first?.value == "RR123456789DK")
        #expect(postnord.first?.title == "PostNord")
    }

    @Test func receiptsAndBills() {
        let receipt = HighlightExtractor.extract(mail("Kvittering for din ordre", "Varer 899,00 kr.\nFragt 49,00 kr.\nI alt: 948,00 kr."))
        #expect(receipt.first { $0.kind == .receipt }?.value == "948,00 kr.")
        let bill = HighlightExtractor.extract(mail("Din elregning", "Beløb: DKK 1.234,50\nBetales senest 1. december", from: "Ørsted <info@orsted.dk>"))
        #expect(bill.first?.kind == .bill)
        #expect(bill.first?.title == "Ørsted")
        #expect(HighlightExtractor.parse("1.234,50") == 1234.5)
        #expect(HighlightExtractor.parse("1,234.50") == 1234.5)
    }

    @Test func jsonLDFlightWins() {
        let html = """
            <html><head><script type="application/ld+json">
            {"@context":"http://schema.org","@type":"FlightReservation","reservationNumber":"ABC123",
             "reservationFor":{"@type":"Flight","flightNumber":"1234","airline":{"@type":"Airline","iataCode":"SK"},
              "departureAirport":{"@type":"Airport","iataCode":"CPH"},"arrivalAirport":{"@type":"Airport","iataCode":"OSL"},
              "departureTime":"2026-12-03T08:15:00+01:00","arrivalTime":"2026-12-03T09:25:00+01:00"}}
            </script></head><body>Your booking</body></html>
            """
        let flight = HighlightExtractor.extract(mail("Booking confirmation", "Your booking", html: html, from: "SAS <no-reply@flysas.com>"))
        let h = flight.first { $0.kind == .flight }
        #expect(h?.title == "SK 1234 CPH → OSL")
        #expect(h?.value == "ABC123")
        #expect(h?.date == ISO8601DateFormatter().date(from: "2026-12-03T07:15:00Z"))
    }

    @Test func storedAndLatestCode() throws {
        let s = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID()).sqlite").path)
        var m = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, threadID: "t", subject: "Kode", fromAddress: "x@y.dk", date: Date())
        m.highlights = [Highlight(kind: .code, title: "Bank", value: "123456")]
        try s.upsert([(m, "x")])
        #expect(try s.latestLoginCode()?.code == "123456")
        #expect(try s.latestLoginCode(now: Date().addingTimeInterval(3_600)) == nil, "old codes don't count")
    }
}
