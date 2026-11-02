import Foundation

// The routing section of an Xray configuration, typed. Everything passes
// through verbatim: domains accept geosite:, full:, domain:, and regexp:
// forms; ips accept geoip: and CIDR forms; the engine validates them.

extension Xray {
    /// Where routed traffic goes. The named cases are resolved at assembly
    /// time: `proxy` becomes the converted outbound's tag, the rest become
    /// standard outbounds (`direct`, `block`, `dns-out`) that are added to
    /// the document automatically when referenced but missing. `custom`
    /// passes a tag through verbatim — it must already exist.
    public enum Destination: Sendable {
        /// The converted proxy server (first outbound).
        case proxy
        /// A `freedom` outbound, tagged `"direct"`.
        case direct
        /// A `blackhole` outbound, tagged `"block"`.
        case block
        /// A `dns` outbound, tagged `"dns-out"`.
        case dns
        /// An outbound tag you provide yourself.
        case custom(String)

        func tag(proxyTag: String) -> String {
            switch self {
            case .proxy:
                return proxyTag
            case .direct:
                return "direct"
            case .block:
                return "block"
            case .dns:
                return "dns-out"
            case .custom(let tag):
                return tag
            }
        }
    }

    /// A routing section written into the assembled configuration.
    /// Destinations resolve at assembly time (see `Destination`); rule
    /// order and strategy are exactly what you declare.
    ///
    /// ```swift
    /// Xray.shared.routing(
    ///     domainStrategy: .ipIfNonMatch,
    ///     rules: [
    ///         Xray.shared.routingRule(
    ///             domains: ["geosite:ads", "full:tracker.example.com"],
    ///             destination: .proxy),
    ///         Xray.shared.routingRule(
    ///             ips: ["geoip:private", "192.168.0.0/16"],
    ///             destination: .direct),
    ///     ],
    ///     final: .proxy
    /// )
    /// ```
    public struct Routing: Sendable {
        /// How the engine resolves domains against IP rules.
        public enum DomainStrategy: String, Sendable {
            /// Use domain matching results as-is.
            case asIs = "AsIs"
            /// Fall back to IP matching when no domain rule hits.
            case ipIfNonMatch = "IPIfNonMatch"
            /// Resolve on demand during IP matching.
            case ipOnDemand = "IPOnDemand"
        }

        /// One routing rule: a `field`-type entry matching domains, IPs,
        /// ports, networks, sniffed protocols, or inbound tags, and sending
        /// the match to an outbound. Empty lists match nothing on their own;
        /// combine fields within a rule with AND semantics, rules with OR.
        public struct Rule: Sendable {
            /// Domains to match: plain (`example.com`), `full:`, `domain:`,
            /// `regexp:`, or `geosite:` categories.
            public var domains: [String]
            /// IPs to match: CIDR ranges or `geoip:` categories.
            public var ips: [String]
            /// Ports to match: `"443"`, `"80,443"`, or `"80-100"`.
            public var port: String?
            /// Networks to match: `"tcp"`, `"udp"`, or `"tcp,udp"`.
            public var network: String?
            /// Sniffed protocols to match, e.g. `["http", "tls", "bittorrent"]`.
            public var protocols: [String]
            /// Inbound tags this rule applies to.
            public var inboundTags: [String]
            /// Where the match goes.
            public var destination: Destination?

            internal init(
                domains: [String] = [],
                ips: [String] = [],
                port: String? = nil,
                network: String? = nil,
                protocols: [String] = [],
                inboundTags: [String] = [],
                destination: Destination? = nil
            ) {
                self.domains = domains
                self.ips = ips
                self.port = port
                self.network = network
                self.protocols = protocols
                self.inboundTags = inboundTags
                self.destination = destination
            }

            func wireObject(proxyTag: String) -> JSONObject {
                var rule: JSONObject = ["type": .string("field")]
                if !domains.isEmpty {
                    rule["domain"] = .array(domains.map(JSONValue.string))
                }
                if !ips.isEmpty {
                    rule["ip"] = .array(ips.map(JSONValue.string))
                }
                if let port {
                    rule["port"] = .string(port)
                }
                if let network {
                    rule["network"] = .string(network)
                }
                if !protocols.isEmpty {
                    rule["protocol"] = .array(protocols.map(JSONValue.string))
                }
                if !inboundTags.isEmpty {
                    rule["inboundTag"] = .array(inboundTags.map(JSONValue.string))
                }
                if let destination {
                    rule["outboundTag"] = .string(destination.tag(proxyTag: proxyTag))
                }
                return rule
            }

            /// True when the rule sends traffic to the converted proxy.
            var needsProxy: Bool {
                destination.map {
                    if case .proxy = $0 { return true }
                    return false
                } ?? false
            }
        }

        public var domainStrategy: DomainStrategy?
        public var rules: [Rule]
        /// Where traffic no rule matched goes. The engine has no `final`
        /// field, so this is written as a trailing `network: "tcp,udp"`
        /// rule — every connection the engine routes is TCP or UDP, so it
        /// catches the leftovers exactly where `final` promises. (A truly
        /// condition-less rule is rejected by the engine as having no
        /// effective fields, hence the network condition.)
        public var final: Destination?

        internal init(
            domainStrategy: DomainStrategy? = nil,
            rules: [Rule] = [],
            final: Destination? = nil
        ) {
            self.domainStrategy = domainStrategy
            self.rules = rules
            self.final = final
        }

        /// True when any rule sends traffic to the converted proxy.
        var needsProxy: Bool {
            rules.contains(where: { $0.needsProxy })
                || final.map {
                    if case .proxy = $0 { return true }
                    return false
                } ?? false
        }

        func wireObject(proxyTag: String) -> JSONObject {
            var rules = self.rules
            if let final {
                // No `final` on the wire: a trailing `network: "tcp,udp"`
                // field rule catches the leftovers exactly where `final`
                // promises. The network condition is load-bearing — the
                // engine rejects a condition-less rule ("no effective
                // fields") — and it matches everything the engine routes.
                rules.append(Rule(network: "tcp,udp", destination: final))
            }
            var section: JSONObject = ["rules": .array(rules.map { .object($0.wireObject(proxyTag: proxyTag)) })]
            if let domainStrategy {
                section["domainStrategy"] = .string(domainStrategy.rawValue)
            }
            return section
        }
    }
}

// Value factories: the same knobs as the inits, callable on the shared
// instance so user code never spells a type name to configure routing.
extension Xray {
    public func routingRule(
        domains: [String] = [],
        ips: [String] = [],
        port: String? = nil,
        network: String? = nil,
        protocols: [String] = [],
        inboundTags: [String] = [],
        destination: Destination? = nil
    ) -> Routing.Rule {
        Routing.Rule(
            domains: domains, ips: ips, port: port, network: network,
            protocols: protocols, inboundTags: inboundTags, destination: destination
        )
    }

    public func routing(
        domainStrategy: Routing.DomainStrategy? = nil,
        rules: [Routing.Rule] = [],
        final: Destination? = nil
    ) -> Routing {
        Routing(domainStrategy: domainStrategy, rules: rules, final: final)
    }
}
