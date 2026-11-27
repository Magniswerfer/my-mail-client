import Foundation
import GRDB

// Signatures and the rules that pick them. In the store (not the app's preferences) because
// they hold images and sync through iCloud one record per signature (ADR 0006).

extension MailStore {
    static func registerSignatureMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v25-signatures") { db in
            try db.create(table: "signature") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .blob).notNull()
            }
            // One row ("settings"): defaults per address and the rules.
            try db.create(table: "signatureSettings") { t in
                t.column("key", .text).primaryKey()
                t.column("json", .blob).notNull()
            }
        }
    }

    /// In the order you keep them.
    public func signatures() throws -> [Signature] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM signature ORDER BY position, id").compactMap {
                try? CloudJSON.value(Signature.self, $0)
            }
        }
    }

    /// Replaces the whole ordered list.
    public func saveSignatures(_ signatures: [Signature]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM signature")
            for (position, signature) in signatures.enumerated() {
                try db.execute(sql: "INSERT INTO signature (id, position, json) VALUES (?, ?, ?)",
                               arguments: [signature.id, position, try CloudJSON.data(signature)])
            }
        }
    }

    public func signatureSettings() throws -> SignatureSettings {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM signatureSettings WHERE key = 'settings'")
                .flatMap { try? CloudJSON.value(SignatureSettings.self, $0) } ?? SignatureSettings()
        }
    }

    public func saveSignatureSettings(_ settings: SignatureSettings) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signatureSettings (key, json) VALUES ('settings', ?)",
                           arguments: [try CloudJSON.data(settings)])
        }
    }

    /// Once, for the plain-text signatures identities had before: each becomes a signature and
    /// its address's default. Ids follow from the text, so two devices doing this agree.
    /// Returns whether anything changed.
    @discardableResult
    public func adoptPlainTextSignatures(_ identities: [Identity]) throws -> Bool {
        var list = try signatures()
        var settings = try signatureSettings()
        var changed = false
        for identity in identities where !identity.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let converted = Signature.fromPlainText(identity.signature, name: identity.name.isEmpty ? identity.address : identity.name)
            if !list.contains(where: { $0.id == converted.id }) {
                list.append(converted)
                changed = true
            }
            if settings.defaults[identity.address.lowercased()] == nil {
                settings.setDefaults(SignatureDefaults(newMail: .signature(converted.id)), for: identity.address)
                changed = true
            }
        }
        if changed {
            try saveSignatures(list)
            try saveSignatureSettings(settings)
        }
        return changed
    }
}

/// A signature as it syncs (with its place in the list).
struct SignaturePayload: Codable { var position: Int; var signature: Signature }
