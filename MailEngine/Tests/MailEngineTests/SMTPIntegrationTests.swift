import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MailEngine

/// Against the local Mailpit (MailEngine/TestServer): STARTTLS + AUTH like iCloud; nothing is delivered.
@Suite(.serialized) struct SMTPIntegrationTests {
    static let endpoint = SMTPEndpoint(host: "127.0.0.1", port: 31587, security: .startTLS,
                                       username: "magnus@tidings.test", allowSelfSignedLocalhost: true)

    static var available: Bool {
        get async {
            guard let url = URL(string: "http://127.0.0.1:38025/api/v1/info") else { return false }
            return (try? await URLSession.shared.data(from: url)) != nil
        }
    }

    struct Caught: Decodable {
        struct Address: Decodable { var Address: String }
        var ID: String
        var MessageID: String
        var Subject: String
        var To: [Address]
        var Bcc: [Address]?
    }

    static func caught(messageID: String) async throws -> Caught? {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:38025/api/v1/messages?limit=200")!)
        struct List: Decodable { var messages: [Caught] }
        return try JSONDecoder().decode(List.self, from: data).messages.first { $0.MessageID == messageID }
    }

    static func raw(id: String) async throws -> Data {
        try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:38025/api/v1/message/\(id)/raw")!).0
    }

    @Test func sendsOverStartTLSWithAuth() async throws {
        guard await Self.available else { return }
        let message = OutgoingMessage(
            from: MailAddress(name: "Magnus Kaspersen", address: "magnus@tidings.test"),
            to: [MailAddress(name: "Anna Jensen", address: "anna@example.dk")],
            bcc: [MailAddress(name: nil, address: "hidden@example.dk")],
            subject: "Middag på lørdag ✓", text: "Hej Anna\n.\nVi ses kl. 18.", html: "<p>Hej <b>Anna</b></p>"
        )
        let reply = try await SMTPClient.send(endpoint: Self.endpoint, password: "anything", from: message.from.address,
                                              recipients: message.envelopeRecipients, message: MIMEBuilder.build(message))
        #expect(reply.code == 250)

        let caught = try #require(try await Self.caught(messageID: message.messageID))
        #expect(caught.Subject == "Middag på lørdag ✓")
        #expect(caught.To.map(\.Address) == ["anna@example.dk"])
        #expect(caught.Bcc?.map(\.Address) == ["hidden@example.dk"], "bcc delivered via the envelope")

        let parsed = MIMEParser.parse(try await Self.raw(id: caught.ID))
        #expect(parsed.plainText == "Hej Anna\n.\nVi ses kl. 18.", "dot-stuffing round-trips")
        // (Mailpit adds its own Bcc header to stored copies; MIMEBuilderTests proves we never send one.)
    }

    @Test func verifyChecksLoginWithoutSending() async throws {
        guard await Self.available else { return }
        try await SMTPClient.verify(endpoint: Self.endpoint, password: "anything")
    }

    @Test(.timeLimit(.minutes(1))) func failsFastAgainstANonSMTPServer() async throws {
        guard await Self.available else { return }
        // Port 31143 is IMAP: its "* OK" greeting must fail at once, not wait for a timeout.
        let wrong = SMTPEndpoint(host: "127.0.0.1", port: 31143, security: .startTLS, username: "x", allowSelfSignedLocalhost: true)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SMTPError.self) {
            try await SMTPClient.verify(endpoint: wrong, password: "x")
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func dotStuffing() {
        let payload = SMTPClient.dataPayload(Data(".start\n..two\nend".utf8))
        #expect(String(buffer: payload) == "..start\r\n...two\r\nend\r\n.\r\n")
    }
}
