import Foundation
import Testing
@testable import MailEngine

@Suite struct MIMEBuilderTests {
    let magnus = MailAddress(name: "Magnus Kaspersen", address: "m@gnus.hk")

    @Test func roundTripsThroughOurParser() {
        let message = OutgoingMessage(
            from: magnus,
            to: [MailAddress(name: "Lars Møller", address: "lars@moeller.dk"), MailAddress(name: "Kaspersen, Anna", address: "anna@example.dk")],
            cc: [MailAddress(name: nil, address: "peter@firma.dk")],
            bcc: [MailAddress(name: nil, address: "secret@example.dk")],
            subject: "Møde om projektet — æøå og en meget lang emnelinje der skal foldes pænt over flere linjer",
            text: "Hej Lars,\n\nKan vi mødes i morgen kl. 10?\n.\nEn linje der starter med punktum og en meget lang linje som helt sikkert er længere end 76 tegn og skal brydes.\n\nMagnus",
            html: "<p>Hej Lars,</p><p>Kan vi <b>mødes</b> i morgen?</p>",
            attachments: [OutgoingAttachment(filename: "Faktura æøå.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 500))],
            inReplyTo: "parent@moeller.dk", references: ["root@moeller.dk", "parent@moeller.dk"]
        )
        let raw = MIMEBuilder.build(message)
        let parsed = MIMEParser.parse(raw)

        #expect(parsed.subject == message.subject)
        #expect(parsed.from == [magnus])
        #expect(parsed.to.map(\.address) == ["lars@moeller.dk", "anna@example.dk"])
        #expect(parsed.to.first?.name == "Lars Møller")
        #expect(parsed.to.last?.name == "Kaspersen, Anna")
        #expect(parsed.cc.map(\.address) == ["peter@firma.dk"])
        #expect(parsed.plainText == message.text)
        #expect(parsed.html == message.html)
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.filename == "Faktura æøå.pdf")
        #expect(parsed.attachments.first?.size == 500)
        #expect(parsed.messageID == message.messageID)
        #expect(parsed.inReplyTo == ["parent@moeller.dk"])
        #expect(parsed.references == ["root@moeller.dk", "parent@moeller.dk"])
    }

    @Test func bccNeverAppearsInHeaders() {
        let message = OutgoingMessage(from: magnus, to: [MailAddress(name: nil, address: "a@x.dk")],
                                      bcc: [MailAddress(name: nil, address: "hidden@x.dk")], subject: "Hej", text: "x")
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        #expect(!raw.contains("hidden@x.dk"))
        #expect(message.envelopeRecipients == ["a@x.dk", "hidden@x.dk"])
    }

    @Test func outputIsSevenBitWithShortLines() {
        let message = OutgoingMessage(from: magnus, to: [MailAddress(name: "Ærlige Åse", address: "a@x.dk")],
                                      subject: String(repeating: "Ø", count: 120), text: String(repeating: "æ", count: 300),
                                      html: "<p>\(String(repeating: "å", count: 300))</p>")
        let raw = MIMEBuilder.build(message)
        #expect(raw.allSatisfy { $0 < 128 }, "7-bit clean")
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 998 }, "RFC 5322 hard limit")
        #expect(lines.filter { $0.utf8.count > 78 }.isEmpty, "folded/soft-broken to 78")
        #expect(MIMEParser.parse(raw).subject == message.subject)
    }

    @Test func plainTextOnlyHasNoMultipart() {
        let raw = String(decoding: MIMEBuilder.build(OutgoingMessage(from: magnus, to: [], subject: "a", text: "b")), as: UTF8.self)
        #expect(!raw.contains("multipart"))
        #expect(raw.contains("Content-Type: text/plain; charset=utf-8"))
    }

    @Test func typedLineBreaksCantInjectHeaders() {
        let message = OutgoingMessage(
            from: MailAddress(name: "Eve\r\nBcc: victim@x.dk", address: "e@x.dk"),
            to: [MailAddress(name: nil, address: "a@x.dk")],
            subject: "Hej\r\nBcc: victim@x.dk\nX-Evil: 1", text: "b",
            attachments: [OutgoingAttachment(filename: "a\r\nX-Evil: 1.txt", mimeType: "text/plain\r\nX-Evil: 1", data: Data("x".utf8))],
            inReplyTo: "<p@x.dk>\r\nX-Evil: 1")
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        let lines = raw.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("Bcc:") || $0.hasPrefix("X-Evil:") })
        #expect(!raw.contains("\r\nBcc:") && !raw.contains("\nX-Evil"))
        #expect(raw.contains("Content-Type: application/octet-stream"))
        #expect(MIMEParser.parse(MIMEBuilder.build(message)).subject == "Hej Bcc: victim@x.dk X-Evil: 1")
    }

    @Test func bccOnlyGetsUndisclosedRecipients() {
        let message = OutgoingMessage(from: magnus, to: [], bcc: [MailAddress(name: nil, address: "hidden@x.dk")], subject: "Hej", text: "x")
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        #expect(raw.contains("\r\nTo: undisclosed-recipients:;\r\n"))
        #expect(!raw.contains("hidden@x.dk"))
    }

    @Test func linesStartingWithFromOrDotAreEncoded() {
        let qp = MIMEBuilder.quotedPrintable("From here\n.\nFromage is fine\n" + String(repeating: "x", count: 75) + "From there")
        let lines = qp.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("From ") || $0.hasPrefix(".") })
        #expect(lines.contains("Fromage is fine"))
        let message = OutgoingMessage(from: magnus, to: [], subject: "a", text: "From here\n.\nok")
        #expect(MIMEParser.parse(MIMEBuilder.build(message)).plainText == "From here\n.\nok")
    }

    @Test func inlineImagesAreRelatedToTheHTMLOnly() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let message = OutgoingMessage(
            from: magnus, to: [MailAddress(name: nil, address: "a@x.dk")], subject: "Hej", text: "Hej",
            html: "<p>Hej <img src=\"cid:logo@x\"></p>",
            attachments: [OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: png, contentID: "logo@x"),
                          OutgoingAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1]))])
        let raw = MIMEBuilder.build(message)
        let entity = Entity.parse([UInt8](raw)[...])
        #expect(entity.contentType.full == "multipart/mixed")
        let alternative = try #require(entity.children.first)
        #expect(alternative.contentType.full == "multipart/alternative")
        #expect(alternative.children.map(\.contentType.full) == ["text/plain", "multipart/related"])
        let related = try #require(alternative.children.last)
        #expect(related.contentType.parameters["type"] == "text/html")
        #expect(related.children.map(\.contentType.full) == ["text/html", "image/png"])
        #expect(MIMEParser.attachments(in: raw).first { $0.contentID == "logo@x" }?.data == png)
    }

    @Test func longNonASCIIFilenamesUseContinuations() {
        let name = "Referat fra mødet om årsregnskabet og budgettet for næste år — endelig version æøå.pdf"
        let raw = MIMEBuilder.build(OutgoingMessage(
            from: magnus, to: [], subject: "s", text: "t",
            attachments: [OutgoingAttachment(filename: name, mimeType: "application/pdf", data: Data([1, 2, 3]))]))
        let source = String(decoding: raw, as: UTF8.self)
        #expect(source.contains("filename*0*=utf-8''"))
        #expect(source.contains("filename*1*="))
        #expect(source.components(separatedBy: "\r\n").filter { $0.count > 78 } == [])
        #expect(MIMEParser.attachments(in: raw).first?.filename == name)
    }

    @Test func asciiThatLooksEncodedIsEncoded() {
        let subject = "About =?utf-8?B?SGVq?= tokens"
        let raw = MIMEBuilder.build(OutgoingMessage(from: magnus, to: [], subject: subject, text: "t"))
        #expect(MIMEParser.parse(raw).subject == subject)
    }
}

@Suite struct ForwardAttachmentTests {
    @Test func extractsAttachmentData() {
        let pdf = Data((0..<300).map { UInt8($0 % 256) })
        let raw = MIMEBuilder.build(OutgoingMessage(
            from: MailAddress(name: nil, address: "a@x.dk"), to: [], subject: "s", text: "t",
            attachments: [OutgoingAttachment(filename: "Kontrakt æøå.pdf", mimeType: "application/pdf", data: pdf)]))
        let found = MIMEParser.attachments(in: raw)
        #expect(found.count == 1)
        #expect(found.first?.filename == "Kontrakt æøå.pdf")
        #expect(found.first?.data == pdf)
    }

    @Test func lineBreaksInHeaderTextCannotInjectHeaders() {
        // A reply's subject or a forwarded file's name can come from an encoded word with a CRLF in it.
        var message = OutgoingMessage(
            from: MailAddress(name: "Evil\r\nBcc: x@evil.example", address: "m@gnus.hk"),
            to: [MailAddress(name: nil, address: "lars@moeller.dk")],
            subject: "Re: hi\r\nBcc: victim@example.dk", text: "body",
            attachments: [OutgoingAttachment(filename: "a.pdf\r\nX-Injected: 1", mimeType: "application/pdf", data: Data([1]))])
        message.inReplyTo = "parent@x\r\nX-Injected: 2"
        let raw = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        let lines = raw.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("Bcc:") || $0.hasPrefix("X-Injected:") })
        #expect(MIMEParser.parse(Data(raw.utf8)).subject == "Re: hi Bcc: victim@example.dk")
    }
}
