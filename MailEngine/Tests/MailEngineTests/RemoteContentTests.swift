import Foundation
import Testing
@testable import MailEngine

@Suite struct RemoteContentTests {
    @Test func removesTrackingPixelsButKeepsRealImages() {
        let html = """
            <p>Hej</p>
            <img src="https://cdn.shop.dk/hero.jpg" width="600" height="300">
            <img src="https://shop.us1.list-manage.com/track/open.php?u=1" width="1" height="1">
            <img src="https://t.shop.dk/o.gif?id=9" style="width:1px;height:1px">
            <img src="https://x.dk/a.png" style="display:none">
            <img src="https://news.example.com/open?u=42">
            <img src="cid:logo123">
            """
        let prepared = RemoteContent.prepare(html)
        #expect(prepared.trackersRemoved == 4)
        #expect(prepared.remoteImages == 1)
        #expect(prepared.html.contains("hero.jpg"))
        #expect(prepared.html.contains("cid:logo123"))
        #expect(!prepared.html.contains("list-manage"))
    }

    @Test func stripsTrackingParametersFromLinks() {
        let prepared = RemoteContent.prepare(#"<a href="https://shop.dk/sko?id=7&amp;utm_source=nl&amp;utm_medium=email&amp;fbclid=abc">Se sko</a>"#)
        #expect(prepared.linksCleaned == 1)
        #expect(prepared.html.contains(#"href="https://shop.dk/sko?id=7""#))
        #expect(RemoteContent.prepare(#"<a href="https://shop.dk/sko?id=7">x</a>"#).linksCleaned == 0)
    }

    @Test func imagesLoadForCorrespondentsAndApprovedSenders() throws {
        let store = try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID()).sqlite").path)
        try store.upsert([(StoredMessage(accountID: "a", mailbox: "Sent", uid: 1, subject: "Hej", fromAddress: "me@x.dk",
                                         recipients: "Anna <anna@example.dk>", date: Date()), "hej")])
        let mine: Set<String> = ["me@x.dk"]
        #expect(try store.allowsRemoteImages(from: "Anna@Example.dk", ownAddresses: mine), "someone I've written to")
        #expect(try !store.allowsRemoteImages(from: "news@shop.dk", ownAddresses: mine))
        #expect(try store.allowsRemoteImages(from: "Me@X.dk", ownAddresses: mine), "my own mail (my signature's pictures)")
        try store.trustImages(from: "@shop.dk")
        #expect(try store.allowsRemoteImages(from: "news@shop.dk", ownAddresses: mine), "domain approved")
    }

    @Test func inlineImagesWithOnlyAContentIDAreFound() {
        let raw = """
            Content-Type: multipart/related; boundary=b\r\n\r\n--b\r\nContent-Type: text/html\r\n\r\n<img src="cid:logo@x">\r\n--b\r\nContent-Type: image/png\r\nContent-ID: <logo@x>\r\nContent-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo=\r\n--b--\r\n
            """
        let parts = MIMEParser.inlineParts(in: Data(raw.utf8))
        #expect(parts["logo@x"]?.mimeType == "image/png")
    }
}
