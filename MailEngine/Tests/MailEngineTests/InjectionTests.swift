import Foundation
import NIOCore
import Testing
@testable import MailEngine

/// Text a sender controls (subjects, names, filenames, invite fields, unsubscribe addresses)
/// must never add headers or SMTP commands to mail sent as the user.
struct InjectionTests {
    /// Header lines of a built message (before the first blank line), unfolded.
    func headerLines(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
        return head.replacingOccurrences(of: "\r\n ", with: " ").components(separatedBy: "\r\n")
    }

    let me = MailAddress(name: "Me", address: "me@example.com")

    @Test func encodedSubjectLineBreaksAreFlattened() {
        let raw = Data("""
            From: =?utf-8?Q?Eve=0D=0ABcc:_boss@corp.com?= <eve@evil.test>\r
            To: me@example.com\r
            Subject: =?utf-8?Q?Invoice=0D=0AReply-To:_attacker@evil.test=0D=0A=0D=0AFake_body?=\r
            Message-ID: <a@b>\r
            \r
            hi\r
            """.utf8)
        let parsed = MIMEParser.parse(raw)
        #expect(!parsed.subject.contains("\r") && !parsed.subject.contains("\n"))
        #expect(parsed.from.first?.name?.contains("\n") == false)
        #expect(parsed.from.first?.address == "eve@evil.test")
    }

    @Test func builderKeepsEveryHeaderOnOneLine() {
        var m = OutgoingMessage(
            from: me,
            to: [MailAddress(name: "Bob\r\nBcc: x@evil.test", address: "bob@example.com\r\nX-Evil: 1")],
            subject: "Re: Invoice\r\nReply-To: attacker@evil.test\n\nFake body",
            text: "body", inReplyTo: "id@x>\r\nX-Injected: 1", references: ["r@x>\nX-Ref: 1"])
        m.attachments = [OutgoingAttachment(filename: "a\r\nContent-Type: text/html\r\n\r\n<b>.pdf",
                                            mimeType: "application/pdf\r\nX-Evil: 1", data: Data("x".utf8),
                                            contentID: "c@x>\r\nX-Cid: 1")]
        let data = MIMEBuilder.build(m)
        let text = String(decoding: data, as: UTF8.self)
        for evil in ["\r\nBcc:", "\r\nReply-To:", "\r\nX-Evil:", "\r\nX-Injected:", "\r\nX-Ref:", "\r\nX-Cid:", "\r\nContent-Type: text/html\r\n\r\n<b>"] {
            #expect(!text.contains(evil), "injected \(evil.debugDescription)")
        }
        let headers = headerLines(data)
        #expect(headers.filter { $0.hasPrefix("Subject:") }.count == 1)
        #expect(headers.contains { $0.hasPrefix("Subject: Re: Invoice") })
        // No bare CR or LF survives anywhere: every line break is CRLF.
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func badMimeTypeFallsBack() {
        #expect(MIMEBuilder.mimeType("image/png") == "image/png")
        #expect(MIMEBuilder.mimeType("application/vnd.ms-excel") == "application/vnd.ms-excel")
        #expect(MIMEBuilder.mimeType("text/html; x=1") == "application/octet-stream")
        #expect(MIMEBuilder.mimeType("a\r\nb/c") == "application/octet-stream")
    }

    @Test func dataPayloadTurnsBareCRIntoLineEnds() {
        let payload = SMTPClient.dataPayload(Data("a\r.\r\nMAIL FROM:<x@y>\rb".utf8))
        let text = String(buffer: payload)
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        #expect(text.contains("\r\n..\r\n"))   // the smuggled "." is dot-stuffed
        #expect(text.hasSuffix("\r\n.\r\n"))
    }

    @Test func envelopeAddressesAreChecked() {
        #expect(SMTPConnection.isSafeEnvelopeAddress("bob@example.com"))
        #expect(SMTPConnection.isSafeEnvelopeAddress("b.o+b@ex-ample.co.uk"))
        #expect(!SMTPConnection.isSafeEnvelopeAddress("u@shop.com>\r\nRCPT TO:<ceo@corp.com"))
        #expect(!SMTPConnection.isSafeEnvelopeAddress("x@y> NOTIFY=NEVER"))
        #expect(!SMTPConnection.isSafeEnvelopeAddress("nobody"))
    }

    @Test func mailtoUnsubscribeRejectsInjection() {
        let evil = Unsubscribe.methods(
            listUnsubscribe: "<mailto:u@shop.com%3E%0D%0ARCPT%20TO:%3Cceo@corp.com?subject=x>", listUnsubscribePost: nil)
        #expect(evil.isEmpty)
        let two = Unsubscribe.methods(listUnsubscribe: "<mailto:a@x.com,b@y.com>", listUnsubscribePost: nil)
        #expect(two.isEmpty)
        let subject = Unsubscribe.methods(
            listUnsubscribe: "<mailto:leave@list.org?subject=bye%0D%0ABcc:%20x@evil.test>", listUnsubscribePost: nil)
        guard case .mail(let to, let s, _)? = subject.first else { Issue.record("expected a mail method"); return }
        #expect(to == "leave@list.org")
        #expect(!s.contains("\r") && !s.contains("\n"))
    }

    @Test func oneClickRefusesLocalTargets() {
        for host in ["https://localhost/u", "https://127.0.0.1/u", "https://10.0.0.1/u", "https://192.168.1.1/u",
                     "https://172.20.0.5/u", "https://169.254.169.254/latest", "https://[::1]/u", "https://[fd00::1]/u",
                     "https://nas.local/u", "https://router/u"] {
            #expect(Unsubscribe.isLocalTarget(URL(string: host)!), "\(host)")
        }
        for host in ["https://shop.dk/u", "https://8.8.8.8/u", "https://172.32.0.1/u", "https://list.example.org/u?x=1"] {
            #expect(!Unsubscribe.isLocalTarget(URL(string: host)!), "\(host)")
        }
    }

    @Test func inviteFieldsCantInjectIntoTheReply() throws {
        let ics = """
            BEGIN:VCALENDAR\r
            METHOD:REQUEST\r
            BEGIN:VEVENT\r
            UID:evil-1\r
            DTSTART:20261201T100000Z\r
            DTEND:20261201T110000Z\r
            SUMMARY:Lunch\\nBcc: x@evil.test\\n\\nAttacker body\r
            ORGANIZER;CN="Boss\\nReply-To: a@evil.test":mailto:boss@corp.com\r
            ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let invite = try #require(CalendarInvite.parse(ics))
        #expect(!invite.summary.contains("\n"))
        #expect(invite.organizer?.name?.contains("\n") == false)
        let reply = try #require(invite.replyMessage(from: me, status: .accepted, subject: "Accepted: \(invite.summary)", text: "ok"))
        let data = MIMEBuilder.build(reply)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\r\nBcc:"))
        #expect(!text.contains("\r\nReply-To:"))
        let replyICS = reply.calendar?.ics ?? ""
        #expect(!replyICS.contains("\r\nReply-To:"))
    }

    @Test func htmlScansStayLinearOnUnclosedTags() {
        let bomb = String(repeating: "<a href=\"https://x.test/unsubscribe\"", count: 40_000)
            + String(repeating: "<script ", count: 40_000) + String(repeating: "<!--", count: 40_000) + String(repeating: "<", count: 200_000)
        let start = Date()
        _ = HTMLText.toPlainText(bomb)
        _ = Unsubscribe.bodyLinks(html: bomb)
        _ = PhishingCheck.mismatchedLinks(in: bomb)
        _ = SchemaOrgEvents.scripts(in: bomb)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func htmlScanStillFindsElements() {
        let html = #"<p>x</p><A HREF="https://a.test/u">Unsubscribe <b>here</b></A><abbr>no</abbr><a href='https://b.test'>b</a>"#
        let anchors = HTMLScan.elements("a", in: html)
        #expect(anchors.map(\.inner) == ["Unsubscribe <b>here</b>", "b"])
        #expect(Unsubscribe.bodyLinks(html: html) == [URL(string: "https://a.test/u")!])
        #expect(HTMLText.toPlainText("<style>p{}</style><p>Hi<!-- c --> there</p><script>x()</script>") == "Hi there")
        #expect(HTMLText.toPlainText("<p>open <!-- never closed</p>").contains("open"))
    }
}
