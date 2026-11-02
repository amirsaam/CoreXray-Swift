import Foundation

// The easy path: describe what you want, get a working document. Assembly
// owns the whole shape — entries, standards, tag resolution — and delegates
// to the Session pipeline, so everything below composes with the low-level
// options rather than replacing them.

extension Xray {
    /// A complete configuration described by intent. One value in, one
    /// working document out — no tag bookkeeping, no merge closures:
    ///
    /// ```swift
    /// var assembly = Xray.shared.assembler(.shareLinks(pastedText))
    /// assembly.remarks = "home"
    /// assembly.routing = Xray.shared.routing(
    ///     domainStrategy: .ipIfNonMatch,
    ///     rules: [
    ///         Xray.shared.routingRule(domains: ["malware.example.com"], destination: .block),
    ///         Xray.shared.routingRule(ips: ["10.0.0.0/8"], destination: .direct),
    ///     ],
    ///     final: .proxy
    /// )
    /// assembly.dns = Xray.shared.dns(queryStrategy: .useIPv4,
    ///                                servers: [.plain("https://dns.google/dns-query")])
    /// assembly.log = Xray.shared.log(level: .warning)
    /// let config = try assembly.assemble()
    /// try session.start(config)
    /// ```
    // Sendable is deliberately absent: `patch` is a user closure that runs
    // exactly once on the assembling thread, and no task boundary ever
    // carries an Assembly. Conforming would force @Sendable on user code
    // for zero thread-safety gain.
    public struct Assembly {
        /// A local SOCKS entry point. Present by default; set to nil for a
        /// document without one.
        public struct SocksEntry: Sendable {
            public var tag: String
            public var listen: String
            public var port: Int
            public var udp: Bool
            /// Nil means open (`auth: noauth`); set for username + password.
            public var auth: Xray.Credentials?
            /// Carried verbatim; nil (the default) leaves the entry without
            /// its own sniffing, so it receives the assembly's through the
            /// normal pipeline.
            public var sniffing: Xray.Sniffing?

            internal init(
                tag: String = "socks-in",
                listen: String = "127.0.0.1",
                port: Int = 10808,
                udp: Bool = true,
                auth: Xray.Credentials? = nil,
                sniffing: Xray.Sniffing? = nil
            ) {
                self.tag = tag
                self.listen = listen
                self.port = port
                self.udp = udp
                self.auth = auth
                self.sniffing = sniffing
            }

            var wireObject: JSONObject {
                var settings: JSONObject = ["udp": .bool(udp)]
                if let auth {
                    settings["auth"] = .string("password")
                    settings["users"] = .array([.object([
                        "user": .string(auth.username),
                        "pass": .string(auth.password),
                    ])])
                } else {
                    settings["auth"] = .string("noauth")
                }
                var entry: JSONObject = [
                    "tag": .string(tag),
                    "protocol": .string("socks"),
                    "listen": .string(listen),
                    "port": .int(port),
                    "settings": .object(settings),
                ]
                if let sniffing {
                    entry["sniffing"] = .object(sniffing.wireObject)
                }
                return entry
            }
        }

        /// A local HTTP entry point: same role as the SOCKS entry for
        /// clients that speak HTTP proxying. Absent by default; set to add
        /// one (default 127.0.0.1:10809, tagged `http-in`).
        public struct HttpEntry: Sendable {
            public var tag: String
            public var listen: String
            public var port: Int
            /// Nil means open; set for username + password.
            public var auth: Xray.Credentials?
            /// Carried verbatim; nil (the default) leaves the entry without
            /// its own sniffing, so it receives the assembly's through the
            /// normal pipeline.
            public var sniffing: Xray.Sniffing?

            internal init(
                tag: String = "http-in",
                listen: String = "127.0.0.1",
                port: Int = 10809,
                auth: Xray.Credentials? = nil,
                sniffing: Xray.Sniffing? = nil
            ) {
                self.tag = tag
                self.listen = listen
                self.port = port
                self.auth = auth
                self.sniffing = sniffing
            }

            var wireObject: JSONObject {
                var entry: JSONObject = [
                    "tag": .string(tag),
                    "protocol": .string("http"),
                    "listen": .string(listen),
                    "port": .int(port),
                ]
                if let auth {
                    entry["settings"] = .object(["accounts": .array([.object([
                        "user": .string(auth.username),
                        "pass": .string(auth.password),
                    ])])])
                }
                if let sniffing {
                    entry["sniffing"] = .object(sniffing.wireObject)
                }
                return entry
            }
        }

        /// A DNS relay entry: `dokodemo-door` catching local DNS and handing
        /// it to the `dns-out` outbound. Present by default; nil to drop.
        public struct DNSRelay: Sendable {
            public var tag: String
            public var listen: String
            public var port: Int
            public var address: String
            public var remotePort: Int
            public var network: String

            internal init(
                tag: String = "dns-in",
                listen: String = "127.0.0.1",
                port: Int = 10810,
                address: String = "1.1.1.1",
                remotePort: Int = 53,
                network: String = "udp"
            ) {
                self.tag = tag
                self.listen = listen
                self.port = port
                self.address = address
                self.remotePort = remotePort
                self.network = network
            }

            var wireObject: JSONObject {
                [
                    "tag": .string(tag),
                    "protocol": .string("dokodemo-door"),
                    "listen": .string(listen),
                    "port": .int(port),
                    "settings": .object([
                        "address": .string(address),
                        "port": .int(remotePort),
                        "network": .string(network),
                    ]),
                ]
            }
        }

        /// Where the proxy server comes from: converted share links or a
        /// JSON document you own. Conversion output becomes the outbounds;
        /// the first one is the `.proxy` destination.
        public var source: Config.Source
        public var remarks: String?
        public var socks: SocksEntry?
        public var http: HttpEntry?
        public var dnsRelay: DNSRelay?
        public var routing: Xray.Routing?
        public var dns: Xray.DNS?
        public var fakeDNS: [Xray.FakeDNS]?
        public var log: Xray.Log?
        /// Device-wide capture through the engine's own TUN inbound. Nil
        /// means proxy mode. See `Xray.TunEntry`.
        public var tun: TunEntry?
        /// Sniffing for inbounds without their own: bare converted
        /// inbounds and entries left at the default nil. Entries carrying
        /// explicit sniffing keep it.
        public var sniffing: Xray.Sniffing?
        /// Per-outbound health probing. Needs `metricsPort` for readable
        /// results. See `Xray.Observatory`.
        public var observatory: Observatory?
        /// Metrics endpoint port, forwarded to the session options: adds the
        /// Metrics listener, the `stats` section, and the policy switches
        /// `TrafficMonitor` reads. Nil means no traffic counters.
        public var metricsPort: Int?
        /// Final patch after everything else. Same position as the
        /// low-level transform, for schema-exotic keys.
        public var patch: ((inout Xray.JSONObject) -> Void)?

        internal init(
            source: Config.Source,
            remarks: String? = nil,
            socks: SocksEntry? = SocksEntry(),
            http: HttpEntry? = nil,
            dnsRelay: DNSRelay? = DNSRelay(),
            routing: Xray.Routing? = nil,
            dns: Xray.DNS? = nil,
            fakeDNS: [Xray.FakeDNS]? = nil,
            log: Xray.Log? = nil,
            tun: TunEntry? = nil,
            sniffing: Xray.Sniffing? = nil,
            observatory: Observatory? = nil,
            metricsPort: Int? = nil,
            patch: ((inout Xray.JSONObject) -> Void)? = nil
        ) {
            self.source = source
            self.remarks = remarks
            self.socks = socks
            self.http = http
            self.dnsRelay = dnsRelay
            self.routing = routing
            self.dns = dns
            self.fakeDNS = fakeDNS
            self.log = log
            self.tun = tun
            self.sniffing = sniffing
            self.observatory = observatory
            self.metricsPort = metricsPort
            self.patch = patch
        }

        /// Assembles the full document: conversion, entries, typed sections,
        /// destinations resolved, standards added, `patch` last.
        public func assemble() throws -> Config {
            let socks = self.socks
            let http = self.http
            let dnsRelay = self.dnsRelay
            let remarks = self.remarks
            let sniffing = self.sniffing
            let patch = self.patch
            return try Session().build(source, options: Session.Options(
                sniffing: sniffing,
                transform: { dict in
                    // Append: conversion emits no inbounds, and the TUN
                    // entry (if any) is already here — never replace.
                    var inbounds = dict["inbounds"]?.arrayValue ?? []
                    if let socks {
                        inbounds.append(.object(socks.wireObject))
                    }
                    if let http {
                        inbounds.append(.object(http.wireObject))
                    }
                    if let dnsRelay {
                        inbounds.append(.object(dnsRelay.wireObject))
                    }
                    if !inbounds.isEmpty {
                        dict["inbounds"] = .array(inbounds)
                    }
                    // The session pipeline already injected this sniffing
                    // into the conversion inbounds; the appended entries
                    // above missed that pass, so inject again. Entries
                    // with their own sniffing keep it — inject skips them.
                    sniffing?.inject(into: &dict)
                    if let remarks {
                        dict["remarks"] = .string(remarks)
                    }
                    patch?(&dict)
                },
                routing: routing,
                tun: tun,
                observatory: observatory,
                dns: dns,
                fakeDNS: fakeDNS,
                log: log,
                metricsPort: metricsPort
            ))
        }
    }
}

// Value factories for local inbound entries. Ports are checked here so a
// typo fails fast instead of surfacing as an engine bind error.
extension Xray {
    public func socksEntry(
        tag: String = "socks-in",
        listen: String = "127.0.0.1",
        port: Int = 10808,
        udp: Bool = true,
        auth: Xray.Credentials? = nil,
        sniffing: Xray.Sniffing? = nil
    ) throws -> Assembly.SocksEntry {
        try Self.validPort(port, name: "socks")
        return Assembly.SocksEntry(
            tag: tag, listen: listen, port: port, udp: udp, auth: auth, sniffing: sniffing
        )
    }

    public func httpEntry(
        tag: String = "http-in",
        listen: String = "127.0.0.1",
        port: Int = 10809,
        auth: Xray.Credentials? = nil,
        sniffing: Xray.Sniffing? = nil
    ) throws -> Assembly.HttpEntry {
        try Self.validPort(port, name: "http")
        return Assembly.HttpEntry(
            tag: tag, listen: listen, port: port, auth: auth, sniffing: sniffing
        )
    }

    public func dnsRelay(
        tag: String = "dns-in",
        listen: String = "127.0.0.1",
        port: Int = 10810,
        address: String = "1.1.1.1",
        remotePort: Int = 53,
        network: String = "udp"
    ) throws -> Assembly.DNSRelay {
        try Self.validPort(port, name: "dns relay")
        try Self.validPort(remotePort, name: "dns relay remote")
        return Assembly.DNSRelay(
            tag: tag, listen: listen, port: port, address: address,
            remotePort: remotePort, network: network
        )
    }
}
