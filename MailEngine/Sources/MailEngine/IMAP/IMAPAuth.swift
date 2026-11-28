import Foundation
import IMAPCommands
import NIOCore
import NIOIMAP

/// How a session signs in.
public enum IMAPAuthMethod: String, Sendable, CaseIterable {
    /// `LOGIN user pass`: quoted strings, or literals for non-ASCII and long values.
    case login
    /// `AUTHENTICATE PLAIN`: base64(NUL user NUL pass), in the command when the server has
    /// SASL-IR, otherwise in answer to its `+` challenge.
    case plain
}

/// Sanitized sign-in diagnostics: the host, TLS, capabilities, the method, what the server
/// said, and the shape of the credentials. Never a password or an encoded payload.
public enum IMAPDiagnostics {
    /// Also hand each line here (tidings-probe prints them). The unified log gets them anyway.
    nonisolated(unsafe) public static var echo: (@Sendable (String) -> Void)?

    static func log(_ line: String) {
        SyncLog.imap(line)
        echo?(line)
    }

    /// `magnus@creativeoak.dk` → `m•••s@creativeoak.dk`: enough to spot a wrong account or a
    /// stray character, not the whole address.
    public static func masked(_ username: String) -> String {
        let parts = username.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let local = String(parts[0])
        let shown = local.count <= 2 ? String(repeating: "•", count: local.count)
            : "\(local.first!)•••\(local.last!)"
        return parts.count == 2 ? "\(shown)@\(parts[1])" : shown
    }

    /// What can go wrong with a credential without saying what it is: whitespace at the ends
    /// (a paste), non-ASCII characters (sent as a literal or in UTF-8), characters LOGIN quotes,
    /// and whether it's long enough to be sent as a literal.
    public static func shape(of value: String) -> String {
        var notes: [String] = []
        if value != value.trimmingCharacters(in: .whitespacesAndNewlines) { notes.append("WHITESPACE AT START OR END") }
        if value.contains(where: { $0.isNewline }) { notes.append("CONTAINS A LINE BREAK") }
        if !value.allSatisfy(\.isASCII) { notes.append("non-ASCII") }
        if value.contains(where: { $0 == "\"" || $0 == "\\" }) { notes.append("has \" or \\") }
        if value.utf8.count > 70 { notes.append("over 70 bytes") }
        if value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { notes.append("CONTROL CHARACTERS") }
        return notes.isEmpty ? "plain ASCII" : notes.joined(separator: ", ")
    }
}

extension MailSession {
    /// Signs in on an open connection. Throws `authenticationFailed` with the server's words.
    static func authenticate(_ connection: IMAPConnection, endpoint: IMAPEndpoint, password: String,
                             method: IMAPAuthMethod, capabilities: [String]) async throws {
        let has = { (cap: String) in capabilities.contains { $0.caseInsensitiveCompare(cap) == .orderedSame } }
        IMAPDiagnostics.log("""
            auth: method=\(method.rawValue.uppercased()) user=\(IMAPDiagnostics.masked(endpoint.username)) \
            user shape=\(IMAPDiagnostics.shape(of: endpoint.username)) password shape=\(IMAPDiagnostics.shape(of: password)) \
            server offers LOGIN=\(has("LOGINDISABLED") ? "no (LOGINDISABLED)" : "yes") AUTH=PLAIN=\(has("AUTH=PLAIN") ? "yes" : "no") SASL-IR=\(has("SASL-IR") ? "yes" : "no")
            """)
        let tagged: TaggedResponse
        switch method {
        case .login where has("LOGINDISABLED"):
            // RFC 3501: the server forbids LOGIN here (usually: no TLS yet). Don't send it anyway.
            throw MailSessionError.authenticationFailed("the server doesn't allow LOGIN on this connection (LOGINDISABLED)")
        case .login:
            tagged = try await connection.send(.login(username: endpoint.username, password: password)) { _, responses in
                try await Self.collect(responses)
            }
        case .plain:
            // RFC 4616: [authzid] NUL authcid NUL passwd, UTF-8; no authorization identity.
            var payload = ByteBuffer()
            payload.writeInteger(UInt8(0))
            payload.writeString(endpoint.username)
            payload.writeInteger(UInt8(0))
            payload.writeString(password)
            if has("SASL-IR") {
                tagged = try await connection.sendAuthenticate(mechanism: .plain, initialResponse: InitialResponse(payload)) { _, responses, _ in
                    try await Self.collect(responses)
                }
            } else {
                // No SASL-IR: wait for the server's empty challenge, then answer it.
                tagged = try await connection.sendAuthenticate(mechanism: .plain, initialResponse: nil) { _, responses, writer in
                    var result: TaggedResponse?
                    var answered = false
                    for try await response in responses {
                        switch response {
                        case .authenticationChallenge where !answered:
                            answered = true
                            IMAPDiagnostics.log("auth: server sent a challenge; answering with the PLAIN response")
                            let encoded = Base64Encoding.encode(Array(payload.readableBytesView))
                            try await writer.writeContinuation(Array(encoded.utf8))
                        case .tagged(let t): result = t
                        case .untagged(let u): IMAPDiagnostics.log("auth: untagged \(Self.sanitized(u))")
                        default: break
                        }
                    }
                    guard let result else { throw MailSessionError.authenticationFailed("no answer from the server") }
                    return result
                }
            }
        }
        IMAPDiagnostics.log("auth: server answered \(Self.sanitized(tagged.state))")
        guard case .ok = tagged.state else {
            throw MailSessionError.authenticationFailed(String(describing: tagged.state))
        }
    }

    /// The tagged answer, logging untagged lines on the way (they carry no secrets).
    private static func collect(_ responses: IMAPConnection.ResponseStream) async throws -> TaggedResponse {
        var result: TaggedResponse?
        for try await response in responses {
            switch response {
            case .tagged(let t): result = t
            case .untagged(let u): IMAPDiagnostics.log("auth: untagged \(sanitized(u))")
            default: break
            }
        }
        guard let result else { throw MailSessionError.authenticationFailed("no answer from the server") }
        return result
    }

    /// Server text, one line and bounded: it never contains what we sent.
    static func sanitized(_ value: some Any) -> String {
        String(String(describing: value).prefix(300)).replacingOccurrences(of: "\r\n", with: " ")
    }
}

/// Plain base64 (RFC 4648), for SASL continuation answers.
enum Base64Encoding {
    static func encode(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
}
