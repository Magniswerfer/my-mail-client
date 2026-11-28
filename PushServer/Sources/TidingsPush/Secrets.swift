import Crypto
import Foundation

/// Encrypts account passwords at rest (ADR 0007): AES-GCM under a master key that lives only
/// in the environment (a Coolify secret), so the database volume or a backup alone reveals
/// nothing.
public struct SecretBox: Sendable {
    let key: SymmetricKey

    /// `base64`: 32 random bytes, e.g. from `openssl rand -base64 32`.
    public init(base64 masterKey: String) throws {
        guard let data = Data(base64Encoded: masterKey.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
            throw ConfigError.invalid("TIDINGS_MASTER_KEY must be 32 bytes, base64 (openssl rand -base64 32)")
        }
        key = SymmetricKey(data: data)
    }

    public init(key: SymmetricKey) { self.key = key }

    /// `context` (the account's login) is authenticated with the ciphertext, so a sealed
    /// password only opens for the account it was sealed for: swapping blobs between rows in
    /// the database doesn't move a password to another account.
    public func seal(_ secret: String, context: String? = nil) throws -> Data {
        let sealed = try context.map { try AES.GCM.seal(Data(secret.utf8), using: key, authenticating: Data($0.utf8)) }
            ?? AES.GCM.seal(Data(secret.utf8), using: key)
        guard let combined = sealed.combined else { throw ConfigError.invalid("AES-GCM produced no output") }
        return combined
    }

    /// Opens with `context`; passwords sealed before contexts existed open without one.
    public func open(_ sealed: Data, context: String? = nil) throws -> String {
        let box = try AES.GCM.SealedBox(combined: sealed)
        if let context, let data = try? AES.GCM.open(box, using: key, authenticating: Data(context.utf8)) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self)
    }
}

/// Device tokens: random, shown once, stored only as a SHA-256.
enum Tokens {
    static func random(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let raw = (0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Which pairing secret a device paired under. Rotating `TIDINGS_PAIRING_SECRET` retires
    /// every device paired with the old one.
    static func secretTag(_ secret: String) -> String {
        String(hash("tidings-pairing-secret|" + secret).prefix(16))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares secrets without leaking where they differ (both are hashed first).
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(SHA256.hash(data: Data(given.utf8))), b = Array(SHA256.hash(data: Data(expected.utf8)))
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let name): "\(name) is not set"
        case .invalid(let message): message
        }
    }
}
