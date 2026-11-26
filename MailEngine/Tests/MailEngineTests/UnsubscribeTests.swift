import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MailEngine

/// Captures requests instead of sending them.
final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            captured.httpBody = data
        }
        Self.requests.append(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UnsubscribeTests {
    @Test func methodsFromHeaders() {
        let both = Unsubscribe.methods(
            listUnsubscribe: "<mailto:unsub-123@news.shop.dk?subject=Afmeld%20mig>, <https://shop.dk/u?id=123>",
            listUnsubscribePost: "List-Unsubscribe=One-Click")
        #expect(both == [.oneClick(URL(string: "https://shop.dk/u?id=123")!),
                         .mail(to: "unsub-123@news.shop.dk", subject: "Afmeld mig", body: "")])

        // Without the post header an https link is a page to visit; http never posts.
        #expect(Unsubscribe.methods(listUnsubscribe: "<https://x.dk/u>", listUnsubscribePost: nil) == [.web(URL(string: "https://x.dk/u")!)])
        #expect(Unsubscribe.methods(listUnsubscribe: "<http://x.dk/u>", listUnsubscribePost: "List-Unsubscribe=One-Click")
                == [.web(URL(string: "http://x.dk/u")!)])
        #expect(Unsubscribe.methods(listUnsubscribe: "<mailto:leave@list.org>", listUnsubscribePost: nil)
                == [.mail(to: "leave@list.org", subject: "unsubscribe", body: "")])
        #expect(Unsubscribe.methods(listUnsubscribe: "<javascript:alert(1)>, <ftp://x>", listUnsubscribePost: nil).isEmpty)
        #expect(Unsubscribe.methods(listUnsubscribe: nil, listUnsubscribePost: nil).isEmpty)
    }

    @Test func methodsFromAParsedMessage() {
        let raw = TestMailFactory.html(from: MailAddress(name: "Shop", address: "news@shop.dk"), subject: "Tilbud", date: Date(),
                                       id: "<a@shop.dk>", html: "<p>Hej</p>", bulk: true)
        let methods = Unsubscribe.methods(in: MIMEParser.parse(raw))
        #expect(methods.first == .oneClick(URL(string: "https://shop.dk/unsub?u=1")!))
    }

    @Test func oneClickPostsTheFormAndChecksTheStatus() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let session = URLSession(configuration: config)
        CapturingURLProtocol.requests = []
        CapturingURLProtocol.status = 200
        try await Unsubscribe.postOneClick(URL(string: "https://shop.dk/u?id=1")!, session: session)
        let request = try #require(CapturingURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "List-Unsubscribe=One-Click")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        CapturingURLProtocol.status = 404
        await #expect(throws: Unsubscribe.Failure.self) {
            try await Unsubscribe.postOneClick(URL(string: "https://shop.dk/u?id=1")!, session: session)
        }
    }

    @Test func sendersByVolume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-senders-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        try s.save(MailboxState(accountID: "a", path: "Sent Messages", role: .sent, uidValidity: 1, uidNext: nil, highestModSeq: nil,
                                messageCount: 0, lastSync: nil))
        func m(_ uid: UInt32, _ from: String, mailbox: String = "INBOX", reason: String? = nil, flags: String = "") -> (StoredMessage, String) {
            var msg = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)", threadID: "t\(uid)", subject: "s",
                                    fromName: from == "news@shop.dk" ? "Shop" : nil, fromAddress: from, recipients: "me",
                                    date: Date().addingTimeInterval(Double(uid)))
            msg.classificationReason = reason
            msg.flags = flags
            msg.category = from == "news@shop.dk" ? .advertising : .primary
            return (msg, "s")
        }
        try s.upsert([m(1, "news@shop.dk", reason: "listUnsubscribe"), m(2, "NEWS@shop.dk", mailbox: "Archive", reason: "listUnsubscribe"),
                      m(3, "news@shop.dk", reason: "listUnsubscribe", flags: "\\Seen"), m(4, "anna@firma.dk"),
                      m(5, "me@x.dk", mailbox: "Sent Messages"), m(6, "me@x.dk")])
        try s.recordUnsubscribe(address: "News@Shop.dk", method: "oneClick")
        let stats = try s.senderStats(ownAddresses: ["me@x.dk"])
        #expect(stats.map(\.address) == ["news@shop.dk", "anna@firma.dk"])
        let shop = try #require(stats.first)
        #expect(shop.count == 3 && shop.inboxCount == 2 && shop.unreadCount == 1 && shop.isList && shop.name == "Shop")
        #expect(shop.category == .advertising && shop.unsubscribedAt != nil)
        #expect(try s.newestMessage(from: "news@SHOP.dk")?.uid == 3)
    }
}
