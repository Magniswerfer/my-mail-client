import Foundation
import GRDB

/// One attached file, for the attachment browser (SPEC §11).
public struct AttachmentEntry: Sendable, Hashable, Identifiable {
    public var messageLocalID: Int64
    public var threadID: String?
    public var accountID: String
    public var index: Int
    public var info: AttachmentInfo
    public var sender: String
    public var subject: String
    public var date: Date
    public var mailbox: String
    public var id: String { "\(messageLocalID)-\(index)" }
    public var filename: String { AttachmentNames.sanitize(info.filename ?? "attachment") }
}

extension MailStore {
    static func registerAttachmentMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v16-attachment-list") { db in
            try db.alter(table: "message") { t in t.add(column: "attachmentList", .text) }
            // Messages without attachments need no lookup.
            try db.execute(sql: "UPDATE message SET attachmentList = '[]' WHERE hasAttachments = 0")
        }
    }

    public func setAttachmentList(_ list: [AttachmentInfo], messageID id: Int64) throws {
        let json = String(decoding: try JSONEncoder().encode(list.filter { !$0.isInline }), as: UTF8.self)
        try db.write { try $0.execute(sql: "UPDATE message SET attachmentList = ? WHERE id = ?", arguments: [json, id]) }
    }

    /// Messages with attachments whose list isn't known yet, newest first.
    func messagesMissingAttachmentList(accountID: String, limit: Int) throws -> [StoredMessage] {
        try db.read {
            try StoredMessage.fetchAll($0, sql: """
                SELECT * FROM message WHERE accountID = ? AND hasAttachments = 1 AND attachmentList IS NULL
                ORDER BY date DESC LIMIT ?
                """, arguments: [accountID, limit])
        }
    }

    /// Every known attachment, newest first; not in Drafts, Trash or Junk.
    public func attachmentEntries(limit: Int = 3000) throws -> [AttachmentEntry] {
        let messages = try db.read {
            try StoredMessage.fetchAll($0, sql: """
                SELECT * FROM message WHERE hasAttachments = 1 AND attachmentList IS NOT NULL AND attachmentList != '[]'
                  AND mailbox NOT IN (SELECT path FROM mailboxState WHERE role IN ('drafts', 'trash', 'junk'))
                ORDER BY date DESC LIMIT ?
                """, arguments: [limit])
        }
        var seen = Set<String>()
        return messages.flatMap { m -> [AttachmentEntry] in
            // The same message in two folders (e.g. Inbox and Archive copies): list it once.
            guard let id = m.id, seen.insert(m.messageID ?? "\(id)").inserted else { return [] }
            return (m.attachmentList ?? []).enumerated().map { index, info in
                AttachmentEntry(messageLocalID: id, threadID: m.threadID, accountID: m.accountID, index: index, info: info,
                                sender: m.fromName ?? m.fromAddress, subject: m.subject, date: m.date, mailbox: m.mailbox)
            }
        }
    }
}

extension AccountSync {
    /// Fills in attachment lists from cached messages (no network), a batch at a time.
    @discardableResult
    public func indexAttachmentsFromCache(limit: Int = 300) throws -> Int {
        let states = try store.mailboxStates(accountID: account.id)
        var done = 0
        for message in try store.messagesMissingAttachmentList(accountID: account.id, limit: limit) {
            guard let id = message.id else { continue }
            let validity = UInt32(states.first { $0.path == message.mailbox }?.uidValidity ?? 0)
            guard let raw = cache.read(account: account.id, mailbox: message.mailbox, validity: validity, uid: message.uid) else { continue }
            try store.setAttachmentList(MIMEParser.parse(raw).attachments, messageID: id)
            done += 1
        }
        return done
    }
}

extension MIMEParser {
    /// The bytes of a listed attachment: same file name, closest size (a message can carry
    /// two files with one name, and inline images sit in the same MIME tree).
    public static func attachmentFile(_ info: AttachmentInfo, in raw: Data) -> OutgoingAttachment? {
        // Lists stored before names were sanitized hold the raw name: compare sanitized.
        let name = AttachmentNames.sanitize(info.filename ?? "attachment")
        return attachments(in: raw)
            .filter { AttachmentNames.sanitize($0.filename) == name }
            .min { abs($0.data.count - info.size) < abs($1.data.count - info.size) }
    }
}
