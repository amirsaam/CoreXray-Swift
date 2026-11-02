import Foundation

// The dns and fakedns sections: where names resolve. Servers accept both
// forms the engine does — a bare address string, or an address scoped to
// domains — and everything passes through verbatim.

extension Xray {
    /// A `dns` section, written verbatim. Replaces any dns section already
    /// in the document.
    ///
    /// ```swift
    /// Xray.shared.dns(
    ///     hosts: ["geosite:malware": "127.0.0.1"],
    ///     queryStrategy: .useIPv4,
    ///     servers: [
    ///         .detailed(address: "fakedns", domains: ["geosite:category-ir"]),
    ///         .plain("https://dns.google/dns-query"),
    ///     ]
    /// )
    /// ```
    public struct DNS: Sendable {
        /// How the engine resolves when both A and AAAA exist.
        public enum QueryStrategy: String, Sendable {
            case useIP = "UseIP"
            case useIPv4 = "UseIPv4"
            case useIPv6 = "UseIPv6"
        }

        /// One dns server entry: either a bare address or an address scoped
        /// to the domains it serves.
        public enum Server: Sendable {
            case plain(String)
            case detailed(address: String, domains: [String])

            var wireValue: JSONValue {
                switch self {
                case .plain(let address):
                    return .string(address)
                case .detailed(let address, let domains):
                    var entry: JSONObject = ["address": .string(address)]
                    if !domains.isEmpty {
                        entry["domains"] = .array(domains.map(JSONValue.string))
                    }
                    return .object(entry)
                }
            }
        }

        /// Static overrides: hostname (or `geosite:` category) to IP.
        public var hosts: [String: String]
        public var queryStrategy: QueryStrategy?
        public var servers: [Server]

        internal init(
            hosts: [String: String] = [:],
            queryStrategy: QueryStrategy? = nil,
            servers: [Server] = []
        ) {
            self.hosts = hosts
            self.queryStrategy = queryStrategy
            self.servers = servers
        }

        var wireObject: JSONObject {
            var section: JSONObject = [:]
            if !hosts.isEmpty {
                section["hosts"] = .object(
                    Dictionary(uniqueKeysWithValues: hosts.map { ($0.key, JSONValue.string($0.value)) })
                )
            }
            if let queryStrategy {
                section["queryStrategy"] = .string(queryStrategy.rawValue)
            }
            if !servers.isEmpty {
                section["servers"] = .array(servers.map { $0.wireValue })
            }
            return section
        }
    }

    /// One `fakedns` pool entry, written verbatim inside the `fakedns` array.
    /// Replaces any fakedns section already in the document.
    public struct FakeDNS: Sendable {
        public var ipPool: String
        public var poolSize: Int

        internal init(ipPool: String, poolSize: Int) {
            self.ipPool = ipPool
            self.poolSize = poolSize
        }

        var wireObject: JSONObject {
            ["ipPool": .string(ipPool), "poolSize": .int(poolSize)]
        }
    }
}

// Value factories for the DNS section and fake-DNS pools.
extension Xray {
    public func dns(
        hosts: [String: String] = [:],
        queryStrategy: DNS.QueryStrategy? = nil,
        servers: [DNS.Server] = []
    ) -> DNS {
        DNS(hosts: hosts, queryStrategy: queryStrategy, servers: servers)
    }

    public func fakeDNS(ipPool: String, poolSize: Int) -> FakeDNS {
        FakeDNS(ipPool: ipPool, poolSize: poolSize)
    }
}
