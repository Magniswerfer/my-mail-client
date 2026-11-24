import Foundation
import IMAPCommands
import NIOCore
import NIOIMAP

/// Per-message metadata from a cheap FETCH (no bodies).
public struct MessageSummary: Sendable, Hashable {
    public var uid: UInt32
    public var flags: [String]
    public var size: Int
    public var internalDate: Date?
    public var modSeq: UInt64?
}

extension MailSession {
    /// `UID FETCH <uids|1:*> (UID FLAGS RFC822.SIZE INTERNALDATE [MODSEQ]) [(CHANGEDSINCE n)]`.
    public func fetchSummaries(uids: [UInt32]? = nil, changedSince: UInt64? = nil) async throws -> [MessageSummary] {
        guard let set = try allOrSome(uids) else { return [] }
        var attributes: [FetchAttribute] = [.uid, .flags, .rfc822Size, .internalDate]
        if supports("CONDSTORE") { attributes.append(.modificationSequence) }
        var modifiers: [FetchModifier] = []
        if let changedSince, supports("CONDSTORE") {
            modifiers.append(.changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue(changedSince))))
        }
        let responses = try await run(.uidFetch(set, attributes, modifiers), name: "UID FETCH summaries")

        var result: [MessageSummary] = []
        var current = MessageSummary(uid: 0, flags: [], size: 0)
        for response in responses {
            guard case .fetch(let part) = response else { continue }
            switch part {
            case .start, .startUID:
                current = MessageSummary(uid: 0, flags: [], size: 0)
                if case .startUID(let uid) = part { current.uid = uid.rawValue }
            case .simpleAttribute(let attribute):
                switch attribute {
                case .uid(let uid): current.uid = uid.rawValue
                case .flags(let flags): current.flags = flags.map(String.init)
                case .rfc822Size(let size): current.size = size
                case .internalDate(let date): current.internalDate = Self.date(from: date)
                case .fetchModificationSequence(let m): current.modSeq = UInt64(m)
                default: break
                }
            case .finish:
                if current.uid != 0 { result.append(current) }
            default: break
            }
        }
        return result
    }

    /// `UID FETCH <uids> BODY.PEEK[]<0.maxBytes>`. PEEK never sets \Seen.
    public func fetchRaw(uids: [UInt32], maxBytes: UInt32? = nil) async throws -> [UInt32: Data] {
        guard let set = Self.uidSet(uids) else { return [:] }
        let partial = maxBytes.map { UInt32(0)...($0 - 1) }
        let responses = try await run(
            .uidFetch(set, [.uid, .bodySection(peek: true, .complete, partial)], []), name: "UID FETCH BODY.PEEK[]"
        )
        var result: [UInt32: Data] = [:]
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
                if let uid { result[uid] = Data(bytes.readableBytesView) }
            default: break
            }
        }
        return result
    }

    /// IDLEs on the selected mailbox until the server reports a change, `wake` fires, or
    /// `timeout` passes. Returns true when something changed or local work is waiting.
    public func idle(timeout: Duration, wake: AsyncStream<Void>? = nil) async throws -> Bool {
        try await connection.sendIdle { _, responses in
            try await withThrowingTaskGroup(of: Bool.self) { group in
                if let wake {
                    // Local work (a triage action) ends IDLE early so it reaches the server promptly.
                    group.addTask {
                        for await _ in wake { return true }
                        return false
                    }
                }
                group.addTask {
                    for try await response in responses {
                        switch response {
                        case .untagged(.mailboxData(.exists)), .untagged(.messageData), .fetch:
                            return true
                        default: continue
                        }
                    }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return false
                }
                let changed = try await group.next() ?? false
                group.cancelAll()
                return changed
            }
        }
    }

    func allOrSome(_ uids: [UInt32]?) throws -> LastCommandSet<UID>? {
        if let uids { return Self.uidSet(uids) }
        if selected?.exists == 0 { return nil }
        return .set(MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<UID>(UID(rawValue: 1)...UID.max))!)
    }

    static func date(from server: ServerMessageDate) -> Date? {
        let c = server.components
        var components = DateComponents()
        components.year = c.year; components.month = c.month; components.day = c.day
        components.hour = c.hour; components.minute = c.minute; components.second = c.second
        components.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
