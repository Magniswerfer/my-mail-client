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
                     "https://nas.local/u", "https://router/u", "https://[0:0:0:0:0:0:0:1]/u",
                     "https://[::ffff:7f00:1]/u", "https://[::ffff:127.0.0.1]/u", "https://[fe80::1%25en0]/u",
                     "https://0177.0.0.1/u", "https://2130706433/u", "https://0x7f.1/u", "https://[fc00::1]/u"] {
            #expect(Unsubscribe.isLocalTarget(URL(string: host)!), "\(host)")
        }
        for host in ["https://shop.dk/u", "https://8.8.8.8/u", "https://172.32.0.1/u", "https://list.example.org/u?x=1",
                     "https://163.com/u", "https://126.com/u", "https://123.cafe/u", "https://[2001:db8::1]/u"] {
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

    @Test func attachmentNamesCantDisguiseThemselves() {
        #expect(AttachmentNames.sanitize("invoice\u{202E}fdp.command") == "invoicefdp.command")
        #expect(AttachmentNames.isRisky("invoice\u{202E}fdp.command"))
        #expect(AttachmentNames.sanitize("../../.ssh/authorized_keys") == "-..-.ssh-authorized_keys")
        #expect(AttachmentNames.sanitize("..") == "attachment")
        #expect(AttachmentNames.sanitize(".hidden") == "hidden")
        #expect(AttachmentNames.sanitize("a\u{0}b\r\nc.pdf") == "abc.pdf")
        #expect(AttachmentNames.sanitize(String(repeating: "x", count: 300) + ".pdf").hasSuffix(".pdf"))
        #expect(!AttachmentNames.isRisky("report.pdf") && AttachmentNames.isRisky("Setup.PKG") && AttachmentNames.isRisky("x.webloc"))
        let raw = Data("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nhi\r\n--b\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=utf-8''invoice%E2%80%AEfdp.command\r\n\r\nx\r\n--b--\r\n".utf8)
        #expect(MIMEParser.parse(raw).attachments.first?.filename == "invoicefdp.command")
    }

    @Test func onlySafeLinkSchemesOpen() {
        for ok in ["https://shop.dk/x", "http://a.test", "mailto:a@b.dk", "tel:+4512345678", "tidings://message/x"] {
            #expect(RemoteContent.isOpenable(URL(string: ok)!), "\(ok)")
        }
        for bad in ["file:///Applications/Utilities/Terminal.app", "smb://evil.test/share", "x-apple.systempreferences:com.apple.preference.security",
                    "vnc://evil.test", "ssh://evil.test", "zoommtg://evil", "javascript:alert(1)", "data:text/html,hi", "https:///nohost"] {
            #expect(!RemoteContent.isOpenable(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func metaRefreshAndPrefetchLinksAreRemoved() {
        let html = #"<meta http-equiv="refresh" content="0;url=https://t.evil/o?id=1"><META HTTP-EQUIV=Refresh CONTENT="1"><link rel="dns-prefetch" href="//t.evil"><p>Hi</p>"#
        let out = RemoteContent.prepare(html).html
        #expect(!out.lowercased().contains("refresh"))
        #expect(!out.contains("t.evil"))
        #expect(out.contains("<p>Hi</p>"))
    }

    func parsed(_ headers: String) -> ParsedMessage {
        MIMEParser.parse(Data((headers.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\nhi\r\n").utf8))
    }

    @Test func autoRepliesGoOnlyToTheAuthor() {
        let mine: Set<String> = ["me@example.com"]
        let ok = parsed("From: Anna <anna@example.dk>\nReply-To: victim@else.test\nTo: me@example.com, boss@corp.test\nSubject: Hi")
        #expect(AutoReplyPolicy.recipient(for: ok, ownAddresses: mine)?.address == "anna@example.dk", "the author, not Reply-To")
        // Forged "from me" with an attacker's To: list: no reply at all.
        #expect(AutoReplyPolicy.recipient(for: parsed("From: me@example.com\nTo: a@x.test, b@y.test\nSubject: x"), ownAddresses: mine) == nil)
        for robot in ["Auto-Submitted: auto-replied", "Precedence: bulk", "List-Id: <news.shop.dk>", "List-Unsubscribe: <mailto:u@shop.dk>",
                      "Return-Path: <>", "Authentication-Results: mx; dmarc=fail header.from=example.dk"] {
            #expect(AutoReplyPolicy.recipient(for: parsed("From: anna@example.dk\n\(robot)\nSubject: x"), ownAddresses: mine) == nil, "\(robot)")
        }
        #expect(AutoReplyPolicy.recipient(for: parsed("From: noreply@shop.dk\nSubject: x"), ownAddresses: mine) == nil)
        #expect(AutoReplyPolicy.recipient(for: parsed("From: anna@example.dk\nAuto-Submitted: no\nSubject: x"), ownAddresses: mine) != nil)
    }

    @Test func ruleMailSaysItsAutomatic() {
        var m = OutgoingMessage(from: me, to: [MailAddress(name: nil, address: "a@b.dk")], subject: "Re: x", text: "Away")
        m.autoSubmitted = "auto-replied"
        #expect(headerLines(MIMEBuilder.build(m)).contains("Auto-Submitted: auto-replied"))
    }

    @Test func deeplyNestedCalendarsAreRefused() {
        let deep = String(repeating: "BEGIN:VEVENT\r\n", count: 100_000)
        #expect(ICalendar.parse("BEGIN:VCALENDAR\r\n" + deep).isEmpty)
        #expect(ICalendar.parse("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nBEGIN:VALARM\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").count == 1)
    }

    @Test func oneBadCloudRecordDoesntStopTheBatch() throws {
        let store = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID()).sqlite").path)
        let now = Date()
        let bad = StateRecord(type: StateRecordType.rule.rawValue, key: "r1", payload: Data("not json".utf8), modifiedAt: now)
        let good = StateRecord(type: StateRecordType.imageTrust.rawValue, key: "@shop.dk", payload: Data("{}".utf8), modifiedAt: now)
        let report = try store.applyCloudChanges(saves: [bad, good], deletions: [], accounts: CloudAccounts([]))
        #expect(report.skipped == 1)
        #expect(try store.allowsRemoteImages(from: "news@shop.dk", ownAddresses: []))
    }
}
