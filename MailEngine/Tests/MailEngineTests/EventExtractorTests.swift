import Foundation
import Testing
@testable import MailEngine

private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!

/// Wednesday 25 November 2026, 10:00 in Copenhagen, unless a test says otherwise.
private func sent(_ y: Int = 2026, _ m: Int = 11, _ d: Int = 25, _ h: Int = 10, zone: TimeZone = copenhagen) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0, zone: TimeZone = copenhagen) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
}

private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    at(y, m, d, 0, zone: TimeZone(identifier: "UTC")!)
}

private func extract(_ text: String, subject: String = "Hej", html: String? = nil, sent date: Date = sent(),
                     zone: TimeZone = copenhagen) -> [EventSuggestion] {
    EventExtractor.extract(EventExtractor.Input(subject: subject, text: text, html: html, sent: date, timeZone: zone))
}

@Suite struct EventTextTests {
    @Test func danishDinnerOnFriday() throws {
        let found = extract("Hej Magnus,\n\nVil I komme til middag hos os fredag kl. 19?\n\nKh Anna", subject: "Fredag")
        let s = try #require(found.first)
        #expect(found.count == 1)
        #expect(s.start == at(2026, 11, 27, 19))
        #expect(!s.isAllDay)
        #expect(s.title == "Middag hos os")
        #expect(s.confidence == .high)
        #expect(s.timeZoneID == "Europe/Copenhagen")
        #expect(s.sourceText.contains("middag hos os fredag kl. 19"))
    }

    @Test func tomorrowAndNextTuesdayAreAnchoredToTheSentDate() throws {
        // Sent on Monday 2 February 2026: "tomorrow" is the 3rd, whatever day the test runs.
        let monday = sent(2026, 2, 2, 9)
        let tomorrow = try #require(extract("Can we meet tomorrow at 15:00?", sent: monday).first)
        #expect(tomorrow.start == at(2026, 2, 3, 15))
        let iMorgen = try #require(extract("Vi ses i morgen kl. 10.30 til kaffe", sent: monday).first)
        #expect(iMorgen.start == at(2026, 2, 3, 10, 30))
        let tuesday = try #require(extract("Næste tirsdag kl 9 har vi møde med revisoren.", sent: monday).first)
        #expect(tuesday.start == at(2026, 2, 10, 9), "\"næste tirsdag\" on a Monday is next week's")
        let plainTuesday = try #require(extract("Tirsdag kl 9 har vi møde med revisoren.", sent: monday).first)
        #expect(plainTuesday.start == at(2026, 2, 3, 9))
        let nextFriday = try #require(extract("Næste fredag kl. 19 er der fest.", sent: monday).first)
        #expect(nextFriday.start == at(2026, 2, 6, 19), "further ahead than tomorrow: the coming one")
        let friday = try #require(extract("Join us on Friday at 7pm for drinks!", sent: monday).first)
        #expect(friday.start == at(2026, 2, 6, 19))
        // Sent on a Wednesday: "next Thursday" isn't tomorrow, "Thursday" is.
        let nextThursday = try #require(extract("Our webinar is next Thursday at 16:00 GMT.").first)
        #expect(nextThursday.start == at(2026, 12, 3, 17))
        #expect(try #require(extract("Webinar on Thursday at 16:00").first).start == at(2026, 11, 26, 16))
    }

    @Test func explicitDateWithRange() throws {
        let s = try #require(extract("Mødet er den 3. december kl. 14-15 i lokale 2.").first)
        #expect(s.start == at(2026, 12, 3, 14))
        #expect(s.end == at(2026, 12, 3, 15))
        #expect(s.title == "Mødet")
        let english = try #require(extract("Meeting from 2pm to 3:30pm on Dec 4 about the budget.").first)
        #expect(english.start == at(2026, 12, 4, 14))
        #expect(english.end == at(2026, 12, 4, 15, 30))
    }

    @Test func aNamedTimeZoneWinsOverTheSenders() throws {
        let london = TimeZone(identifier: "Europe/London")!
        let s = try #require(extract("Reminder: the webinar is on 3 December at 14:00 CET. Register below.",
                                     sent: sent(zone: london), zone: london).first)
        #expect(s.start == at(2026, 12, 3, 13, zone: TimeZone(identifier: "UTC")!))
        #expect(s.title == "Webinar")
        #expect(s.timeZone?.secondsFromGMT(for: s.start) == 3_600)
    }

    @Test func timesWithoutAZoneAreTheSenders() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let s = try #require(extract("Lunch on December 2 at 12:30?", sent: sent(zone: newYork), zone: newYork).first)
        #expect(s.start == at(2026, 12, 2, 12, 30, zone: newYork))
    }

    @Test func aDateAndASeparateTimeAreJoined() throws {
        let s = try #require(extract("Frokost onsdag 12:00-13:00 i kantinen").first)
        #expect(s.start == at(2026, 12, 2, 12), "the Wednesday after, since it was sent on a Wednesday")
        #expect(s.end == at(2026, 12, 2, 13))
    }

    @Test func aYearlessDateIsTheNextOne() throws {
        let december = sent(2026, 12, 20)
        let s = try #require(extract("The kick-off is on 7 January at 9:00.", sent: december).first)
        #expect(s.start == at(2027, 1, 7, 9))
    }

    @Test func aDateWithoutTimeNeedsAPlanWordAndIsAllDay() throws {
        let s = try #require(extract("Julefrokosten er lørdag den 12. december – sæt kryds i kalenderen!").first)
        #expect(s.isAllDay)
        #expect(s.start == utcDay(2026, 12, 12))
        #expect(s.confidence == .medium, "the model decides about bare dates")
        #expect(extract("Vi talte om det den 12. december.").isEmpty)
    }

    @Test func aTimeWithoutAPlanWordIsUncertain() throws {
        let s = try #require(extract("Kan du fredag kl. 16?").first)
        #expect(s.confidence == .medium)
        #expect(s.titleIsGuess)
    }

    @Test func subjectCanCarryTheDate() throws {
        let s = try #require(extract("Glæder mig!", subject: "Re: Middag fredag kl. 18.30").first)
        #expect(s.start == at(2026, 11, 27, 18, 30))
        #expect(s.title == "Middag", "\(s.title)")
    }

    @Test func titlesAndTimesFromEverydayMail() throws {
        func one(_ text: String) throws -> EventSuggestion { try #require(extract(text).first, "\(text)") }
        #expect(try one("Husk at vi skal til tandlæge i morgen kl. 10").title == "Tandlæge")
        #expect(try one("Join us for our annual Christmas party on 12 December at 18:00").title == "Annual Christmas party")
        #expect(try one("Hi Magnus, are you free for a call on Thursday at 3pm?").start == at(2026, 11, 26, 15))
        let booking = try one("Din tid hos Frisør Lotte er bekræftet: tirsdag d. 1/12 kl. 14.30")
        #expect(booking.title == "Tid hos Frisør Lotte")
        #expect(booking.start == at(2026, 12, 1, 14, 30))
        let openHouse = try one("Hej! Vi holder åbent hus lørdag fra 10-14")
        #expect(openHouse.title == "Åbent hus")
        #expect(openHouse.end == at(2026, 11, 28, 14))
        #expect(try one("Webinar: Introduction to SwiftUI — 3 December 2026, 14:00–15:00 CET").title == "Webinar: Introduction to SwiftUI")
        #expect(try one("Kan vi flytte mødet til torsdag d. 3. dec. kl. 9.00-10.30?").title == "Mødet")
        #expect(try one("Tak for i går! Skal vi ses igen næste fredag kl 17?").titleIsGuess, "a question: the model may retitle it")
        let compound = try one("Save the date: Sommerfest 20. juni 2027")
        #expect(compound.title == "Sommerfest")
        #expect(compound.isAllDay && compound.start == utcDay(2027, 6, 20))
        #expect(try one("Vil du med til frokost i morgen kl. 12?").start == at(2026, 11, 26, 12), "noon, not midnight")
    }

    @Test func notPlans() {
        #expect(extract("Your order #48213 was placed on 12/11/2026 and will ship soon.").isEmpty)
        #expect(extract("Ordrenummer: 2026-1125-0042. Tak for din bestilling.").isEmpty)
        #expect(extract("Document updated 3 days ago by Anna.").isEmpty)
        #expect(extract("Fakturadato: 20.11.2026. Betales senest 4.12.2026.").isEmpty)
        #expect(extract("Din pakke er afsendt og leveres fredag mellem kl. 8 og 16.").isEmpty)
        #expect(extract("Black Friday-udsalg: slutter søndag kl. 23:59!").isEmpty)
        #expect(extract("Your subscription renews on 1 December 2026.").isEmpty)
        #expect(extract("Best,\nAnna\nKundeservice · Åbningstid: man–fre kl. 9–17 · Tlf. 70 20 30 40").isEmpty)
        #expect(extract("The meeting on 3 March 2025 at 10:00 went well, thanks.").isEmpty, "in the past")
        #expect(extract("Thanks for dinner yesterday at 7pm!").isEmpty, "in the past")
        #expect(extract("Meeting notes from last Monday's meeting at 10:00").isEmpty)
        #expect(extract("Vi sås sidste fredag kl. 19 til middag").isEmpty)
        #expect(extract("Opdateret 24. nov. 2026 kl. 10:00").isEmpty)
        #expect(extract("Nyhedsbrev uge 48, 25. november 2026").isEmpty)
        #expect(extract("Your trial ends on December 9.").isEmpty)
        #expect(extract("Sent: Monday, 30 November 2026 10:00\nTo: Bo").isEmpty)
    }

    @Test func quotedHistoryIsIgnored() {
        let reply = """
            Sounds good, see you then!

            On Mon, 23 Nov 2026 at 09:12, Anna <anna@example.dk> wrote:
            > Dinner on Friday at 7pm?
            > Best, Anna
            """
        #expect(extract(reply).isEmpty)
        let danish = "Super!\n\nDen 24. nov. 2026 kl. 08.00 skrev Bo:\n> Møde torsdag kl. 10?"
        #expect(extract(danish).isEmpty)
        let forwarded = "FYI\n\n---------- Forwarded message ---------\nFrom: x\nMeeting Friday at 10:00"
        #expect(extract(forwarded).isEmpty)
    }

    @Test func atMostThreeBestFirst() {
        let text = """
            Program:
            Fredag kl. 18 middag i teltet.
            Lørdag kl. 10 kaffe og rundvisning.
            Lørdag kl. 19 fest med band.
            Søndag kl. 11 brunch.
            Og så har vi måske tid onsdag kl. 15.
            """
        let found = extract(text)
        #expect(found.count == EventExtractor.maxSuggestions)
        #expect(found.allSatisfy { $0.confidence == .high })
        #expect(found.first?.start == at(2026, 11, 27, 18))
    }

    @Test func locationFromALabel() throws {
        let s = try #require(extract("Workshop torsdag den 10. december kl. 13-16.\nSted: Kulturhuset, Store sal").first)
        #expect(s.location == "Kulturhuset, Store sal")
        #expect(s.end == at(2026, 12, 10, 16))
    }

    @Test func senderZoneFromTheDateHeader() {
        let local = copenhagen
        let date = sent()
        #expect(EventExtractor.senderZone(dateHeader: "Wed, 25 Nov 2026 10:00:00 +0100", sent: date, local: local) == local)
        #expect(EventExtractor.senderZone(dateHeader: "Wed, 25 Nov 2026 04:00:00 -0500 (EST)", sent: date, local: local).secondsFromGMT(for: date) == -18_000)
        #expect(EventExtractor.senderZone(dateHeader: "Wed, 25 Nov 2026 09:00:00 GMT", sent: date, local: local) == local, "no numeric offset")
        #expect(EventExtractor.senderZone(dateHeader: nil, sent: date, local: local) == local)
    }
}

@Suite struct EventSchemaOrgTests {
    private func html(_ json: String) -> String {
        "<html><head><script type=\"application/ld+json\">\(json)</script></head><body><p>Tak for din reservation fredag kl. 12</p></body></html>"
    }

    @Test func restaurantReservation() throws {
        let json = """
            {"@context": "http://schema.org", "@type": "FoodEstablishmentReservation", "reservationNumber": "ABC123",
             "reservationStatus": "http://schema.org/ReservationConfirmed", "partySize": 4,
             "startTime": "2026-12-04T19:30:00+01:00",
             "reservationFor": {"@type": "FoodEstablishment", "name": "Restaurant Noma",
                "address": {"@type": "PostalAddress", "streetAddress": "Refshalevej 96", "postalCode": "1432", "addressLocality": "København K"}}}
            """
        let s = try #require(extract("", html: html(json)).first)
        #expect(s.kind == .restaurant)
        #expect(s.source == .schemaOrg)
        #expect(s.title == "Restaurant Noma")
        #expect(s.start == at(2026, 12, 4, 19, 30))
        #expect(s.end == at(2026, 12, 4, 21, 30), "two hours when the booking has no end")
        #expect(s.location == "Restaurant Noma, Refshalevej 96, 1432 København K")
        #expect(s.reservationNumber == "ABC123")
        #expect(s.timeZoneID == "Europe/Copenhagen", "the offset agrees with the sender's zone")
        #expect(extract("", html: html(json)).count == 1, "the markup wins over the sentence")
    }

    @Test func flightReservation() throws {
        let json = """
            [{"@context": "https://schema.org", "@type": "FlightReservation", "reservationNumber": "XYZ9",
              "reservationFor": {"@type": "Flight", "flightNumber": "1501", "airline": {"@type": "Airline", "iataCode": "SK", "name": "SAS"},
                "departureAirport": {"@type": "Airport", "iataCode": "CPH", "name": "Copenhagen Airport"},
                "arrivalAirport": {"@type": "Airport", "iataCode": "LHR"},
                "departureTime": "2026-12-18T07:05:00+01:00", "arrivalTime": "2026-12-18T08:00:00+00:00"}}]
            """
        let s = try #require(extract("", html: html(json)).first)
        #expect(s.kind == .flight)
        #expect(s.title == "SK1501 CPH → LHR")
        #expect(s.start == at(2026, 12, 18, 7, 5))
        #expect(s.end == at(2026, 12, 18, 9, 0))
        #expect(s.location == "Copenhagen Airport")
    }

    @Test func lodgingWithDatesOnlyIsAllDay() throws {
        let json = """
            {"@context": "http://schema.org", "@graph": [{"@type": "LodgingReservation",
              "checkinDate": "2027-01-08", "checkoutDate": "2027-01-10",
              "reservationFor": {"@type": "LodgingBusiness", "name": "Hotel Skt. Petri", "address": "Krystalgade 22, København"}}]}
            """
        let s = try #require(extract("", html: html(json)).first)
        #expect(s.kind == .lodging)
        #expect(s.isAllDay)
        #expect(s.start == utcDay(2027, 1, 8))
        #expect(s.end == utcDay(2027, 1, 10))
        #expect(s.location == "Krystalgade 22, København")
    }

    @Test func eventsTicketsAndCancellations() throws {
        let ticket = """
            {"@context": "http://schema.org", "@type": "EventReservation", "reservationNumber": "T-77",
             "reservationFor": {"@type": "MusicEvent", "name": "Mew i Royal Arena", "startDate": "2026-12-12T20:00:00",
               "location": {"@type": "Place", "name": "Royal Arena", "address": "Hannemanns Allé 18, København S"}}}
            """
        let s = try #require(extract("", html: html(ticket)).first)
        #expect(s.title == "Mew i Royal Arena")
        #expect(s.start == at(2026, 12, 12, 20), "no offset: the sender's wall clock")
        #expect(s.location == "Royal Arena, Hannemanns Allé 18, København S")

        let cancelled = """
            {"@context": "http://schema.org", "@type": "Event", "name": "Julemarked", "startDate": "2026-12-05",
             "eventStatus": "https://schema.org/EventCancelled"}
            """
        #expect(extract("", html: html(cancelled)).allSatisfy { $0.source == .text }, "a cancelled event isn't suggested")

        let allDay = """
            {"@context": "http://schema.org", "@type": "Festival", "name": "Not an event type", "startDate": "2026-12-05"}
            """
        #expect(extract("", html: html(allDay)).allSatisfy { $0.source == .text })

        let event = """
            {"@context": "http://schema.org", "@type": "Event", "name": "Julemarked", "startDate": "2026-12-05", "endDate": "2026-12-06"}
            """
        let market = try #require(extract("", html: html(event)).first)
        #expect(market.isAllDay)
        #expect(market.end == utcDay(2026, 12, 7), "schema.org end dates are inclusive")
    }

    @Test func calendarInviteForTheBridge() throws {
        let s = try #require(extract("Middag hos os fredag kl. 19").first)
        let invite = s.calendarInvite(uid: "u1", notes: "n")
        #expect(invite.method == .publish)
        #expect(invite.summary == s.title)
        #expect(invite.start == s.start)
        #expect(invite.timeZoneID == "Europe/Copenhagen")
        #expect(invite.attendees.isEmpty && invite.organizer == nil, "nobody to answer")
    }
}

// MARK: - Store round trip and the background scan

private struct FakeJudge: EventJudge {
    var verdict: @Sendable (EventSuggestion) -> EventReview?
    func review(_ candidate: EventSuggestion, subject: String, sender: String, context: String) async -> EventReview? {
        verdict(candidate)
    }
}

@Suite struct EventScanStoreTests {
    private func store() throws -> MailStore {
        try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("tidings-events-\(UUID()).sqlite").path)
    }

    private func message(_ uid: UInt32, _ text: String, mailbox: String = "INBOX", from: String = "anna@example.dk",
                         category: MailCategory = .primary, daysAgo: Double = 0) -> StoredMessage {
        var m = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: "t\(uid)",
                              subject: "Hej", fromName: "Anna", fromAddress: from, recipients: "me@example.dk",
                              date: Date().addingTimeInterval(-daysAgo * 86_400), category: category)
        m.bodyText = TextCompression.compress(text)
        return m
    }

    @Test func scanStoreDismissAndMove() async throws {
        let s = try store()
        var invite = message(3, "Meeting Friday at 10:00")
        invite.invite = CalendarInvite.parse("""
            BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:x1\nDTSTART:20991201T100000Z\nSUMMARY:Sync\nEND:VEVENT\nEND:VCALENDAR
            """)
        let messages = [
            message(1, "Vil I komme til middag hos os i morgen kl. 19?"),
            message(2, "Updated 3 days ago."),
            invite,
            message(4, "I'll bring cake to the party tomorrow at 15:00", mailbox: "Sent Messages", from: "me@example.dk"),
            message(5, "Dinner tomorrow at 19:00?", daysAgo: 90),
            message(6, "Ses i morgen kl. 19", from: "me@example.dk"),
        ]
        try s.upsert(messages.map { ($0, $0.plainText ?? "") })
        try s.save(MailboxState(accountID: "a", path: "Sent Messages", role: .sent, uidValidity: 1, uidNext: 10,
                                highestModSeq: nil, messageCount: 1, lastSync: Date()))

        let scanner = EventScanner(store: s, judge: nil, raw: { _ in nil })
        let report = try await scanner.run(ownAddresses: ["me@example.dk"])
        #expect(report.scanned == 3, "not the invite, Sent, or mail older than the window")
        #expect(report.found == 1)
        let again = try await scanner.run(ownAddresses: ["me@example.dk"])
        #expect(again.scanned == 0, "each message is scanned once")

        let dinner = try #require(try s.eventSuggestions(for: messages[0]))
        #expect(dinner.suggestions.count == 1)
        #expect(dinner.visible().first?.title == "Middag hos os")
        #expect(try s.eventSuggestions(for: messages[1])?.suggestions.isEmpty == true)
        #expect(try s.eventSuggestions(for: messages[5])?.suggestions.isEmpty == true, "your own mail")
        #expect(try s.eventSuggestions(for: invite) == nil)

        // Dismiss is remembered, also when a re-scan is saved and when the message moves.
        try s.setEventSuggestionState(.dismissed, for: messages[0])
        try s.saveEventSuggestions(EventSuggestionRecord(accountID: "a", messageKey: messages[0].eventKey, suggestions: dinner.suggestions))
        var archived = messages[0]
        archived.id = nil
        archived.mailbox = "Archive"
        archived.uid = 99
        try s.delete(ids: [messages[0].id ?? 1])
        try s.upsert([(archived, archived.plainText ?? "")])
        let moved = try #require(try s.eventSuggestions(for: archived))
        #expect(moved.state == .dismissed)
        #expect(moved.visible().isEmpty)
        #expect(moved.suggestions == dinner.suggestions, "the suggestions round-trip through JSON")
        #expect(try s.messagesNeedingEventScan(since: .distantPast, limit: 10).allSatisfy { $0.uid != 99 })
    }

    @Test func theModelConfirmsAndTitlesUncertainOnes() async throws {
        let s = try store()
        let messages = [
            message(1, "Kan du i morgen kl. 16?", category: .updates),
            message(2, "Kan du i overmorgen kl. 17?", category: .updates),
            message(3, "Vil du med til frokost i morgen kl. 12?"),
        ]
        try s.upsert(messages.map { ($0, $0.plainText ?? "") })
        let judge = FakeJudge { candidate in
            candidate.sourceText.contains("16") ? EventReview(isEvent: true, title: "Kaffe med Anna", location: "Café Norden")
                : candidate.sourceText.contains("17") ? EventReview(isEvent: false, title: "")
                : EventReview(isEvent: true, title: "Frokost med Anna")
        }
        let scanner = EventScanner(store: s, judge: judge, raw: { _ in nil })
        let report = try await scanner.run(ownAddresses: [])
        #expect(report.reviewed == 2, "the two uncertain ones; the frokost had a good title already")

        let confirmed = try #require(try s.eventSuggestions(for: messages[0]))
        #expect(!confirmed.awaitingReview)
        #expect(confirmed.visible().first?.title == "Kaffe med Anna")
        #expect(confirmed.visible().first?.location == nil, "a place the email doesn't name is ignored")
        #expect(try s.eventSuggestions(for: messages[1])?.visible().isEmpty == true, "the model said no")
        #expect(try s.eventSuggestions(for: messages[2])?.visible().first?.title == "Frokost", "kept as is")
    }

    @Test func withoutAModelUncertainOnesNeedPersonalMail() async throws {
        let s = try store()
        let messages = [
            message(1, "Kan du i morgen kl. 16?", category: .primary),
            message(2, "Kan du i morgen kl. 16?", category: .updates),
        ]
        try s.upsert(messages.map { ($0, $0.plainText ?? "") })
        _ = try await EventScanner(store: s, judge: nil, raw: { _ in nil }).run(ownAddresses: [])
        #expect(try s.eventSuggestions(for: messages[0])?.visible().count == 1)
        #expect(try s.eventSuggestions(for: messages[1])?.visible().isEmpty == true)
    }

    @Test func scanNowUsesTheRawMessage() async throws {
        let s = try store()
        let raw = """
            From: Bo <bo@example.dk>\r
            To: me@example.dk\r
            Subject: Booking\r
            Date: Wed, 25 Nov 2026 10:00:00 -0500\r
            Message-ID: <r1@x>\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <html><head><script type="application/ld+json">{"@context":"http://schema.org","@type":"FoodEstablishmentReservation",
            "startTime":"2099-12-04T19:30:00","reservationFor":{"@type":"FoodEstablishment","name":"Le Bernardin"}}</script></head>
            <body>See you soon</body></html>\r
            """
        var m = message(1, "See you soon")
        m.messageID = "r1@x"
        try s.upsert([(m, "See you soon")])
        let scanner = EventScanner(store: s, judge: nil, raw: { _ in Data(raw.utf8) })
        let record = try await scanner.scanNow(m, ownAddresses: [])
        let booking = try #require(record.visible().first)
        #expect(booking.title == "Le Bernardin")
        #expect(booking.timeZone?.secondsFromGMT(for: booking.start) == -18_000, "the sender's zone from the Date header")
        #expect(try s.eventSuggestions(for: m)?.suggestions == record.suggestions)
    }
}
