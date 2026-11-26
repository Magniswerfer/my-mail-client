import APNSTestServer
import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MailEngine
import Testing
@testable import TidingsPush

/// The whole server against the local Dovecot (IMAP IDLE) and Mailpit (SMTP), with APNSwift's
/// fake APNs: the real APNs client, JWT and HTTP request, just not Apple. Skips itself when the
/// test servers aren't running (`MailEngine/TestServer`). Nothing here touches a real account.
@Suite(.serialized) struct EndToEndTests {
    static let password = "tidings-test"
    static let me = MailAddress(name: "Magnus Kaspersen", address: "magnus@tidings.test")
    static let deviceToken = String(repeating: "3c", count: 32)

    static var dovecotAvailable: Bool {
        get async {
            (try? await MailSession.probeGreeting(endpoint: IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "x"))) != nil
        }
    }

    static var mailpitAvailable: Bool {
        get async {
            guard let url = URL(string: "http://127.0.0.1:38025/api/v1/info") else { return false }
            return (try? await URLSession.shared.data(from: url)) != nil
        }
    }

    struct Harness {
        let apns: APNSTestServer
        let engine: PushEngine
        let endpoint: IMAPEndpoint
        let login: String

        func pushes() -> [APNSTestServer.SentNotification] { apns.getSentNotifications() }

        /// Polls until `condition` holds or `seconds` pass.
        func waitFor(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if try await condition() { return true }
                try await Task.sleep(for: .milliseconds(200))
            }
            return false
        }

        func append(_ mailbox: String = "INBOX", from: String, fromName: String, subject: String,
                    headers: [String] = [], flags: [String] = []) async throws {
            let raw = ([
                "From: \(fromName) <\(from)>", "To: \(EndToEndTests.me.name ?? "") <\(EndToEndTests.me.address)>", "Subject: \(subject)",
                "Date: \(Self.rfc822(Date()))", "Message-ID: <\(UUID().uuidString)@tidings.test>", "MIME-Version: 1.0",
                "Content-Type: text/plain; charset=utf-8",
            ] + headers + ["", "Hej Magnus,", "", "Hvad siger du til det?", "", "Anna", ""]).joined(separator: "\r\n")
            try await MailSession.open(endpoint: endpoint, password: EndToEndTests.password) { session in
                try await session.ensureMailbox(mailbox)
                _ = try await session.append(to: mailbox, message: Data(raw.utf8), flags: flags)
            }
        }

        static func rfc822(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f.string(from: date)
        }
    }

    func harness(smtp: Bool = false) async throws -> Harness? {
        guard await Self.dovecotAvailable else { return nil }
        if smtp, !(await Self.mailpitAvailable) { return nil }
        let apns = APNSTestServer()
        try await apns.start(port: 0)
        let key = P256.Signing.PrivateKey()
        let config = try Fixtures.config(apns: .init(privateKeyPEM: key.pemRepresentation, keyID: "TESTKEY123", teamID: "493257NQK3",
                                                     topic: "hk.gnus.tidings.dev", overrideURL: "http://127.0.0.1", overridePort: apns.port))
        let logger = Logger(label: "e2e")
        let engine = try PushEngine(config: config, sender: try APNsSender(config.apns!, logger: logger), logger: logger)
        try await engine.start()

        let login = "push-\(UUID().uuidString.prefix(8).lowercased())@tidings.test"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: login)
        _ = try await TestServerSeeder.seed(endpoint: endpoint, password: Self.password)

        // What the iPhone does: pair, hand over its push token, upload the account.
        let app = Application(router: PushServerAPI.router(engine: engine))
        try await app.test(.router) { client in
            let paired = try await client.execute(uri: "/v1/devices", method: .post,
                                                  body: try Fixtures.json(PushAPI.PairRequest(secret: Fixtures.secret, deviceName: "iPhone"))) {
                try Fixtures.decode(PushAPI.PairResponse.self, $0.body)
            }
            let auth: HTTPFields = [.authorization: "Bearer \(paired.token)"]
            try await client.execute(uri: "/v1/devices/me", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.DeviceUpdate(apnsToken: Self.deviceToken, environment: .sandbox))) {
                #expect($0.status == .noContent)
            }
            let account = AccountConfig(displayName: "Push test", endpoint: endpoint, addresses: [Self.me.address],
                                        smtp: smtp ? SMTPEndpoint(host: "127.0.0.1", port: 31587, security: .startTLS, username: login,
                                                                  allowSelfSignedLocalhost: true) : nil)
            try await client.execute(uri: "/v1/accounts/\(login)", method: .put, headers: auth,
                                     body: try Fixtures.json(PushAPI.AccountUpload(record: CloudAccountRecord(account), password: Self.password))) {
                #expect($0.status == .noContent)
            }
        }
        let h = Harness(apns: apns, engine: engine, endpoint: endpoint, login: login)
        // First sync done: the seeded mail is old news and must not notify.
        #expect(try await h.waitFor(30) { try await engine.status().accounts.first?.state == "idle" })
        return h
    }

    func shutdown(_ h: Harness) async throws {
        await h.engine.stop()
        try await h.apns.shutdown()
    }

    @Test func newPrimaryMailNotifiesTheDeviceAndBulkMailDoesnt() async throws {
        guard let h = try await harness() else { return }
        #expect(h.pushes().isEmpty, "the first sync never notifies")

        try await h.append(from: "deals@shop.example", fromName: "Shop", subject: "Black Friday -40%",
                           headers: ["List-Unsubscribe: <mailto:unsub@shop.example>", "Precedence: bulk"])
        try await h.append(from: "anna@firma.dk", fromName: "Anna Jensen", subject: "Middag på fredag?")

        #expect(try await h.waitFor { !h.pushes().isEmpty }, "IDLE noticed the new mail and APNs got a push")
        try await Task.sleep(for: .seconds(2)) // anything else that would (wrongly) follow
        let pushes = h.pushes()
        #expect(pushes.count == 1)
        let push = try #require(pushes.first)
        #expect(push.deviceToken == Self.deviceToken)
        #expect(push.topic == "hk.gnus.tidings.dev")
        #expect(push.pushType == "alert")
        #expect(push.collapseID?.hasPrefix("mail-") == true)
        let payload = try #require(try JSONSerialization.jsonObject(with: push.payload) as? [String: Any])
        let alert = try #require((payload["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Anna Jensen")
        #expect(alert["body"] as? String == "Middag på fredag?")
        #expect(payload[PushAPI.PayloadKey.account] as? String == h.login)
        #expect((payload[PushAPI.PayloadKey.messageID] as? String)?.hasSuffix("@tidings.test") == true)
        #expect(payload[PushAPI.PayloadKey.kind] as? String == "mail")
        try await shutdown(h)
    }

    @Test func aSnoozeWakesWithNoDeviceRunning() async throws {
        guard let h = try await harness() else { return }
        // Snoozed by a device until a few seconds from now, then the device went away.
        try await h.append("Snoozed", from: "bo@firma.dk", fromName: "Bo", subject: "Snoozed reminder",
                           flags: SnoozeKeywords.keywords(until: Date().addingTimeInterval(4)))
        try await h.engine.applyState([]) // nudges the connection to look again now
        #expect(try await h.waitFor(40) { h.pushes().contains { String(decoding: $0.payload, as: UTF8.self).contains("\"wake\"") } })
        // And it's back in the Inbox on the server.
        let inInbox = try await MailSession.open(endpoint: h.endpoint, password: Self.password) { session in
            _ = try await session.select("INBOX", readOnly: true)
            return try await session.fetchHeaderField("Subject").values.contains("Snoozed reminder")
        }
        #expect(inInbox)
        try await shutdown(h)
    }

    @Test func sendLaterGoesOutFromTheServer() async throws {
        guard let h = try await harness(smtp: true) else { return }
        let subject = "Send later \(UUID().uuidString.prefix(6))"
        let message = OutgoingMessage(from: Self.me, to: [MailAddress(name: nil, address: "anna@example.dk")], subject: subject, text: "Hej")
        try await h.engine.schedule(id: "s1", PushAPI.ScheduledSend(account: h.login, sendAt: Date().addingTimeInterval(2), kind: .new, message: message))
        // A second one, cancelled in time, never goes out.
        try await h.engine.schedule(id: "s2", PushAPI.ScheduledSend(account: h.login, sendAt: Date().addingTimeInterval(60), kind: .new,
                                                                    message: OutgoingMessage(from: Self.me, to: [MailAddress(name: nil, address: "anna@example.dk")],
                                                                                             subject: subject + " cancelled", text: "Nej")))
        #expect(try await h.engine.cancelScheduled(id: "s2"))
        let search = URL(string: "http://127.0.0.1:38025/api/v1/search?query=\(subject.replacingOccurrences(of: " ", with: "%20"))")!
        #expect(try await h.waitFor(40) {
            let (data, _) = try await URLSession.shared.data(from: search)
            return String(decoding: data, as: UTF8.self).contains("\"messages_count\":1") || String(decoding: data, as: UTF8.self).contains("\"total\":1")
        })
        #expect(try await h.waitFor(10) { try await h.engine.status().scheduled == 0 })
        try await shutdown(h)
    }
}
