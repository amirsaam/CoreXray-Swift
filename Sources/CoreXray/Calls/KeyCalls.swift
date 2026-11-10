import Foundation

// Age key generation for encrypted subscription feeds. One call, no
// validation is needed. The Kit layer (`Kit/Keys.swift`) only names it.

internal final class KeyCalls {
    /// Never instantiated: all members are static.
    private init() {}

    internal static func newKeys(kind: XrayAgeKeyPairKind) throws -> XrayAgeKeyPair {
        try EngineTransport.ask(.newAgeKeys, payload: Xray.AgeKindChoice(kind: kind), as: XrayAgeKeyPair.self)
    }
}

extension Xray {
    internal struct AgeKindChoice: Encodable, Sendable {
        let kind: XrayAgeKeyPairKind

        enum CodingKeys: String, CodingKey {
            case kind = "keyType"
        }
    }
}
