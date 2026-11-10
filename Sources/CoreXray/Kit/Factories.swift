import Foundation

// Starting points on the shared instance. They create the objects an app
// holds onto without spelling out constructors or the engine pipeline.
// Everything here returns before touching the engine except
// `validate`, which only checks.

extension Xray {
    /// A session to hold onto for the app's lifetime: it owns the launch
    /// lifecycle with an optional log sink. The sink is an escaping
    /// closure (the session holds it), passed trailing:
    ///
    /// ```swift
    /// let session = Xray.shared.newSession { print("[xray]", $0) }
    /// ```
    public func newSession(_ logger: ((String) -> Void)? = nil) -> XraySession {
        XraySession(logger: logger)
    }

    /// Builds a runnable configuration from JSON text or share links, with
    /// the session defaults applied. No session is needed when you only want
    /// the document. Persist it for later use.
    public func configuration(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws -> XrayConfig {
        try XraySession().build(source, options: options ?? XraySessionOptions())
    }

    /// Checks a source the way `start` would, without starting anything.
    /// Throws the engine's parser complaint. It rejects bad user input
    /// without launching.
    public func validate(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws {
        try XraySession().validate(source, options: options ?? XraySessionOptions())
    }

    /// Starts an assembly from a server description: share links or one
    /// outbound object. The one-call path from intent to a runnable
    /// document (conversion/wrapping, entries, sections, patches
    /// applied). Tune the result through the returned assembly before
    /// calling `assemble()` on it. Full documents are rejected.
    /// Pass those through `configuration(.json(...))`.
    public func assembler(_ source: XrayAssemblySource) -> XrayAssembly {
        XrayAssembly(source: source)
    }

    /// Builds a runnable proxy document from a server description in one
    /// call: conversion/wrapping plus local inbounds and sections, no
    /// struct construction. A socks inbound on `socksPort` is included by default (matching the native
    /// apps); pass nil to leave it out, or a port for an HTTP inbound via
    /// `httpPort`. The DNS relay ships by default (local queries need a
    /// door); pass `dnsRelay: false` to drop it. For TUN,
    /// observatory, or patches, use `assembler(_:)`.
    public func proxyConfiguration(
        _ source: XrayAssemblySource,
        remarks: String? = nil,
        socksPort: Int? = 10808,
        httpPort: Int? = nil,
        dnsRelay: Bool = true,
        routing: XrayRouting? = nil,
        dns: XrayDNS? = nil,
        log: XrayLog? = nil,
        credentials: XrayCredentials? = nil,
        environment: [String: String]? = nil,
        geoCheck: Bool = true,
        diagnostics: ((String) -> Void)? = nil
    ) throws -> XrayConfig {
        if let socksPort { try Self.validPort(socksPort, name: "socks") }
        if let httpPort { try Self.validPort(httpPort, name: "http") }
        var assembly = XrayAssembly(source: source)
        assembly.remarks = remarks
        assembly.socks = socksPort.map { XrayAssemblySocksEntry(port: $0) }
        assembly.http = httpPort.map { XrayAssemblyHttpEntry(port: $0) }
        if !dnsRelay { assembly.dnsRelay = nil }
        assembly.routing = routing
        assembly.dns = dns
        assembly.log = log
        assembly.credentials = credentials
        assembly.environment = environment
        assembly.geoCheck = geoCheck
        assembly.diagnostics = diagnostics
        return try assembly.assemble()
    }
}

// Shared validation for factory-built values.
extension Xray {
    internal static func validPort(_ port: Int, name: String) throws {
        guard (1 ... 65_535).contains(port) else {
            throw XrayError.invalidInput("\(name) port must be 1-65535, got \(port)")
        }
    }
}
