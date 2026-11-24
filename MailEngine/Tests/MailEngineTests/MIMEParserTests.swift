import Foundation
import Testing
@testable import MailEngine

@Suite struct MIMEParserTests {
    func parse(_ raw: String) -> ParsedMessage {
        MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    @Test func danishQuotedPrintableAndEncodedSubject() {
        let m = parse("""
            From: =?utf-8?Q?Lars_M=C3=B8ller?= <lars@moeller.dk>
            To: "Kaspersen, Magnus" <magnus@example.dk>, anna@example.dk
            Subject: =?utf-8?Q?M=C3=B8de_om?= =?utf-8?Q?_projektet?=
            Date: Tue, 24 Nov 2026 10:15:00 +0100
            Message-ID: <abc@moeller.dk>
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hej Magnus,=0A
            Kan vi m=C3=B8des i morgen? Det er en lang linje som er bl=
            evet ombrudt.
            """)
        #expect(m.subject == "Møde om projektet")
        #expect(m.from == [MailAddress(name: "Lars Møller", address: "lars@moeller.dk")])
        #expect(m.to.map(\.address) == ["magnus@example.dk", "anna@example.dk"])
        #expect(m.to.first?.name == "Kaspersen, Magnus")
        #expect(m.messageID == "abc@moeller.dk")
        #expect(m.plainText.contains("Kan vi mødes i morgen?"))
        #expect(m.plainText.contains("blevet ombrudt"))
        #expect(m.date == ISO8601DateFormatter().date(from: "2026-11-24T09:15:00Z"))
    }

    @Test func multipartAlternativePrefersPlainAndKeepsHTML() {
        let m = parse("""
            From: shop@zalando.dk
            Subject: =?ISO-8859-1?B?S3ZpdHRlcmluZyBm+HIgZGl0IGv4Yg==?=
            Content-Type: multipart/alternative; boundary="b1"

            --b1
            Content-Type: text/plain; charset=iso-8859-1
            Content-Transfer-Encoding: quoted-printable

            Tak for dit k=F8b.
            --b1
            Content-Type: text/html; charset=utf-8

            <html><body><p>Tak for dit <b>køb</b>.</p></body></html>
            --b1--
            """)
        #expect(m.subject == "Kvittering før dit køb")
        #expect(m.plainText == "Tak for dit køb.")
        #expect(m.html?.contains("<b>køb</b>") == true)
        #expect(m.attachments.isEmpty)
    }

    @Test func htmlOnlyIsConvertedToText() {
        let m = parse("""
            Subject: Nyhedsbrev
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: base64

            \(Data("<style>p{color:red}</style><h1>Ugens nyheder</h1><p>Første&nbsp;punkt &amp; mere</p><ul><li>Et</li><li>To</li></ul>".utf8).base64EncodedString())
            """)
        #expect(m.plainText.contains("Ugens nyheder"))
        #expect(m.plainText.contains("Første punkt & mere"))
        #expect(m.plainText.contains("• Et"))
        #expect(!m.plainText.contains("color"))
    }

    @Test func nestedMultipartWithRFC2231Attachment() {
        let m = parse("""
            Subject: Faktura
            Content-Type: multipart/mixed; boundary=outer

            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/plain

            Se vedhæftede faktura.
            --inner--
            --outer
            Content-Type: application/pdf
            Content-Disposition: attachment; filename*=utf-8''Faktura%20%C3%A6%C3%B8%C3%A5.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQK
            --outer--
            """)
        #expect(m.plainText == "Se vedhæftede faktura.")
        #expect(m.attachments.count == 1)
        #expect(m.attachments.first?.filename == "Faktura æøå.pdf")
        #expect(m.attachments.first?.mimeType == "application/pdf")
        #expect(m.attachments.first?.size == 9)
    }

    @Test func threadingHeaders() {
        let m = parse("""
            Subject: Re: Middag
            In-Reply-To: <b@x.dk>
            References: <a@x.dk>
             <b@x.dk>

            ok
            """)
        #expect(m.inReplyTo == ["b@x.dk"])
        #expect(m.references == ["a@x.dk", "b@x.dk"])
    }

    @Test func brokenInputDoesNotCrash() {
        let m = parse("""
            Subject: =?unknown-charset?Q?hej?=
            Content-Type: multipart/mixed; boundary=missing

            no boundaries here at all
            """)
        #expect(m.subject == "hej")
        #expect(m.plainText.contains("no boundaries"))
        #expect(MIMEParser.parse(Data()).subject == "")
    }

    @Test func addressFormats() {
        let list = AddressParser.parse(#"Team: a@x.dk, "B, Bo" <b@x.dk>;, c@x.dk (Carl), <d@x.dk>"#)
        #expect(list.map(\.address) == ["a@x.dk", "b@x.dk", "c@x.dk", "d@x.dk"])
        #expect(list[1].name == "B, Bo")
        #expect(list[2].name == "Carl")
    }

    @Test func dateVariants() {
        #expect(DateParser.parse("24 Nov 2026 10:15:00 +0100") != nil)
        #expect(DateParser.parse("Tue, 24 Nov 2026 10:15:00 +0100 (CET)") != nil)
        #expect(DateParser.parse("Tue,  4 Nov 2026 10:15:00 GMT") != nil)
    }
}

@Suite struct SignalClassifierTests {
    func classify(_ headers: String) -> MailCategory {
        SignalClassifier.classify(MIMEParser.parse(Data((headers + "\r\n\r\nbody").replacingOccurrences(of: "\n", with: "\r\n").utf8))).category
    }

    @Test func categories() {
        #expect(classify("From: Anna <anna@example.dk>\nSubject: Middag?") == .primary)
        #expect(classify("From: no_reply@email.apple.com\nSubject: Password changed") == .updates)
        #expect(classify("From: noreply@zalando.dk\nSubject: Din ordre er afsendt") == .transactions)
        #expect(classify("From: news@nike.com\nList-Unsubscribe: <https://x>\nSubject: Black Friday: -40%") == .advertising)
        #expect(classify("From: nyhedsbrev@pol.dk\nList-Unsubscribe: <https://x>\nSubject: Morgenbrief") == .newsletters)
        #expect(classify("From: messages-noreply@linkedin.com\nSubject: New connection") == .social)
    }
}
