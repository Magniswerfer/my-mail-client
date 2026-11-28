import Foundation
import Testing
@testable import MailEngine

@Suite struct OutgoingHTMLTests {
    @Test func documentIsCompleteAndDeclaresUTF8() {
        let html = OutgoingHTML.document("<p>Hej</p>")
        #expect(html.hasPrefix("<!DOCTYPE html><html><head>"))
        #expect(html.contains("charset=utf-8"))
        #expect(html.contains("name=\"viewport\""))
        #expect(html.contains("font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px"))
        #expect(html.hasSuffix("<p>Hej</p></div></body></html>"))
        // No colours: the recipient's light or dark appearance decides.
        #expect(!html.contains("color:") && !html.contains("background"))
        // The font stack's quotes don't end the style attribute.
        #expect(!html.contains("\"Helvetica Neue\""))
    }

    @Test func textKeepsSpacesHTMLWouldCollapse() {
        #expect(OutgoingHTML.text("a b") == "a b")
        #expect(OutgoingHTML.text("a   b") == "a&nbsp;&nbsp; b")
        #expect(OutgoingHTML.text(" indented") == "&nbsp;indented")
        #expect(OutgoingHTML.text("trailing ") == "trailing&nbsp;")
        #expect(OutgoingHTML.text(" mid ", leadingEdge: false, trailingEdge: false) == " mid ")
        #expect(OutgoingHTML.text("\tx") == "&nbsp;&nbsp;&nbsp; x")
        #expect(OutgoingHTML.text("<b> & \"q\"") == "&lt;b&gt; &amp; &quot;q&quot;")
    }

    @Test func plainTextLinksSayWhereTheyGo() {
        #expect(OutgoingHTML.plainTextLink(text: "Read more", href: "https://example.com/a") == "Read more <https://example.com/a>")
        #expect(OutgoingHTML.plainTextLink(text: "example.com", href: "https://example.com/") == "example.com")
        #expect(OutgoingHTML.plainTextLink(text: "https://example.com/a", href: "https://example.com/a") == "https://example.com/a")
        #expect(OutgoingHTML.plainTextLink(text: "anna@x.dk", href: "mailto:anna@x.dk") == "anna@x.dk")
    }
}

@Suite struct SubjectEncodingTests {
    @Test func onlyTheWordsThatNeedItAreEncoded() {
        #expect(MIMEBuilder.encodeText("Re: Møde i morgen") == "Re: =?utf-8?Q?M=C3=B8de?= i morgen")
        #expect(MIMEBuilder.encodeText("Plain subject") == "Plain subject")
        #expect(MIMEBuilder.encodeText("Re: Grøn æble") == "Re: =?utf-8?Q?Gr=C3=B8n_=C3=A6ble?=")
    }

    @Test func roundTripsThroughOurParser() {
        let subjects = ["Re: Møde i morgen", "🎉🎉🎉 Fest på fredag 🎉", "Sv: Kære Åse — årsregnskab", "Tab\tand  two spaces ø",
                        String(repeating: "Ø", count: 120), "a =?utf-8?B?SGVq?= b", " leading ø", "ø trailing "]
        for subject in subjects {
            let raw = MIMEBuilder.build(OutgoingMessage(from: MailAddress(name: nil, address: "a@x.dk"), to: [], subject: subject, text: "t"))
            let expected = subject.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            #expect(MIMEParser.parse(raw).subject == expected)
            #expect(String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        }
    }
}
