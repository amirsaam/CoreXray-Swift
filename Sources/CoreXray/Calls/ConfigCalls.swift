import Foundation

// Share-link conversion both ways, config validation, and subscription
// unwrapping. Entries the engine cannot build are dropped inside the engine;
// the "no valid outbound" failure is reported as `.engineFailed` here and is
// reworded by the Kit layer.

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
            throw XrayError.bridgeFailed("the engine answered with a non-object instead of a configuration: the feed holds no convertible links")
        }
        return try EngineTransport.serialize(value)
    }

    internal static func links(from json: String) throws -> String {
        // Strict: an answer without links is a broken answer, and an
        // empty string back would look like "no routable outbounds".
        let links = try EngineTransport.ask(
            .shareLinksFromConfig,
            payload: Xray.ConfigPayload(xrayJson: json),
            as: Xray.LinkList.self
        ).links
        guard !links.isEmpty else {
            throw XrayError.bridgeFailed("the engine answered without links: the configuration holds nothing exportable")
        }
        return links
    }

    internal static func check(json: String) throws {
        try EngineTransport.acknowledge(.checkConfig, payload: Xray.ConfigPayload(xrayJson: json))
    }

    internal static func decodeText(_ text: String, ageSecret: String?) throws -> String {
        // Pasted subscriptions carry stray newlines; the engine detects
        // Age armor is detected by its header. Trim first. A base64 blob loses
        // nothing, and armor detection stops depending on paste hygiene.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try EngineTransport.ask(
            .decodeSubscription,
            payload: Xray.TextSnapshot(text: trimmed, ageSecret: ageSecret),
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
            // An empty secret is no secret: trim and normalize to nil so
            // the wire carries either a real secret or no `age` key at
            // all, never whitespace that fails server-side as a key.
            let trimmed = ageSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.age = trimmed.flatMap { $0.isEmpty ? nil : AgeSecret(secretKey: $0) }
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
