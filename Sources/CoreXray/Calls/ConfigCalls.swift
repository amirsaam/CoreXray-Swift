import Foundation

// Share-link conversion both ways, config validation, and subscription
// unwrapping. Entries the engine cannot build are dropped inside the engine;
// the "no valid outbound" failure surfaces as `.engineFailed` here and is
// reworded by the friendly layer.

internal final class ConfigCalls {
    /// Never instantiated: all members are static.
    private init() {}

    internal static func convert(shareLinks: String, ageSecret: String?) throws -> String {
        let value = try EngineTransport.resolved(
            EngineTransport.envelope(
                of: try EngineTransport.send(
                    .configFromShareLinks,
                    payload: Xray.TextSnapshot(text: shareLinks, ageSecret: ageSecret)
                ),
                as: XrayJSONValue.self
            )
        )
        guard case .object = value else {
            throw XrayError.bridgeFailed("engine answered with a document instead of a configuration")
        }
        return try EngineTransport.serialize(value)
    }

    internal static func links(from json: String) throws -> String {
        // Strict: an answer without links is a broken answer, and an
        // empty string back would look like "no routable outbounds".
        try EngineTransport.ask(
            .shareLinksFromConfig,
            payload: Xray.ConfigPayload(xrayJson: json),
            as: Xray.LinkList.self
        ).links
    }

    internal static func check(json: String) throws {
        try EngineTransport.acknowledge(.checkConfig, payload: Xray.ConfigPayload(xrayJson: json))
    }

    internal static func decodeText(_ text: String, ageSecret: String?) throws -> String {
        try EngineTransport.ask(
            .decodeSubscription,
            payload: Xray.TextSnapshot(text: text, ageSecret: ageSecret),
            as: Xray.TextSnapshot.self
        ).text
    }
}

extension Xray {
    internal struct TextSnapshot: Codable, Sendable {
        let text: String
        let age: AgeSecret?

        init(text: String, ageSecret: String?) {
            self.text = text
            // An empty secret is no secret: normalize it to nil so the
            // wire carries either a real secret or no `age` key at all,
            // never two needlessly distinct empty states.
            self.age = ageSecret.flatMap { $0.isEmpty ? nil : AgeSecret(secretKey: $0) }
        }

        enum CodingKeys: String, CodingKey {
            case text
            case age
        }
    }

    internal struct AgeSecret: Codable, Sendable {
        let secretKey: String

        init(secretKey: String) {
            self.secretKey = secretKey
        }
    }

    internal struct LinkList: Decodable, Sendable {
        let links: String
    }
}
