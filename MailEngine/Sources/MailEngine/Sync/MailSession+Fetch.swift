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

/// A set of UIDs as the server sends it (`1:500,512`), without expanding the ranges:
/// `VANISHED (EARLIER)` may name UIDs we never had.
public struct UIDRanges: Sendable, Hashable {
    /// Sorted, non-overlapping.
    public private(set) var ranges: [ClosedRange<UInt32>]

    public init(_ ranges: [ClosedRange<UInt32>] = []) {
        var merged: [ClosedRange<UInt32>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound == .max || range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        self.ranges = merged
    }

    init(_ set: UIDSet) {
        self.init(set.ranges.map { $0.range.lowerBound.rawValue...$0.range.upperBound.rawValue })
    }

    public var isEmpty: Bool { ranges.isEmpty }
    public var count: Int { ranges.reduce(0) { $0 + $1.count } }

    public func contains(_ uid: UInt32) -> Bool {
        var low = 0, high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < uid { low = mid + 1 }
            else if ranges[mid].lowerBound > uid { high = mid - 1 }
            else { return true }
        }
        return false
    }

    public mutating func formUnion(_ other: UIDRanges) { self = UIDRanges(ranges + other.ranges) }
}

/// What changed in the selected mailbox since a MODSEQ (`UID FETCH 1:* … (CHANGEDSINCE n [VANISHED])`).
public struct MailboxChanges: Sendable {
    /// New messages and messages whose flags changed.
    public var summaries: [MessageSummary]
    /// Expunged since then (QRESYNC only; may name UIDs never seen). Nil when not asked for.
    public var vanished: UIDRanges?
    /// The message count after the command (EXISTS updates that arrived with it).
    public var exists: Int?
}

extension MailSession {
    /// `UID FETCH <uids|1:*> (UID FLAGS RFC822.SIZE INTERNALDATE [MODSEQ]) [(CHANGEDSINCE n)]`.
    public func fetchSummaries(uids: [UInt32]? = nil, changedSince: UInt64? = nil) async throws -> [MessageSummary] {
        guard let set = try allOrSome(uids) else { return [] }
        var modifiers: [FetchModifier] = []
        if let changedSince, supports("CONDSTORE") {
            modifiers.append(.changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue(changedSince))))
        }
        let responses = try await run(.uidFetch(set, summaryAttributes, modifiers), name: "UID FETCH summaries")
        noteExists(in: responses)
        return Self.summaries(in: responses)
    }

    /// Everything that changed since `modSeq`, in one round trip: new messages, flag changes and,
    /// with `vanished` (QRESYNC enabled), expunges. RFC 7162 §3.1.4.1 and §3.2.6.
    public func fetchChanges(since modSeq: UInt64, vanished: Bool) async throws -> MailboxChanges {
        var changes = MailboxChanges(summaries: [], vanished: vanished ? UIDRanges() : nil)
        guard let set = try allOrSome(nil) else {
            changes.exists = 0
            return changes
        }
        var modifiers: [FetchModifier] = [
            .changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue(modSeq)))
        ]
        if vanished { modifiers.append(.other(KeyValue(key: "VANISHED", value: nil))) }
        let responses = try await run(.uidFetch(set, summaryAttributes, modifiers),
                                      name: vanished ? "UID FETCH CHANGEDSINCE VANISHED" : "UID FETCH CHANGEDSINCE")
        changes.summaries = Self.summaries(in: responses)
        for response in responses {
            switch response {
            case .untagged(.messageData(.vanishedEarlier(let set))), .untagged(.messageData(.vanished(let set))):
                changes.vanished?.formUnion(UIDRanges(set))
            default: break
            }
        }
        changes.exists = noteExists(in: responses)
        return changes
    }

    /// Every UID in the selected mailbox: `UID SEARCH RETURN (ALL) ALL` where ESEARCH gives a
    /// compact `1:500,512` answer, else plain `UID SEARCH ALL`.
    public func allUIDs() async throws -> UIDRanges {
        if selected?.exists == 0 { return UIDRanges() }
        if supports("ESEARCH") {
            let responses = try await run(.uidSearch(key: .all, returnOptions: [.all]), name: "UID SEARCH RETURN (ALL)")
            var result = UIDRanges()
            for response in responses {
                if case .untagged(.mailboxData(.extendedSearch(let found))) = response, let uids = found.matchedUIDs {
                    result.formUnion(UIDRanges(uids))
                }
            }
            return result
        }
        let responses = try await run(.uidSearch(key: .all), name: "UID SEARCH ALL")
        var uids: [UInt32] = []
        for response in responses {
            if case .untagged(.mailboxData(.search(let ids, _))) = response {
                uids.append(contentsOf: ids.map { UID($0).rawValue })
            }
        }
        return UIDRanges(uids.map { $0...$0 })
    }

    private var summaryAttributes: [FetchAttribute] {
        var attributes: [FetchAttribute] = [.uid, .flags, .rfc822Size, .internalDate]
        if supports("CONDSTORE") { attributes.append(.modificationSequence) }
        return attributes
    }

    /// Keeps `selected.exists` current from the EXISTS, EXPUNGE and VANISHED updates that
    /// arrive with a command's answer.
    @discardableResult
    func noteExists(in responses: [Response]) -> Int? {
        guard var exists = selected?.exists else { return nil }
        var changed = false
        for response in responses {
            switch response {
            case .untagged(.mailboxData(.exists(let n))): exists = n
            case .untagged(.messageData(.expunge)): exists -= 1
            case .untagged(.messageData(.vanished(let set))): exists -= set.count
            default: continue
            }
            changed = true
        }
        let current = max(0, exists)
        if changed { _selected.withLock { $0?.exists = current } }
        return current
    }

    static func summaries(in responses: [Response]) -> [MessageSummary] {
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
