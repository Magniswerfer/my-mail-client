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

    public func seal(_ secret: String) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(secret.utf8), using: key).combined else {
            throw ConfigError.invalid("AES-GCM produced no output")
        }
        return combined
    }

    public func open(_ sealed: Data) throws -> String {
        String(decoding: try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key), as: UTF8.self)
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
