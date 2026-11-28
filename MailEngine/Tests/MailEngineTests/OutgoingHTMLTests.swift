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
