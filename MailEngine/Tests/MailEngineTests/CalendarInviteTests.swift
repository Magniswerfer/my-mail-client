import Foundation
import Testing
@testable import MailEngine

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

private func mail(_ raw: String) -> ParsedMessage {
    MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
}

/// An Outlook/Exchange invitation: Windows TZID, VTIMEZONE, folded lines, escaped text, a room
/// and a Teams link, as the base64 `text/calendar` alternative Exchange sends.
private let outlookICS = #"""
BEGIN:VCALENDAR
METHOD:REQUEST
PRODID:Microsoft Exchange Server 2010
VERSION:2.0
BEGIN:VTIMEZONE
TZID:Romance Standard Time
BEGIN:STANDARD
DTSTART:16010101T030000
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:16010101T020000
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
ORGANIZER;CN=Anna Holm:mailto:anna@firma.dk
ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Magnus:mailto:Magnus@Example.dk
ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;CN="Holm, Lars":mailto:lars@firma.dk
ATTENDEE;CUTYPE=ROOM;CN=Mødelokale 2:mailto:room2@firma.dk
DESCRIPTION;LANGUAGE=da-DK:Dagsorden:\n1. Status\, plan\n\nJoin: https://teams.micros
 oft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x
UID:040000008200E00074C5B7101A82E008000000001
SUMMARY;LANGUAGE=da-DK:Projektmøde\; fase 2
DTSTART;TZID=Romance Standard Time:20261201T140000
DTEND;TZID=Romance Standard Time:20261201T150000
SEQUENCE:2
LOCATION;LANGUAGE=da-DK:Microsoft Teams Meeting
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
"""#

private let outlookMail = """
From: "Anna Holm" <anna@firma.dk>
To: Magnus <magnus@example.dk>
Subject: Projektmøde
Message-ID: <inv1@firma.dk>
Content-Type: multipart/alternative; boundary="b"

--b
Content-Type: text/plain; charset=utf-8

Hej, lad os mødes.
--b
Content-Type: text/html; charset=utf-8

<p>Hej, lad os mødes.</p>
--b
Content-Type: text/calendar; charset="utf-8"; method=REQUEST
Content-Transfer-Encoding: base64

\(Data(outlookICS.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
--b--
"""

private let googleCancel = """
From: Google Calendar <calendar-notification@google.com>
To: magnus@example.dk
Subject: Canceled event: Frokost @ Tue Dec 8, 2026 12pm - 1pm (CET)
List-Unsubscribe: <https://calendar.google.com/unsub>
Content-Type: multipart/mixed; boundary="m"

--m
Content-Type: text/plain

Cancelled.
--m
Content-Type: application/ics; name="invite.ics"
Content-Disposition: attachment; filename="invite.ics"

BEGIN:VCALENDAR
PRODID:-//Google Inc//Google Calendar 70.9054//EN
METHOD:CANCEL
BEGIN:VEVENT
DTSTART:20261208T110000Z
DTEND:20261208T120000Z
ORGANIZER;CN=bob@gmail.com:mailto:bob@gmail.com
UID:abc123@google.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:magnus@example.dk
X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
SEQUENCE:1
STATUS:CANCELLED
SUMMARY:Frokost
END:VEVENT
END:VCALENDAR
--m--
"""

@Suite struct CalendarInviteTests {
    @Test func outlookInviteIsRecognisedNotAnAttachment() throws {
        let m = mail(outlookMail)
        #expect(m.plainText.contains("lad os mødes"))
        #expect(m.attachments.isEmpty, "the calendar alternative isn't a file")
        let invite = try #require(m.invite)
        #expect(invite.method == .request)
        #expect(invite.summary == "Projektmøde; fase 2")
        #expect(invite.start == date("2026-12-01T13:00:00Z"), "Windows zone name → Europe/Paris, winter time")
        #expect(invite.end == date("2026-12-01T14:00:00Z"))
        #expect(invite.timeZoneID == "Europe/Paris")
        #expect(invite.sequence == 2)
        #expect(invite.organizer == CalendarInvite.Person(name: "Anna Holm", address: "anna@firma.dk", status: .needsAction,
                                                          isOptional: false, wantsReply: false, isResource: false))
        #expect(invite.attendees.count == 3)
        #expect(invite.attendees[1].name == "Holm, Lars" && invite.attendees[1].isOptional)
        #expect(invite.attendees[2].isResource)
        #expect(invite.guests.count == 2, "rooms aren't guests")
        #expect(invite.notes?.contains("1. Status, plan") == true)
        #expect(invite.conferenceURL == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x",
                "link found across a folded line")
        #expect(invite.needsResponse(from: ["magnus@example.dk"]), "attendee match is case-insensitive")
        #expect(!invite.needsResponse(from: ["someone@else.dk"]))
    }

    @Test func replyEchoesWhatOrganizersMatchOn() throws {
        let invite = try #require(mail(outlookMail).invite)
        let reply = try #require(invite.replyMessage(
            from: MailAddress(name: "Magnus", address: "magnus@example.dk"), status: .accepted,
            subject: "Accepted: Projektmøde", text: "Magnus accepted.", inReplyTo: "inv1@firma.dk",
            now: date("2026-11-24T10:00:00Z")))
        #expect(reply.to.map(\.address) == ["anna@firma.dk"])
        let ics = try #require(reply.calendar?.ics)
        #expect(ics.contains("METHOD:REPLY"))
        #expect(ics.contains("ATTENDEE;CN=Magnus;PARTSTAT=ACCEPTED:mailto:Magnus@Example.dk"), "address exactly as invited")
        #expect(ics.contains("UID:040000008200E00074C5B7101A82E008000000001"))
        #expect(ics.contains("SEQUENCE:2"))
        #expect(ics.contains("DTSTAMP:20261124T100000Z"))
        #expect(ics.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "folded at 75 octets")

        let raw = MIMEBuilder.build(reply)
        #expect(String(decoding: raw, as: UTF8.self).contains("Content-Type: text/calendar; charset=utf-8; method=REPLY"))
        let back = MIMEParser.parse(raw)
        #expect(back.plainText == "Magnus accepted.")
        #expect(back.invite?.method == .reply)
        #expect(back.invite?.uid == invite.uid)
        #expect(back.invite?.replyFrom?.status == .accepted)
    }

    @Test func googleCancellationFromAttachment() throws {
        let m = mail(googleCancel)
        #expect(m.attachments.count == 1, "a real .ics file stays an attachment")
        let invite = try #require(m.invite)
        #expect(invite.isCancelled && invite.method == .cancel)
        #expect(invite.organizer?.name == nil, "a CN that just repeats the address is dropped")
        #expect(invite.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(invite.start == date("2026-12-08T11:00:00Z"))
        #expect(!invite.needsResponse(from: ["magnus@example.dk"]))
    }

    @Test func timesAllDayDurationsAndZones() throws {
        func event(_ body: String) -> CalendarInvite? {
            CalendarInvite.parse("BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:x\n\(body)\nEND:VEVENT\nEND:VCALENDAR")
        }
        let allDay = try #require(event("DTSTART;VALUE=DATE:20261224"))
        #expect(allDay.isAllDay && allDay.start == date("2026-12-24T00:00:00Z") && allDay.end == date("2026-12-25T00:00:00Z"))
        let timed = try #require(event("DTSTART;TZID=Europe/Copenhagen:20260701T090000\nDURATION:PT1H30M"))
        #expect(timed.start == date("2026-07-01T07:00:00Z"))
        #expect(timed.end == date("2026-07-01T08:30:00Z"))
        #expect(event("SUMMARY:no start") == nil)
        #expect(TimeZoneResolver.zone(named: "/mozilla.org/20050126_1/Europe/Copenhagen")?.identifier == "Europe/Copenhagen")
        #expect(ICalDuration.seconds("P1W") == 604_800 && ICalDuration.seconds("-PT15M") == -900)

        // A zone only the calendar itself defines: daylight in July, standard in December.
        let custom = try #require(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            BEGIN:VTIMEZONE
            TZID:Custom Zone
            BEGIN:STANDARD
            DTSTART:16010101T030000
            TZOFFSETTO:+0100
            RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10
            END:STANDARD
            BEGIN:DAYLIGHT
            DTSTART:16010101T020000
            TZOFFSETTO:+0200
            RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3
            END:DAYLIGHT
            END:VTIMEZONE
            BEGIN:VEVENT
            UID:y
            DTSTART;TZID=Custom Zone:20260715T100000
            DTEND;TZID=Custom Zone:20261215T100000
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(custom.start == date("2026-07-15T08:00:00Z"))
        #expect(custom.end == date("2026-12-15T09:00:00Z"))
    }

    @Test func replyToOneOccurrenceKeepsRecurrenceID() throws {
        let invite = try #require(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:r1
            RECURRENCE-ID;TZID=Europe/Copenhagen:20261203T100000
            DTSTART;TZID=Europe/Copenhagen:20261203T110000
            ORGANIZER:mailto:o@x.dk
            ATTENDEE;RSVP=TRUE:mailto:magnus@example.dk
            SUMMARY:Standup (moved)
            END:VEVENT
            END:VCALENDAR
            """))
        let ics = invite.replyICS(as: MailAddress(name: nil, address: "magnus@example.dk"), status: .declined)
        #expect(ics.contains("RECURRENCE-ID;TZID=Europe/Copenhagen:20261203T100000"))
        #expect(ics.contains("PARTSTAT=DECLINED"))
    }

    @Test func invitesLandInPrimaryAndAnswersInUpdates() throws {
        let me: Set<String> = ["magnus@example.dk"]
        // "confirmation" in the subject and an automated sender would otherwise say Transactions/Updates.
        let invite = SignalClassifier.classify(mail(googleCancel), userAddresses: me)
        #expect(invite.category == .primary && invite.reason == .calendarInvite)

        let answer = try #require(mail(outlookMail).invite?.replyMessage(
            from: MailAddress(name: "Lars", address: "lars@firma.dk"), status: .tentative, subject: "Tentative: x", text: "."))
        let classified = SignalClassifier.classify(MIMEParser.parse(MIMEBuilder.build(answer)), userAddresses: me)
        #expect(classified.category == .updates && classified.reason == .calendarReply)
        #expect(ClassificationReason(encoded: ClassificationReason.calendarInvite.encoded) == .calendarInvite)
    }
}

@Suite struct InviteStoreTests {
    func store() throws -> MailStore {
        try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("tidings-inv-\(UUID()).sqlite").path)
    }

    @Test func updatesWithoutReferencesJoinTheInvitationsConversation() throws {
        let s = try store()
        let original = mail(outlookMail)
        let invite = try #require(original.invite)
        var first = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: original.messageID,
                                  threadID: try s.threadID(for: original, fallback: "f1", accountID: "a"),
                                  subject: original.subject, fromAddress: "anna@firma.dk", date: date("2026-11-20T09:00:00Z"))
        first.invite = invite
        first.inviteUID = invite.uid
        try s.upsert([(first, original.plainText)])

        // An update: new Message-ID, no References, same event UID.
        let update = mail(outlookMail.replacingOccurrences(of: "<inv1@firma.dk>", with: "<inv2@firma.dk>"))
        #expect(try s.threadID(for: update, fallback: "f2", accountID: "a") == first.threadID)
        #expect(try s.threadID(for: update, fallback: "f2", accountID: "other") == "inv2@firma.dk", "accounts stay apart")

        let stored = try #require(try s.messages(inThread: first.threadID!).first)
        #expect(stored.invite == invite, "the invite round-trips through the store")
    }

    @Test func newestAnswerWinsAndUpdatesAskAgain() throws {
        let s = try store()
        let invite = try #require(mail(outlookMail).invite)
        try s.recordInviteResponse(InviteResponse(accountID: "a", uid: invite.uid, sequence: 2, status: .accepted,
                                                  respondedAt: date("2026-11-21T09:00:00Z")))
        // A late-synced older answer from Sent doesn't overwrite the newer one.
        try s.recordInviteResponse(InviteResponse(accountID: "a", uid: invite.uid, sequence: 1, status: .declined,
                                                  respondedAt: date("2026-11-20T09:00:00Z")))
        #expect(try s.inviteResponse(accountID: "a", uid: invite.uid)?.status == .accepted)

        var message = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, threadID: "t", subject: "x",
                                    fromAddress: "anna@firma.dk", date: Date())
        message.invite = invite
        message.inviteUID = invite.uid
        try s.upsert([(message, "")])
        #expect(try s.unansweredInvites(accountID: "a", ownAddresses: ["magnus@example.dk"]).isEmpty, "answered at this sequence")

        var updated = invite
        updated.sequence = 3
        updated.start = Date().addingTimeInterval(86_400)
        updated.end = Date().addingTimeInterval(90_000)
        message.uid = 2
        message.date = Date().addingTimeInterval(60)
        message.invite = updated
        try s.upsert([(message, "")])
        #expect(try s.unansweredInvites(accountID: "a", ownAddresses: ["magnus@example.dk"]).count == 1, "a changed invite asks again")

        try s.forgetInviteResponse(accountID: "a", uid: invite.uid)
        #expect(try s.inviteResponse(accountID: "a", uid: invite.uid) == nil)
    }

    @Test func craftedTimeZoneRulesDoNotCrash() {
        let ics = """
            BEGIN:VCALENDAR
            BEGIN:VTIMEZONE
            TZID:Crafted
            BEGIN:STANDARD
            DTSTART:16010101T030000
            TZOFFSETTO:+0100
            RRULE:FREQ=YEARLY;BYDAY=-100000000000000SU;BYMONTH=9223372036854775807
            END:STANDARD
            END:VTIMEZONE
            BEGIN:VEVENT
            UID:z
            DTSTART;TZID=Crafted:20260715T100000
            END:VEVENT
            END:VCALENDAR
            """
        #expect(CalendarInvite.parse(ics)?.start == date("2026-07-15T09:00:00Z"), "falls back to the zone's only offset")
    }

    @Test func replyKeepsTheOrganizerNameOnOneLine() throws {
        let invite = try #require(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:n
            DTSTART:20260701T090000Z
            ORGANIZER;CN=Boss\\nATTENDEE:mailto:boss@example.dk
            END:VEVENT
            END:VCALENDAR
            """))
        let ics = invite.replyICS(as: MailAddress(name: nil, address: "me@x.dk"), status: .accepted)
        #expect(!ics.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("ATTENDEE:mailto:boss") })
    }
}
