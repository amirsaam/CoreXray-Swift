import Foundation

// A complete Xray configuration as it travels: JSON text you already have, or
// the output of share-link conversion. A pure value; running it belongs to
// `XraySession`, which is the single owner of engine side effects.

/// What a session can start from: JSON you already have, or share
/// links that still need converting.
public enum XrayConfigSource: Sendable {
    /// Complete Xray JSON configuration text.
    case json(String)

    /// Proxy share links; converted through the engine first.
    case shareLinks(String)
}

/// A complete Xray configuration as it travels: JSON text you already
/// have, or the output of share-link conversion. A pure value; running
/// it belongs to `XraySession`, the single owner of engine side effects.
public struct XrayConfig: Sendable {
    /// The configuration as JSON text, ready to hand to a session (or to
    /// persist or edit between calls).
    public var json: String

    /// Builds a configuration from raw Xray JSON text. No validation
    /// happens here; call `validate()` to have the engine confirm it
    /// parses and builds.
    internal init(json: String) {
        self.json = json
    }

    /// Builds a configuration from proxy share links: one `vless://`,
    /// `trojan://`, `ss://`, or `socks://` link, many newline-separated,
    /// a base64 blob of those, or an Age-encrypted export (with
    /// `ageSecret`). Verified against the bundled engine: `vmess://`,
    /// `hysteria2://`, `wireguard://`, and `{"outbounds":[...]}` JSON
    /// blobs are dropped by its converter, so a feed of only those
    /// throws `XrayError` ("no valid outbound found"). Entries the
    /// engine cannot build are dropped; if nothing survives, throws.
    internal init(shareLinks: String, ageSecret: String? = nil) throws {
        self.json = try ConfigCalls.convert(shareLinks: shareLinks, ageSecret: ageSecret)
    }

    /// Turns this configuration back into proxy share links,
    /// newline-separated, one link per routable outbound.
    public func shareLinks() throws -> String {
        try ConfigCalls.links(from: json)
    }

    /// Validates this configuration with the engine without starting
    /// anything. The thrown `XrayError` carries the engine's parser
    /// complaint. It rejects bad user input without launching.
    /// The check runs inside the engine, so it needs the engine
    /// stopped. While running, use `validateOffline()` instead. The
    /// launch-time geo gate also runs first, so a document whose
    /// `geosite:`/`geoip:` files are missing fails here the same way it
    /// would fail at `start`, instead of validating green and then
    /// refusing to launch.
    public func validate() throws {
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(XrayJSONValue.self, from: data),
           case .object(let dict) = decoded {
            try XrayGeoAssets.check(referenced: XrayGeoAssets.referenced(in: dict), env: dict["env"]?.objectValue)
            try XrayGeoAssets.check(externalFiles: XrayGeoAssets.referencedExternalFiles(in: dict), env: dict["env"]?.objectValue)
        }
        try ConfigCalls.check(json: json)
    }

    /// Checks the document's structure without touching the engine, so
    /// it works while the engine runs. Verifies the text parses to a
    /// JSON object with only known top-level sections, and that every
    /// inbound and outbound carries the non-empty `protocol` the engine
    /// requires. `tag` is intentionally not required: untagged entries
    /// launch fine (the engine invents an identity), and demanding one
    /// would reject documents the engine accepts. This is shape, not
    /// semantics. Unknown protocols and bad addresses still need the
    /// engine's own `validate()`.
    public func validateOffline() throws {
        let decoded: XrayJSONValue
        do {
            decoded = try JSONDecoder().decode(XrayJSONValue.self, from: Data(json.utf8))
        } catch {
            throw XrayError.invalidInput("the configuration is not valid JSON: \(error.localizedDescription)")
        }
        guard case .object(let dict) = decoded else {
            throw XrayError.invalidInput("the configuration must be a JSON object holding Xray sections")
        }
        try Self.checkStructure(of: dict)
    }

    /// The top-level sections the engine parses. The list stays pinned to the section
    /// map in the bundled libXray's `infra/conf` loader, not to the
    /// Xray-core HEAD the list may have grown in since. Anything else
    /// is a typo the engine would reject at launch.
    private static let knownSections: Set<String> = [
        "log", "metrics", "stats", "observatory", "dns", "fakedns",
        "inbounds", "outbounds", "routing", "policy", "reverse",
        "transport", "api", "script", "env", "remarks",
    ]

    /// Shape-checks a decoded document: known sections only, entry
    /// arrays where the engine reads arrays, and a non-empty `protocol`
    /// on every inbound/outbound entry.
    private static func checkStructure(of dict: XrayJSONObject) throws {
        for key in dict.keys where !knownSections.contains(key) {
            throw XrayError.invalidInput(
                "unknown top-level section '\(key)': the engine parses \(knownSections.sorted().joined(separator: ", "))"
            )
        }
        for section in ["inbounds", "outbounds"] {
            guard let raw = dict[section] else { continue }
            guard let entries = raw.arrayValue else {
                throw XrayError.invalidInput("the '\(section)' section must be an array: the engine reads no other shape, so a lone object would fail at launch, not just here")
            }
            for (index, entry) in entries.enumerated() {
                guard case .object(let fields) = entry else {
                    throw XrayError.invalidInput("the \(section) entry at index \(index) must be a JSON object")
                }
                guard case .string(let value) = fields["protocol"], !value.isEmpty else {
                    throw XrayError.invalidInput(
                        "the \(section) entry at index \(index) is missing its 'protocol'"
                    )
                }
            }
        }
    }

}

extension Xray {

    /// Unwraps a provider's Age-encrypted subscription export: text
    /// starting with the Age armor header is decrypted with `ageSecret`,
    /// and any other text comes back unchanged. It does not parse links
    /// and does not base64-decode. The result goes to
    /// `XrayConfig(shareLinks:ageSecret:)`, which accepts a single link,
    /// many newline-separated links, or a base64 blob of those. It does
    /// not accept `{"outbounds":[...]}` JSON blobs: the engine's
    /// converter drops those, so full documents go to
    /// `Xray.shared.configuration(.json(...))` instead.
    public func decodeSubscription(_ text: String, ageSecret: String? = nil) throws -> String {
        try ConfigCalls.decodeText(text, ageSecret: ageSecret)
    }
}
