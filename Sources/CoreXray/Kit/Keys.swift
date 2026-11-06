import Foundation

// Age key pairs for encrypted subscription feeds.

/// Flavor of key pair. `hybrid` folds ML-KEM-768 over the classic
/// X25519 exchange, for feeds that support post-quantum resistance.
public enum XrayAgeKeyPairKind: String, Codable, Sendable {
    case x25519
    case hybrid
}

/// A fresh Age key pair: the secret stays on this device, the public half
/// goes to whoever exports encrypted feeds for you.
public struct XrayAgeKeyPair: Decodable, Sendable {

    /// Starts with "AGE-SECRET-KEY-"; keep it out of logs.
    public let secretKey: String

    /// Starts with "age1"; publishable.
    public let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case secretKey
        case publicKey
    }

}

extension Xray {

    /// Generates a key pair for Age-encrypted subscription exports: `.x25519`
    /// gives the classic pair, `.hybrid` folds ML-KEM-768 over it.
    public func generateAgeKeyPair(kind: XrayAgeKeyPairKind = .x25519) throws -> XrayAgeKeyPair {
        try KeyCalls.newKeys(kind: kind)
    }
}
