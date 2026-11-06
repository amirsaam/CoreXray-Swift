import Foundation

// The easy path: describe what you want, get a working document. XrayAssembly
// owns the whole shape — entries, standards, tag resolution — and delegates
// to the XraySession pipeline, so everything below composes with the low-level
// options rather than replacing them.

/// A local SOCKS entry point. Present by default; set to nil for a
/// document without one.
public struct XrayAssemblySocksEntry: Sendable {
    public var tag: String
    public var listen: String
    public var port: Int
    public var udp: Bool
    /// Nil means open (`auth: noauth`); set for username + password.
    public var auth: XrayCredentials?
    /// Carried verbatim; nil (the default) leaves the entry without
    /// its own sniffing, so it receives the assembly's through the
    /// normal pipeline.
    public var sniffing: XraySniffing?

    internal init(
        tag: String = "socks-in",
        listen: String = "127.0.0.1",
        port: Int = 10808,
        udp: Bool = true,
        auth: XrayCredentials? = nil,
        sniffing: XraySniffing? = nil
    ) {
        self.tag = tag
        self.listen = listen
        self.port = port
        self.udp = udp
        self.auth = auth
        self.sniffing = sniffing
    }

    var wireObject: XrayJSONObject {
        var settings: XrayJSONObject = ["udp": .bool(udp)]
        if let auth {
            settings["auth"] = .string("password")
            settings["users"] = .array([.object([
                "user": .string(auth.username),
                "pass": .string(auth.password),
            ])])
        } else {
            settings["auth"] = .string("noauth")
        }
        var entry: XrayJSONObject = [
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
public struct XrayAssemblyHttpEntry: Sendable {
    public var tag: String
    public var listen: String
    public var port: Int
    /// Nil means open; set for username + password.
    public var auth: XrayCredentials?
    /// Carried verbatim; nil (the default) leaves the entry without
    /// its own sniffing, so it receives the assembly's through the
    /// normal pipeline.
    public var sniffing: XraySniffing?

    internal init(
        tag: String = "http-in",
        listen: String = "127.0.0.1",
        port: Int = 10809,
        auth: XrayCredentials? = nil,
        sniffing: XraySniffing? = nil
    ) {
        self.tag = tag
        self.listen = listen
        self.port = port
        self.auth = auth
        self.sniffing = sniffing
    }

    var wireObject: XrayJSONObject {
        var entry: XrayJSONObject = [
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

/// A XrayDNS relay entry: `dokodemo-door` catching local XrayDNS and handing
/// it to the `dns-out` outbound. Present by default; nil to drop.
public struct XrayAssemblyDNSRelay: Sendable {
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

    var wireObject: XrayJSONObject {
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

/// What an assembly builds from: a server description, never a finished
/// document. Share links are converted through the engine; a single
/// outbound object is wrapped as the outbounds as-is. A full
/// configuration document is rejected — that already *is* a runnable
/// document, so run it through `engine.configuration(.json(...))` or
/// hand it to a session instead of assembling around it.
public enum XrayAssemblySource: Sendable {
    /// Proxy share links: one `vless://`, `trojan://`, `ss://`, or
    /// `socks://` link, many newline-separated, or a base64 blob of
    /// those. Converted through the engine; the first surviving
    /// outbound is the `.proxy` destination.
    case shareLinks(String)

    /// One outbound object (`{"protocol": ..., "tag": ..., ...}`) with
    /// no wrapper and no other sections. It becomes the outbounds, so
    /// it is the `.proxy` destination. Anything shaped like a full
    /// document (an `inbounds`/`outbounds` wrapper, an array) is
    /// rejected with a pointer to the right call.
    case outboundJson(String)
}

public struct XrayAssembly {

    /// Where the proxy server comes from: converted share links or one
    /// outbound object. Conversion/wrapping output becomes the
    /// outbounds; the first one is the `.proxy` destination.
    public var source: XrayAssemblySource
    public var remarks: String?
    public var socks: XrayAssemblySocksEntry?
    public var http: XrayAssemblyHttpEntry?
    public var dnsRelay: XrayAssemblyDNSRelay?
    public var routing: XrayRouting?
    public var dns: XrayDNS?
    public var fakeDNS: [XrayFakeDNS]?
    public var log: XrayLog?
    /// Device-wide capture through the engine's own TUN inbound. Nil
    /// means proxy mode. See `XrayTunEntry`.
    public var tun: XrayTunEntry?
    /// XraySniffing for inbounds without their own: bare converted
    /// inbounds and entries left at the default nil. Entries carrying
    /// explicit sniffing keep it.
    public var sniffing: XraySniffing?
    /// Per-outbound health probing. Needs `metricsPort` for readable
    /// results. See `XrayObservatory`.
    public var observatory: XrayObservatory?
    /// XrayMetrics endpoint port, forwarded to the session options: adds the
    /// XrayMetrics listener, the `stats` section, and the policy switches
    /// `XrayTrafficMonitor` reads. Nil means no traffic counters.
    public var metricsPort: Int?
    /// Final patch after everything else. Same position as the
    /// low-level transform, for schema-exotic keys.
    public var patch: ((inout XrayJSONObject) -> Void)?

    internal init(
        source: XrayAssemblySource,
        remarks: String? = nil,
        socks: XrayAssemblySocksEntry? = XrayAssemblySocksEntry(),
        http: XrayAssemblyHttpEntry? = nil,
        dnsRelay: XrayAssemblyDNSRelay? = XrayAssemblyDNSRelay(),
        routing: XrayRouting? = nil,
        dns: XrayDNS? = nil,
        fakeDNS: [XrayFakeDNS]? = nil,
        log: XrayLog? = nil,
        tun: XrayTunEntry? = nil,
        sniffing: XraySniffing? = nil,
        observatory: XrayObservatory? = nil,
        metricsPort: Int? = nil,
        patch: ((inout XrayJSONObject) -> Void)? = nil
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

    /// Assembles the full document: conversion/wrapping, entries, typed
    /// sections, destinations resolved, standards added, `patch` last.
    public func assemble() throws -> XrayConfig {
        let socks = self.socks
        let http = self.http
        let dnsRelay = self.dnsRelay
        let remarks = self.remarks
        let sniffing = self.sniffing
        let patch = self.patch
        let pipelineSource: XrayConfigSource
        switch source {
        case .shareLinks(let text):
            pipelineSource = .shareLinks(text)
        case .outboundJson(let text):
            pipelineSource = .json(try Self.wrapOutbound(text))
        }
        return try XraySession().build(pipelineSource, options: XraySessionOptions(
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

    /// Wraps one outbound object as a pipeline-ready document. Rejects
    /// anything that is not exactly one outbound: arrays, full
    /// documents, and objects missing the engine's required fields.
    private static func wrapOutbound(_ text: String) throws -> String {
        let decoded: XrayJSONValue
        do {
            decoded = try JSONDecoder().decode(XrayJSONValue.self, from: Data(text.utf8))
        } catch {
            throw XrayError.invalidInput("the outbound JSON is not valid JSON: \(error.localizedDescription)")
        }
        guard case .object(let fields) = decoded else {
            throw XrayError.invalidInput(
                "the outbound JSON must be a single outbound object, not an array — "
                    + "pass one {\"protocol\": ..., \"tag\": ...} object per assembly"
            )
        }
        if fields["outbounds"] != nil || fields["inbounds"] != nil {
            throw XrayError.invalidInput(
                "this looks like a full configuration document, not one outbound — "
                    + "run it through engine.configuration(.json(...)) instead of the assembler"
            )
        }
        for field in ["tag", "protocol"] {
            guard case .string(let value) = fields[field], !value.isEmpty else {
                throw XrayError.invalidInput("the outbound object is missing its '\(field)'")
            }
        }
        let document: XrayJSONObject = ["outbounds": .array([.object(fields)])]
        return String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
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
        auth: XrayCredentials? = nil,
        sniffing: XraySniffing? = nil
    ) throws -> XrayAssemblySocksEntry {
        try Self.validPort(port, name: "socks")
        return XrayAssemblySocksEntry(
            tag: tag, listen: listen, port: port, udp: udp, auth: auth, sniffing: sniffing
        )
    }

    public func httpEntry(
        tag: String = "http-in",
        listen: String = "127.0.0.1",
        port: Int = 10809,
        auth: XrayCredentials? = nil,
        sniffing: XraySniffing? = nil
    ) throws -> XrayAssemblyHttpEntry {
        try Self.validPort(port, name: "http")
        return XrayAssemblyHttpEntry(
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
    ) throws -> XrayAssemblyDNSRelay {
        try Self.validPort(port, name: "dns relay")
        try Self.validPort(remotePort, name: "dns relay remote")
        return XrayAssemblyDNSRelay(
            tag: tag, listen: listen, port: port, address: address,
            remotePort: remotePort, network: network
        )
    }
}
