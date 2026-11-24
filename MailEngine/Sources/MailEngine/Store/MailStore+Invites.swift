import Foundation
import GRDB

/// Your answer to an invitation: from Tidings, or seen in Sent from another client.
public struct InviteResponse: Sendable, Codable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "inviteResponse"

    public var accountID: String
    public var uid: String
    /// The invite SEQUENCE answered; a later update (higher sequence) asks again.
    public var sequence: Int
    public var status: CalendarInvite.ParticipationStatus
    public var respondedAt: Date

    public init(accountID: String, uid: String, sequence: Int, status: CalendarInvite.ParticipationStatus, respondedAt: Date) {
        self.accountID = accountID
        self.uid = uid
        self.sequence = sequence
        self.status = status
        self.respondedAt = respondedAt
    }
}

extension CalendarInvite.ParticipationStatus: DatabaseValueConvertible {}

extension MailStore {
    static func registerInviteMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v10-invites") { db in
            try db.alter(table: "message") { t in
                t.add(column: "invite", .text)
                t.add(column: "inviteUID", .text)
            }
            try db.create(index: "message_inviteUID", on: "message", columns: ["inviteUID"])
            try db.create(table: "inviteResponse") { t in
                t.column("accountID", .text).notNull()
                t.column("uid", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("respondedAt", .datetime).notNull()
                t.primaryKey(["accountID", "uid"])
            }
        }
    }

    /// Keeps the newest answer per event; an older one (e.g. synced late from Sent) never
    /// overwrites a newer one.
    public func recordInviteResponse(_ response: InviteResponse) throws {
        try db.write { db in
            if let existing = try InviteResponse.fetchOne(db, key: ["accountID": response.accountID, "uid": response.uid]),
               existing.respondedAt > response.respondedAt {
                return
            }
            try response.save(db)
        }
    }

    /// Undo of an answer that never left the outbox.
    public func forgetInviteResponse(accountID: String, uid: String) throws {
        _ = try db.write { try InviteResponse.deleteOne($0, key: ["accountID": accountID, "uid": uid]) }
    }

    public func inviteResponse(accountID: String, uid: String) throws -> InviteResponse? {
        try db.read { try InviteResponse.fetchOne($0, key: ["accountID": accountID, "uid": uid]) }
    }

    /// Invitations in the inbox still waiting for your answer (for a badge or a smart folder).
    public func unansweredInvites(accountID: String, ownAddresses: Set<String>) throws -> [StoredMessage] {
        try db.read { db in
            let candidates = try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE accountID = ? AND mailbox = 'INBOX' AND invite IS NOT NULL ORDER BY date DESC
                """, arguments: [accountID])
            var seen = Set<String>()
            return try candidates.filter { message in
                guard let invite = message.invite, seen.insert(invite.uid).inserted,
                      invite.needsResponse(from: ownAddresses), invite.end.map({ $0 > Date() }) ?? true else { return false }
                let answered = try InviteResponse.fetchOne(db, key: ["accountID": accountID, "uid": invite.uid])
                return answered.map { $0.sequence < invite.sequence } ?? true
            }
        }
    }
}
