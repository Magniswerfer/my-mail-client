import Foundation
import IMAPCommands
import NIOCore
import NIOIMAP
import Synchronization

/// A mailbox as returned by LIST.
public struct MailboxListing: Sendable, Hashable {
    public var path: String
    public var separator: Character?
    public var attributes: [String]

    public init(path: String, separator: Character?, attributes: [String]) {
        self.path = path
        self.separator = separator
        self.attributes = attributes
    }
}

/// State reported by SELECT/EXAMINE.
public struct SelectedMailbox: Sendable, Hashable {
    public var path: String
    public var exists: Int = 0
    public var uidValidity: UInt32?
    public var uidNext: UInt32?
    public var highestModSeq: UInt64?
    public var flags: [String] = []
    public var permanentFlags: [String] = []
    /// `PERMANENTFLAGS` contains `\*`: the server claims to accept arbitrary keywords.
    public var acceptsArbitraryKeywords = false
    public var readOnly = false
}

public enum MailSessionError: Error, CustomStringConvertible {
    case commandFailed(command: String, detail: String)
    case authenticationFailed(String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let detail): "\(command) failed: \(detail)"
        case .authenticationFailed(let detail): "Login failed: \(detail)"
        }
    }
}

/// An authenticated IMAP session with the quirk handling from `ServerProfile`.
///
/// The underlying connection only lives inside `MailSession.open`, so a session must not
/// escape that closure.
public final class MailSession: Sendable {
    public let endpoint: IMAPEndpoint
    public let profile: ServerProfile
    public let greetingCapabilities: [String]
    public let capabilities: [String]
    private let connection: IMAPConnection

    private init(
        endpoint: IMAPEndpoint, profile: ServerProfile, connection: IMAPConnection,
        greetingCapabilities: [String], capabilities: [String]
    ) {
        self.endpoint = endpoint
        self.profile = profile
        self.connection = connection
        self.greetingCapabilities = greetingCapabilities
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains { $0.caseInsensitiveCompare(capability) == .orderedSame }
    }

    // MARK: Opening

    /// Connects without logging in and returns the greeting's capability list.
    public static func probeGreeting(endpoint: IMAPEndpoint) async throws -> [String] {
        let configuration = IMAPConnection.Configuration(
            hostname: endpoint.host, port: endpoint.port, useTLS: endpoint.useTLS, logging: .noLogging
        )
        return try await IMAPConnection.withConnection(configuration: configuration) { greeting, connection in
            var caps = Self.capabilities(in: greeting.status)
            if caps.isEmpty {
                caps = try await Self.fetchCapabilities(connection)
            }
            _ = try? await connection.send(.logout) { _, responses in try await responses.waitForCompletion() }
            return caps
        }
    }

    /// Connects, logs in, refreshes capabilities and enables CONDSTORE/QRESYNC when available.
    public static func open<Result: Sendable>(
        endpoint: IMAPEndpoint,
        password: String,
        profile: ServerProfile? = nil,
        _ body: (MailSession) async throws -> Result
    ) async throws -> Result {
        let profile = profile ?? ServerProfile.detect(host: endpoint.host)
        let configuration = IMAPConnection.Configuration(
            hostname: endpoint.host, port: endpoint.port, useTLS: endpoint.useTLS, logging: .noLogging
        )
        return try await IMAPConnection.withConnection(configuration: configuration) { greeting, connection in
            let greetingCaps = Self.capabilities(in: greeting.status)

            let login = try await connection.send(.login(username: endpoint.username, password: password)) {
                _, responses in try await responses.waitForCompletion()
            }
            if case .ok = login.state {} else {
                throw MailSessionError.authenticationFailed(String(describing: login.state))
            }

            // iCloud: the pre-auth list is minimal and the proxy needs a CAPABILITY after login.
            let caps = try await Self.fetchCapabilities(connection)
                .filter { !profile.ignoredCapabilities.contains($0.uppercased()) }
            let session = MailSession(
                endpoint: endpoint, profile: profile, connection: connection,
                greetingCapabilities: greetingCaps, capabilities: caps
            )
            try await session.enableExtensions()
            let result = try await body(session)
            _ = try? await connection.send(.logout) { _, responses in try await responses.waitForCompletion() }
            return result
        }
    }

    private static func capabilities(in status: UntaggedStatus) -> [String] {
        let text: ResponseText
        switch status {
        case .ok(let t), .preauth(let t), .no(let t), .bad(let t), .bye(let t): text = t
        }
        if case .capability(let caps) = text.code { return caps.map(Self.string(for:)) }
        return []
    }

    private static func fetchCapabilities(_ connection: IMAPConnection) async throws -> [String] {
        var caps: [String] = []
        let tagged = try await connection.send(.capability) { _, responses in
            var result: TaggedResponse?
            for try await response in responses {
                switch response {
                case .untagged(.capabilityData(let list)): caps = list.map(Self.string(for:))
                case .tagged(let t): result = t
                default: break
                }
            }
            return result
        }
        guard let tagged, case .ok = tagged.state else {
            throw MailSessionError.commandFailed(command: "CAPABILITY", detail: String(describing: tagged?.state))
        }
        return caps
    }

    static func string(for capability: Capability) -> String {
        capability.value.map { "\(capability.name)=\($0)" } ?? capability.name
    }

    /// Enables CONDSTORE/QRESYNC. iCloud answers with a bare OK (no `* ENABLED`),
    /// which `ServerProfile.enableOmitsEnabledResponse` tells us to accept.
    public private(set) var qresyncEnabled: Bool {
        get { _qresyncEnabled.withLock { $0 } }
        set { _qresyncEnabled.withLock { $0 = newValue } }
    }
    private let _qresyncEnabled = Mutex(false)

    /// The mailbox state from the most recent SELECT/EXAMINE on this session.
    public var selected: SelectedMailbox? { _selected.withLock { $0 } }
    private let _selected = Mutex<SelectedMailbox?>(nil)

    private func enableExtensions() async throws {
        guard supports("ENABLE"), supports("QRESYNC") || supports("CONDSTORE") else { return }
        var wanted: [Capability] = []
        if supports("CONDSTORE") { wanted.append(.condStore) }
        if supports("QRESYNC") { wanted.append(.qresync) }
        var confirmed = false
        let tagged = try await connection.send(.enable(wanted)) { _, responses in
            var result: TaggedResponse?
            for try await response in responses {
                switch response {
                case .untagged(.enableData(let enabled)):
                    confirmed = enabled.contains(.qresync) || enabled.contains(.condStore)
                case .tagged(let t): result = t
                default: break
                }
            }
            return result
        }
        if let tagged, case .ok = tagged.state {
            qresyncEnabled = confirmed || profile.enableOmitsEnabledResponse
        }
    }

    // MARK: Commands

    /// Sends a command, collecting all responses, and throws if the tagged response is not OK.
    @discardableResult
    func run(_ command: Command, name: String) async throws -> [Response] {
        var collected: [Response] = []
        let tagged = try await connection.send(command) { _, responses in
            var result: TaggedResponse?
            for try await response in responses {
                if case .tagged(let t) = response { result = t } else { collected.append(response) }
            }
            return result
        }
        guard let tagged else {
            throw MailSessionError.commandFailed(command: name, detail: "no tagged response")
        }
        guard case .ok = tagged.state else {
            throw MailSessionError.commandFailed(command: name, detail: String(describing: tagged.state))
        }
        return collected
    }

    /// `LIST "" "*"`. Must use the single-pattern form: `.pattern([...])` encodes as `("*")`,
    /// which is LIST-EXTENDED syntax. iCloud lacks LIST-EXTENDED and answers that with OK and
    /// zero mailboxes (found on the live server, 2026-11-24).
    static let listAllCommand: Command = .list(
        nil, reference: MailboxName(ByteBuffer(string: "")), .mailbox(ByteBuffer(string: "*"))
    )

    public func listMailboxes() async throws -> [MailboxListing] {
        let responses = try await run(Self.listAllCommand, name: "LIST")
        return responses.compactMap { response in
            guard case .untagged(.mailboxData(.list(let info))) = response else { return nil }
            let path = info.path.displayStringComponents().joined(separator: info.path.pathSeparator.map(String.init) ?? "/")
            return MailboxListing(
                path: path,
                separator: info.path.pathSeparator,
                attributes: info.attributes.map { String($0) }
            )
        }
    }

    public func select(_ path: String, readOnly: Bool = false) async throws -> SelectedMailbox {
        let name = MailboxName(ByteBuffer(string: path))
        var parameters: [SelectParameter] = []
        if qresyncEnabled == false, supports("CONDSTORE") { parameters.append(.condStore) }
        let responses = try await run(
            readOnly ? .examine(name, parameters) : .select(name, parameters),
            name: readOnly ? "EXAMINE" : "SELECT"
        )
        var state = SelectedMailbox(path: path, readOnly: readOnly)
        for response in responses {
            switch response {
            case .untagged(.mailboxData(.exists(let n))): state.exists = n
            case .untagged(.mailboxData(.flags(let flags))): state.flags = flags.map(String.init)
            case .untagged(.conditionalState(.ok(let text))):
                switch text.code {
                case .uidValidity(let v): state.uidValidity = UInt32(v)
                case .uidNext(let n): state.uidNext = n.rawValue
                case .highestModificationSequence(let m): state.highestModSeq = UInt64(m)
                case .permanentFlags(let flags):
                    for flag in flags {
                        switch flag {
                        case .flag(let f): state.permanentFlags.append(String(f))
                        case .wildcard:
                            state.permanentFlags.append("\\*")
                            state.acceptsArbitraryKeywords = true
                        }
                    }
                case .readOnly: state.readOnly = true
                default: break
                }
            default: break
            }
        }
        _selected.withLock { $0 = state }
        return state
    }

    public func create(_ path: String) async throws {
        try await run(.create(MailboxName(ByteBuffer(string: path)), []), name: "CREATE")
    }

    /// Creates the mailbox unless it already exists.
    public func ensureMailbox(_ path: String) async throws {
        let existing = try await listMailboxes()
        if existing.contains(where: { $0.path == path }) { return }
        try await create(path)
    }

    /// APPENDs a raw RFC 5322 message and returns its UID when the server reports one (UIDPLUS).
    public func append(to path: String, message: Data, flags: [String] = []) async throws -> UInt32? {
        let name = MailboxName(ByteBuffer(string: path))
        let flagList = flags.compactMap(Flag.init)
        let bytes = ByteBuffer(bytes: message)
        let appendMessage = AppendMessage(
            options: AppendOptions(flagList: flagList),
            data: AppendData(byteCount: bytes.readableBytes)
        )
        let state: TaggedResponse.State? = try await connection.append(
            to: name,
            writing: { _, writer in
                try await writer.write(message: appendMessage) { messageWriter in
                    try await messageWriter.write(messageBytes: bytes)
                }
            },
            reading: { _, responses in
                var result: TaggedResponse.State?
                for try await response in responses {
                    if case .tagged(let t) = response { result = t.state }
                }
                return result
            }
        )
        guard let state, case .ok(let text) = state else {
            throw MailSessionError.commandFailed(command: "APPEND", detail: String(describing: state))
        }
        if case .uidAppend(let code) = text.code { return code.uids.min().rawValue }
        return nil
    }

    /// `UID SEARCH HEADER <field> <value>` on the selected mailbox.
    /// - Warning: fails on iCloud (`NO [UNAVAILABLE]`); see `fetchHeaderField`.
    public func uidSearch(header field: String, contains value: String) async throws -> [UInt32] {
        let responses = try await run(
            .uidSearch(key: .header(field, ByteBuffer(string: value))), name: "UID SEARCH"
        )
        var uids: [UInt32] = []
        for response in responses {
            if case .untagged(.mailboxData(.search(let ids, _))) = response {
                uids.append(contentsOf: ids.map { UID($0).rawValue })
            }
        }
        return uids.sorted()
    }

    /// One header field's value per message, via `UID FETCH … BODY.PEEK[HEADER.FIELDS (field)]`.
    /// `uids == nil` means every message in the selected mailbox. Messages without the header
    /// map to an empty string.
    ///
    /// Use this instead of `uidSearch(header:)` on iCloud: `UID SEARCH HEADER` there fails with
    /// `NO [UNAVAILABLE] Unexpected exception` (live server, 2026-11-24).
    public func fetchHeaderField(_ field: String, uids: [UInt32]? = nil) async throws -> [UInt32: String] {
        let set: LastCommandSet<UID>
        if let uids {
            guard let s = Self.uidSet(uids) else { return [:] }
            set = s
        } else {
            if selected?.exists == 0 { return [:] }
            let all = MessageIdentifierSet<UID>(UID(rawValue: 1)...UID.max)
            set = .set(MessageIdentifierSetNonEmpty(set: all)!)
        }
        let section = SectionSpecifier(kind: .headerFields([field]))
        let responses = try await run(
            .uidFetch(set, [.uid, .bodySection(peek: true, section, nil)], []), name: "UID FETCH HEADER.FIELDS"
        )
        var result: [UInt32: String] = [:]
        var uid: UInt32?
        var bytes = ByteBuffer()
        for response in responses {
            guard case .fetch(let part) = response else { continue }
            switch part {
            case .start, .startUID:
                uid = nil
                bytes.clear()
                if case .startUID(let u) = part { uid = u.rawValue }
            case .simpleAttribute(.uid(let u)): uid = u.rawValue
            case .streamingBytes(var chunk): bytes.writeBuffer(&chunk)
            case .finish:
                if let uid { result[uid] = Self.headerValue(field, in: String(buffer: bytes)) }
            default: break
            }
        }
        return result
    }

    /// Extracts an unfolded header value from a raw header block.
    static func headerValue(_ field: String, in raw: String) -> String {
        let unfolded = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        for line in unfolded.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(field) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// `UID FETCH <uids> (UID FLAGS MODSEQ?)` on the selected mailbox.
    public func fetchFlags(uids: [UInt32]) async throws -> [UInt32: (flags: [String], modSeq: UInt64?)] {
        guard let set = Self.uidSet(uids) else { return [:] }
        var attributes: [FetchAttribute] = [.uid, .flags]
        if supports("CONDSTORE") { attributes.append(.modificationSequence) }
        let responses = try await run(.uidFetch(set, attributes, []), name: "UID FETCH")
        var result: [UInt32: (flags: [String], modSeq: UInt64?)] = [:]
        var currentUID: UInt32?
        var currentFlags: [String] = []
        var currentModSeq: UInt64?
        for response in responses {
            guard case .fetch(let part) = response else { continue }
            switch part {
            case .start, .startUID:
                currentUID = nil; currentFlags = []; currentModSeq = nil
                if case .startUID(let uid) = part { currentUID = uid.rawValue }
            case .simpleAttribute(.uid(let uid)): currentUID = uid.rawValue
            case .simpleAttribute(.flags(let flags)): currentFlags = flags.map(String.init)
            case .simpleAttribute(.fetchModificationSequence(let m)): currentModSeq = UInt64(m)
            case .finish:
                if let uid = currentUID { result[uid] = (currentFlags, currentModSeq) }
            default: break
            }
        }
        return result
    }

    public enum FlagChange: Sendable { case add, remove }

    public func store(uids: [UInt32], _ change: FlagChange, flags: [String]) async throws {
        guard let set = Self.uidSet(uids) else { return }
        let list = flags.compactMap(Flag.init)
        let data: StoreData = .flags(change == .add ? .add(silent: true, list: list) : .remove(silent: true, list: list))
        try await run(.uidStore(set, [], data), name: "UID STORE")
    }

    /// Moves messages. iCloud has no MOVE, so this falls back to COPY + \Deleted + UID EXPUNGE,
    /// which is safe to re-run: a crash after COPY leaves a duplicate, never a loss.
    public func move(uids: [UInt32], to destination: String) async throws {
        guard let set = Self.uidSet(uids) else { return }
        let target = MailboxName(ByteBuffer(string: destination))
        if supports("MOVE") {
            try await run(.uidMove(set, target), name: "UID MOVE")
            return
        }
        try await run(.uidCopy(set, target), name: "UID COPY")
        try await store(uids: uids, .add, flags: ["\\Deleted"])
        if supports("UIDPLUS") {
            try await run(.uidExpunge(set), name: "UID EXPUNGE")
        } else {
            throw MailSessionError.commandFailed(
                command: "MOVE", detail: "server has neither MOVE nor UIDPLUS; refusing a blanket EXPUNGE"
            )
        }
    }

    /// Permanently removes the given UIDs from the selected mailbox (requires UIDPLUS).
    public func expunge(uids: [UInt32]) async throws {
        guard let set = Self.uidSet(uids) else { return }
        guard supports("UIDPLUS") else {
            throw MailSessionError.commandFailed(command: "UID EXPUNGE", detail: "server lacks UIDPLUS")
        }
        try await store(uids: uids, .add, flags: ["\\Deleted"])
        try await run(.uidExpunge(set), name: "UID EXPUNGE")
    }

    static func uidSet(_ uids: [UInt32]) -> LastCommandSet<UID>? {
        let set = MessageIdentifierSet<UID>(uids.map { MessageIdentifierRange<UID>(UID(rawValue: $0)) })
        return MessageIdentifierSetNonEmpty(set: set).map { .set($0) }
    }
}
