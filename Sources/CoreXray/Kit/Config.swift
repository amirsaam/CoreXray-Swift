import Foundation

// A complete Xray configuration as it travels: JSON text you already have, or
// the output of share-link conversion. A pure value; running it belongs to
// `Xray.Session`, which is the single owner of engine side effects.

extension Xray {
    public struct Config: Sendable {
        /// The configuration as JSON text, ready to hand to a session (or to
        /// persist, log, or edit between calls).
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
        /// throws `Xray.Error` ("no valid outbound found"). Entries the
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
        /// anything. The thrown `Xray.Error` carries the engine's parser
        /// complaint, which is the cheapest way to reject bad user input.
        /// The check runs inside the engine, so it needs the engine
        /// stopped — while running, use `validateOffline()` instead.
        public func validate() throws {
            try ConfigCalls.check(json: json)
        }

        /// Checks the document's structure without touching the engine, so
        /// it works while the engine runs. Verifies the text parses to a
        /// JSON object with only known top-level sections, and that every
        /// inbound and outbound carries the `tag` and `protocol` the engine
        /// requires. This is shape, not semantics: unknown protocols,
        /// unreachable addresses, and contradictory rules still need the
        /// engine's own `validate()`.
        public func validateOffline() throws {
            let decoded: JSONValue
            do {
                decoded = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            } catch {
                throw Error.invalidInput("the configuration is not valid JSON: \(error.localizedDescription)")
            }
            guard case .object(let dict) = decoded else {
                throw Error.invalidInput("the configuration must be a JSON object holding Xray sections")
            }
            try Self.checkStructure(of: dict)
        }

        /// The top-level sections the engine parses. Anything else is a
        /// typo the engine would reject at launch.
        private static let knownSections: Set<String> = [
            "log", "metrics", "stats", "observatory", "dns", "fakedns",
            "inbounds", "outbounds", "routing", "policy", "reverse",
            "transport", "api", "script", "env", "remarks",
        ]

        /// Shape-checks a decoded document: known sections only, and every
        /// inbound/outbound carries `tag` plus `protocol`.
        private static func checkStructure(of dict: JSONObject) throws {
            for key in dict.keys where !knownSections.contains(key) {
                throw Error.invalidInput(
                    "unknown top-level section '\(key)': the engine parses \(knownSections.sorted().joined(separator: ", "))"
                )
            }
            for section in ["inbounds", "outbounds"] {
                guard let entries = dict[section]?.arrayValue else { continue }
                for (index, entry) in entries.enumerated() {
                    guard case .object(let fields) = entry else {
                        throw Error.invalidInput("the \(section) entry at index \(index) must be a JSON object")
                    }
                    for field in ["tag", "protocol"] {
                        guard case .string(let value) = fields[field], !value.isEmpty else {
                            throw Error.invalidInput(
                                "the \(section) entry at index \(index) is missing its '\(field)'"
                            )
                        }
                    }
                }
            }
        }

        /// What a session can start from: JSON you already have, or share
        /// links that still need converting.
        public enum Source: Sendable {
            /// Complete Xray JSON configuration text.
            case json(String)

            /// Proxy share links; converted through the engine first.
            case shareLinks(String)
        }
    }

    /// Unwraps a provider's Age-encrypted subscription export: text
    /// starting with the Age armor header is decrypted with `ageSecret`,
    /// and any other text comes back unchanged. It does not parse links
    /// and does not base64-decode — the result (whatever it is) goes to
    /// `Config(shareLinks:ageSecret:)`, which accepts a single link, many
    /// newline-separated links, a base64 blob, or a
    /// `{"outbounds":[...]}` JSON blob.
    public func decodeSubscription(_ text: String, ageSecret: String? = nil) throws -> String {
        try ConfigCalls.decodeText(text, ageSecret: ageSecret)
    }
}
