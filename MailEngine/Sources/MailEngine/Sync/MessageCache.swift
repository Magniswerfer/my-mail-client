import Foundation

/// Tier 2 (ADR 0001): raw messages on disk, size-capped with least-recently-used eviction.
public struct MessageCache: Sendable {
    public let directory: URL
    public var limitBytes: Int

    public static let defaultLimitBytes = 2 << 30   // 2 GiB

    public init(directory: URL, limitBytes: Int = defaultLimitBytes) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(account: String, mailbox: String, validity: UInt32, uid: UInt32) -> URL {
        mailboxDirectory(account: account, mailbox: mailbox).appendingPathComponent("\(validity)-\(uid).eml")
    }

    func mailboxDirectory(account: String, mailbox: String) -> URL {
        let safeMailbox = mailbox.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "box"
        return directory.appendingPathComponent("\(account)/\(safeMailbox)")
    }

    public func read(account: String, mailbox: String, validity: UInt32, uid: UInt32) -> Data? {
        let url = url(account: account, mailbox: mailbox, validity: validity, uid: uid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // The modification date is the LRU clock `trim` evicts by.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func write(_ data: Data, account: String, mailbox: String, validity: UInt32, uid: UInt32) throws {
        let url = url(account: account, mailbox: mailbox, validity: validity, uid: uid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes every cached message of one account (it was removed).
    public func removeAccount(_ account: String) {
        guard Self.isSafePathComponent(account) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(account, isDirectory: true))
    }

    /// Evicts least-recently-used files until the cache fits `limitBytes`.
    public func trim() throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, lastUsed: Date)] = []
        var total = 0
        for case let url as URL in enumerator where url.pathExtension == "eml" {
            let values = try url.resourceValues(forKeys: Set(keys))
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > limitBytes else { return }
        for (url, size, _) in files.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= limitBytes { break }
        }
    }

    func renameMailbox(_ old: String, to new: String, account: String) {
        let from = mailboxDirectory(account: account, mailbox: old)
        let to = mailboxDirectory(account: account, mailbox: new)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    func removeMailbox(_ mailbox: String, account: String) {
        guard Self.isSafePathComponent(account) else { return }
        try? FileManager.default.removeItem(at: mailboxDirectory(account: account, mailbox: mailbox))
    }

    /// Deleting by account id must never reach outside the cache directory.
    private static func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != ".." && name != "."
    }
}
