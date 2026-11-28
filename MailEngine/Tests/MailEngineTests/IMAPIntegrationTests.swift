import Foundation
import Testing
@testable import MailEngine

/// Runs against the local Dovecot container (MailEngine/TestServer). Skipped unless it is reachable.
/// Start it with: docker compose -f MailEngine/TestServer/compose.yml up -d
@Suite(.serialized) struct IMAPIntegrationTests {
    static let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "integration")
    static let password = "tidings-test"

    static var serverAvailable: Bool {
        get async {
            (try? await MailSession.probeGreeting(endpoint: endpoint)) != nil
        }
    }

    @Test func keywordTestPassesWithICloudQuirksSimulated() async throws {
        guard await Self.serverAvailable else { return }
        let report = try await KeywordTest(endpoint: Self.endpoint, password: Self.password,
                                           profile: .iCloudSimulation, capProbeLimit: 5).run()
        #expect(report.passed, "\(report.steps.filter { !$0.passed })")
    }

    @Test func simulationHidesMoveAndEnablesQresyncViaBareOK() async throws {
        guard await Self.serverAvailable else { return }
        try await MailSession.open(endpoint: Self.endpoint, password: Self.password, profile: .iCloudSimulation) { session in
            #expect(!session.supports("MOVE"))
            #expect(!session.supports("SPECIAL-USE"))
            #expect(session.supports("UIDPLUS"))
            #expect(session.qresyncEnabled)
        }
    }

    @Test func fenceRefusesToTouchRealMail() async throws {
        guard await Self.serverAvailable else { return }
        try await MailSession.open(endpoint: Self.endpoint, password: Self.password, profile: .iCloudSimulation) { session in
            let fence = TestFence(session: session)
            _ = try await fence.prepare()
            // A message without this run's marker, appended directly (simulating real mail).
            let foreign = try await session.append(to: TestFence.rootMailbox, message: Data("Subject: real\r\n\r\nreal mail\r\n".utf8))
            _ = try await session.select(TestFence.rootMailbox)
            let uid = try #require(foreign)
            await #expect(throws: TestFence.Violation.self) {
                try await fence.store(uids: [uid], in: TestFence.rootMailbox, .add, flags: ["\\Deleted"])
            }
            await #expect(throws: TestFence.Violation.self) {
                try await fence.move(uids: [uid], from: "INBOX", to: TestFence.rootMailbox)
            }
            await #expect(throws: TestFence.Violation.self) {
                try await fence.cleanUp(mailbox: "INBOX")
            }
            // Tidy up the foreign message outside the fence API (test server only).
            try await session.expunge(uids: [uid])
        }
    }

    @Test func fenceRefusesWhenTheNamedMailboxIsNotSelected() async throws {
        guard await Self.serverAvailable else { return }
        try await MailSession.open(endpoint: Self.endpoint, password: Self.password, profile: .iCloudSimulation) { session in
            let fence = TestFence(session: session)
            _ = try await fence.prepare()
            // A marked message outside the fence (test server only): naming the fenced mailbox
            // while INBOX is selected must not reach it.
            let stray = try await session.append(to: "INBOX", message: fence.syntheticMessage(subject: "stray"))
            _ = try await session.select("INBOX")
            let uid = try #require(stray)
            await #expect(throws: TestFence.Violation.self) {
                try await fence.store(uids: [uid], in: TestFence.rootMailbox, .add, flags: ["\\Flagged"])
            }
            try await session.expunge(uids: [uid])
        }
    }
}
