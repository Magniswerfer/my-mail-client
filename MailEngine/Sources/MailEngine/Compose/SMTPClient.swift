import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Outgoing server settings.
public struct SMTPEndpoint: Sendable, Hashable, Codable {
    public enum Security: String, Sendable, Codable { case startTLS, tls, none }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String
    /// Tests only: accept a self-signed certificate, and only when `host` is localhost.
    public var allowSelfSignedLocalhost = false

    public init(host: String, port: Int, security: Security, username: String, allowSelfSignedLocalhost: Bool = false) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.allowSelfSignedLocalhost = allowSelfSignedLocalhost
    }

    /// iCloud: STARTTLS on 587 only (465/25 are closed), login with the full address.
    public static func iCloud(address: String) -> SMTPEndpoint {
        SMTPEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS, username: address)
    }

    var isLocalhost: Bool { host == "127.0.0.1" || host == "localhost" || host == "::1" }
}

public struct SMTPResponse: Sendable, CustomStringConvertible {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: "\n") }
    public var description: String { "\(code) \(text)" }
}

public enum SMTPError: Error, CustomStringConvertible, Equatable {
    case rejected(command: String, code: Int, message: String)
    case authenticationFailed(String)
    case tooLarge(size: Int, limit: Int)
    case startTLSUnavailable
    case connectionClosed
    case notSMTP(String)
    case timeout

    public var description: String {
        switch self {
        case .rejected(let command, let code, let message): "\(command) was rejected (\(code)): \(message)"
        case .authenticationFailed(let message): "The mail server rejected the login: \(message)"
        case .tooLarge(let size, let limit): "The message is \(size / 1_048_576) MB; the server accepts at most \(limit / 1_048_576) MB."
        case .startTLSUnavailable: "The server doesn't offer an encrypted connection (STARTTLS); refusing to send the password in the clear."
        case .connectionClosed: "The mail server closed the connection."
        case .notSMTP(let line): "That server doesn't speak SMTP (it said \"\(line.prefix(60))\")."
        case .timeout: "The mail server stopped responding."
        }
    }

    /// 4xx replies and dropped connections are worth retrying; 5xx are not.
    public var isTransient: Bool {
        switch self {
        case .rejected(_, let code, _): (400..<500).contains(code)
        case .connectionClosed, .timeout: true
        default: false
        }
    }
}

/// A minimal ESMTP submission client (RFC 5321 / 3207 / 4954).
public enum SMTPClient {
    /// Delivers one message. Returns the server's final reply (often a queue id).
    @discardableResult
    public static func send(endpoint: SMTPEndpoint, password: String, from: String, recipients: [String], message: Data) async throws -> SMTPResponse {
        let connection = try await SMTPConnection.connect(endpoint)
        do {
            let response = try await connection.deliver(endpoint: endpoint, password: password, from: from,
                                                        recipients: recipients, message: message)
            _ = try? await connection.command("QUIT")
            try? await connection.close()
            return response
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Opens a connection and authenticates without sending anything (account setup check).
    public static func verify(endpoint: SMTPEndpoint, password: String) async throws {
        let connection = try await SMTPConnection.connect(endpoint)
        defer { Task { try? await connection.close() } }
        _ = try await connection.handshake(endpoint: endpoint, password: password)
        _ = try? await connection.command("QUIT")
    }

    /// Dot-stuffs and terminates the DATA payload, normalizing line endings to CRLF.
    static func dataPayload(_ message: Data) -> ByteBuffer {
        var text = String(decoding: message, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        return ByteBuffer(string: text + ".\r\n")
    }
}

final class SMTPConnection: Sendable {
    let channel: any Channel
    let decoder: NIOLoopBound<SMTPResponseDecoder>

    private init(channel: any Channel, decoder: NIOLoopBound<SMTPResponseDecoder>) {
        self.channel = channel
        self.decoder = decoder
    }

    static func connect(_ endpoint: SMTPEndpoint) async throws -> SMTPConnection {
        let tlsContext = try makeTLSContext(endpoint)
        let host = endpoint.host
        let immediateTLS = endpoint.security == .tls
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if immediateTLS {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: tlsContext, serverHostname: SMTPConnection.sniHost(host)))
                    }
                    try channel.pipeline.syncOperations.addHandler(SMTPResponseDecoder())
                }
            }
            .connect(host: endpoint.host, port: endpoint.port)
            .get()
        let decoder = try await channel.eventLoop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: SMTPResponseDecoder.self), eventLoop: channel.eventLoop)
        }.get()
        return SMTPConnection(channel: channel, decoder: decoder)
    }

    static func makeTLSContext(_ endpoint: SMTPEndpoint) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        if endpoint.allowSelfSignedLocalhost, endpoint.isLocalhost {
            configuration.certificateVerification = .none
        }
        return try NIOSSLContext(configuration: configuration)
    }

    /// SNI must be a hostname, never an IP literal.
    static func sniHost(_ host: String) -> String? {
        host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" } ? nil : host
    }

    // MARK: Protocol

    func handshake(endpoint: SMTPEndpoint, password: String) async throws -> [String] {
        let greeting = try await response()
        guard greeting.code == 220 else { throw SMTPError.rejected(command: "greeting", code: greeting.code, message: greeting.text) }
        var extensions = try await ehlo()

        if endpoint.security == .startTLS {
            guard extensions.contains(where: { $0.uppercased() == "STARTTLS" }) else { throw SMTPError.startTLSUnavailable }
            let reply = try await command("STARTTLS")
            guard reply.code == 220 else { throw SMTPError.rejected(command: "STARTTLS", code: reply.code, message: reply.text) }
            let context = try Self.makeTLSContext(endpoint)
            let host = endpoint.host
            let channel = self.channel
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: Self.sniHost(host)), position: .first)
            }.get()
            extensions = try await ehlo()   // capabilities must be re-read after TLS (RFC 3207)
        }

        let auth = extensions.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased().split(separator: " ").map(String.init) ?? []
        if auth.contains("PLAIN") {
            let token = Data("\0\(endpoint.username)\0\(password)".utf8).base64EncodedString()
            let reply = try await command("AUTH PLAIN \(token)", redacted: "AUTH PLAIN ***")
            guard reply.code == 235 else { throw SMTPError.authenticationFailed(reply.text) }
        } else if auth.contains("LOGIN") {
            var reply = try await command("AUTH LOGIN")
            guard reply.code == 334 else { throw SMTPError.authenticationFailed(reply.text) }
            reply = try await command(Data(endpoint.username.utf8).base64EncodedString(), redacted: "***")
            guard reply.code == 334 else { throw SMTPError.authenticationFailed(reply.text) }
            reply = try await command(Data(password.utf8).base64EncodedString(), redacted: "***")
            guard reply.code == 235 else { throw SMTPError.authenticationFailed(reply.text) }
        }
        return extensions
    }

    func deliver(endpoint: SMTPEndpoint, password: String, from: String, recipients: [String], message: Data) async throws -> SMTPResponse {
        let extensions = try await handshake(endpoint: endpoint, password: password)
        if let size = extensions.first(where: { $0.uppercased().hasPrefix("SIZE ") }).flatMap({ Int($0.split(separator: " ")[1]) }),
           size > 0, message.count > size {
            throw SMTPError.tooLarge(size: message.count, limit: size)
        }
        try await expect(250, "MAIL FROM:<\(from)>")
        var accepted = 0
        var lastRejection: SMTPResponse?
        for recipient in recipients {
            let reply = try await command("RCPT TO:<\(recipient)>")
            if reply.code == 250 || reply.code == 251 { accepted += 1 } else { lastRejection = reply }
        }
        // Partial delivery is surprising for mail; refuse unless every recipient was accepted.
        if let lastRejection {
            _ = try? await command("RSET")
            throw SMTPError.rejected(command: "RCPT TO", code: lastRejection.code, message: lastRejection.text)
        }
        guard accepted > 0 else { throw SMTPError.rejected(command: "RCPT TO", code: 0, message: "no recipients") }
        try await expect(354, "DATA")
        try await channel.writeAndFlush(SMTPClient.dataPayload(message))
        let final = try await response(timeout: .minutes(5))   // big attachments take a while to accept
        guard final.code == 250 else { throw SMTPError.rejected(command: "DATA", code: final.code, message: final.text) }
        return final
    }

    func ehlo() async throws -> [String] {
        #if os(macOS)
        let name = Host.current().localizedName.map { $0.replacingOccurrences(of: " ", with: "-") } ?? "tidings"
        #else
        // No host-name API on iOS (or a server); an address literal is valid and reveals nothing.
        let name = "[127.0.0.1]"
        #endif
        let reply = try await command("EHLO \(name.isEmpty ? "tidings" : name)")
        guard reply.code == 250 else { throw SMTPError.rejected(command: "EHLO", code: reply.code, message: reply.text) }
        return Array(reply.lines.dropFirst())
    }

    @discardableResult
    func expect(_ code: Int, _ line: String) async throws -> SMTPResponse {
        let reply = try await command(line)
        guard reply.code == code else {
            throw SMTPError.rejected(command: String(line.prefix(while: { $0 != ":" && $0 != " " })), code: reply.code, message: reply.text)
        }
        return reply
    }

    func command(_ line: String, redacted: String? = nil) async throws -> SMTPResponse {
        try await channel.writeAndFlush(ByteBuffer(string: line + "\r\n"))
        return try await response()
    }

    /// Waits for the next reply. Every wait is bounded so a silent server can't hang a send.
    func response(timeout: TimeAmount = .seconds(60)) async throws -> SMTPResponse {
        let promise = channel.eventLoop.makePromise(of: SMTPResponse.self)
        let decoder = self.decoder
        let channel = self.channel
        channel.eventLoop.execute { decoder.value.next(promise) }
        let timer = channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(SMTPError.timeout)
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        return try await promise.futureResult.get()
    }

    func close() async throws {
        try await channel.close()
    }
}

/// Turns bytes into SMTP replies ("250-a", "250-b", "250 c" → one reply) and hands them to
/// waiting callers in order.
final class SMTPResponseDecoder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var buffer = ByteBuffer()
    private var pendingLines: [String] = []
    private var waiting = CircularBuffer<EventLoopPromise<SMTPResponse>>()
    private var ready = CircularBuffer<SMTPResponse>()
    private var failure: (any Error)?

    func next(_ promise: EventLoopPromise<SMTPResponse>) {
        if let response = ready.popFirst() { promise.succeed(response) }
        else if let failure { promise.fail(failure) }
        else { waiting.append(promise) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let range = buffer.readableBytesView.firstRange(of: [13, 10]) {
            let length = range.lowerBound - buffer.readableBytesView.startIndex
            let line = buffer.readString(length: length) ?? ""
            buffer.moveReaderIndex(forwardBy: 2)
            handle(line)
        }
        buffer.discardReadBytes()
    }

    private func handle(_ line: String) {
        guard line.count >= 3, let code = Int(line.prefix(3)) else {
            fail(SMTPError.notSMTP(line))
            return
        }
        let rest = line.dropFirst(3)
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        pendingLines.append(text)
        if rest.first == "-" { return }  // continuation
        let response = SMTPResponse(code: code, lines: pendingLines)
        pendingLines = []
        if let promise = waiting.popFirst() { promise.succeed(response) } else { ready.append(response) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SMTPError.connectionClosed)
        context.fireChannelInactive()
    }

    private func fail(_ error: any Error) {
        failure = failure ?? error
        while let promise = waiting.popFirst() { promise.fail(error) }
    }
}
