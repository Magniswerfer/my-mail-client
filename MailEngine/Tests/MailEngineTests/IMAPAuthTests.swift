import Foundation
import Synchronization
import Testing
@testable import MailEngine

/// Sign-in: both methods against the local Dovecot, and the diagnostics never showing secrets.
@Suite(.serialized) struct IMAPAuthTests {
    @Test(arguments: IMAPAuthMethod.allCases)
    func bothMethodsSignIn(_ method: IMAPAuthMethod) async throws {
        guard await IMAPIntegrationTests.serverAvailable else { return }
        try await MailSession.open(endpoint: IMAPIntegrationTests.endpoint, password: IMAPIntegrationTests.password,
                                   auth: method) { session in
            #expect(session.supports("IMAP4rev1"))
        }
    }

    @Test(arguments: IMAPAuthMethod.allCases)
    func aWrongPasswordIsAnAuthenticationFailure(_ method: IMAPAuthMethod) async throws {
        guard await IMAPIntegrationTests.serverAvailable else { return }
        do {
            try await MailSession.open(endpoint: IMAPIntegrationTests.endpoint, password: "not it", auth: method) { _ in }
            Issue.record("signed in with a wrong password")
        } catch let error as MailSessionError {
            #expect(error.description.contains("AUTHENTICATIONFAILED"))
        }
    }

    @Test func diagnosticsNeverContainThePassword() async throws {
        guard await IMAPIntegrationTests.serverAvailable else { return }
        let password = IMAPIntegrationTests.password
        let lines = Mutex<[String]>([])
        IMAPDiagnostics.echo = { line in lines.withLock { $0.append(line) } }
        defer { IMAPDiagnostics.echo = nil }
        for method in IMAPAuthMethod.allCases {
            try await MailSession.open(endpoint: IMAPIntegrationTests.endpoint, password: password, auth: method) { _ in }
        }
        let all = lines.withLock { $0.joined(separator: "\n") }
        #expect(all.contains("method=PLAIN"))
        #expect(!all.contains(password))
        // Nor the PLAIN payload, base64 or not.
        let payload = Data("\u{0}\(IMAPIntegrationTests.endpoint.username)\u{0}\(password)".utf8)
        #expect(!all.contains(payload.base64EncodedString()))
    }

    @Test func maskingAndShape() {
        #expect(IMAPDiagnostics.masked("magnus@creativeoak.dk") == "m•••s@creativeoak.dk")
        #expect(IMAPDiagnostics.masked("ab") == "••")
        #expect(IMAPDiagnostics.shape(of: "hunter2") == "plain ASCII")
        #expect(IMAPDiagnostics.shape(of: "hunter2 ").contains("WHITESPACE"))
        #expect(IMAPDiagnostics.shape(of: "pæssword").contains("non-ASCII"))
        #expect(IMAPDiagnostics.shape(of: "a\"b").contains("has"))
    }
}
