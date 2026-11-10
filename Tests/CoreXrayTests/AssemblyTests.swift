import XCTest
@testable import CoreXray

// The one-call path: a whole working document from intent, verified live.

final class AssemblyTests: XCTestCase {
    private let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Bridge"

    func testFullAssemblyFromShareLink() throws {
        let session = XraySession()
        let config = try XrayAssembly(
            source: .shareLinks(link),
            remarks: "demo",
            routing: XrayRouting(
                domainStrategy: .ipIfNonMatch,
                rules: [
                    .init(inboundTags: ["dns-in"], destination: .dns),
                    .init(domains: ["malware.example.com"], destination: .block),
                    .init(ips: ["10.0.0.0/8"], destination: .direct),
                ],
                final: .proxy
            ),
            dns: XrayDNS(
                hosts: ["blocked.example.com": "127.0.0.1"],
                queryStrategy: .useIPv4,
                servers: [.detailed(address: "fakedns", domains: ["example.com"])]
            ),
            fakeDNS: [XrayFakeDNS(ipPool: "198.18.0.0/16", poolSize: 512)],
            log: XrayLog(level: .warning, dnsLog: true)
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))

        // The converted proxy keeps its tag; destinations resolve to it, and
        // the "final" arrives as a trailing match-all rule (no "final" key —
        // the engine would ignore it).
        XCTAssertEqual(value["outbounds"]?[0]?["tag"], .string("Bridge"))
        XCTAssertNil(value["routing"]?["final"])
        XCTAssertEqual(value["routing"]?["rules"]?.arrayValue?.last?["outboundTag"], .string("Bridge"))
        // Referenced standards appear exactly once, with the right protocols.
        XCTAssertEqual(value["outbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("direct") })?["protocol"], .string("freedom"))
        XCTAssertEqual(value["outbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("block") })?["protocol"], .string("blackhole"))
        XCTAssertEqual(value["outbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("dns-out") })?["protocol"], .string("dns"))
        XCTAssertEqual(value["routing"]?["rules"]?[0]?["outboundTag"], .string("dns-out"))
        // Entries arrive with tags the rules reference. This assembly sets
        // no sniffing, so default-nil entries carry none either: sniffing
        // is the assembly's to give (see the sniffing-inheritance test),
        // not the entries' to assume.
        XCTAssertEqual(value["inbounds"]?[0]?["tag"], .string("socks-in"))
        XCTAssertNil(value["inbounds"]?[0]?["sniffing"])
        XCTAssertEqual(value["inbounds"]?[1]?["tag"], .string("dns-in"))
        XCTAssertEqual(value["inbounds"]?[1]?["protocol"], .string("dokodemo-door"))
        // Typed sections land verbatim.
        XCTAssertEqual(value["dns"]?["queryStrategy"], .string("UseIPv4"))
        XCTAssertEqual(value["log"]?["logLevel"], .string("warning"))
        XCTAssertEqual(value["remarks"], .string("demo"))

        try config.validate()
        try session.start(config)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    func testProxyConfigurationFactory() throws {
        let config = try Xray.shared.proxyConfiguration(
            .shareLinks(link),
            remarks: "factory",
            socksPort: 10880,
            routing: XrayRouting(final: .proxy)
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))

        XCTAssertEqual(value["inbounds"]?[0]?["tag"], .string("socks-in"))
        XCTAssertEqual(value["inbounds"]?[0]?["port"], .int(10880))
        XCTAssertNil(value["inbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("http-in") }))
        XCTAssertEqual(value["remarks"], .string("factory"))

        try config.validate()
    }

    func testProxyConfigurationWithoutSocks() throws {
        let config = try Xray.shared.proxyConfiguration(.shareLinks(link), socksPort: nil)
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertNil(value["inbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("socks-in") }))
    }

    func testDefaultsCanBeDropped() throws {
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: nil,
            dnsRelay: nil
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertNil(value["inbounds"])
        XCTAssertEqual(value["outbounds"]?[0]?["tag"], .string("Bridge"))
    }

    func testPatchRunsLast() throws {
        let config = try XrayAssembly(
            source: .shareLinks(link),
            patch: { $0["remarks"] = .string("patched") }
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["remarks"], .string("patched"))
        XCTAssertEqual(value["inbounds"]?[0]?["tag"], .string("socks-in"))
    }

    func testSocksEntryAuthStartsLive() throws {
        let session = XraySession()
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: XrayAssemblySocksEntry(
                port: 18081,
                auth: XrayCredentials(username: "proxy-user", password: "s3cret")
            ),
            dnsRelay: nil
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["inbounds"]?[0]?["settings"]?["auth"], .string("password"))
        XCTAssertEqual(value["inbounds"]?[0]?["settings"]?["users"]?[0]?["user"], .string("proxy-user"))
        try config.validate()
        try session.start(config)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    func testHttpEntryWithAuthStartsLive() throws {
        let session = XraySession()
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: nil,
            http: XrayAssemblyHttpEntry(
                port: 18082,
                auth: XrayCredentials(username: "web-user", password: "s3cret")
            ),
            dnsRelay: nil
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["inbounds"]?[0]?["protocol"], .string("http"))
        XCTAssertEqual(
            value["inbounds"]?[0]?["settings"]?["accounts"]?[0]?["user"],
            .string("web-user")
        )
        try config.validate()
        try session.start(config)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    func testTunAssemblyValidatesLive() throws {
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: nil,
            dnsRelay: nil,
            tun: XrayTunEntry(
                gateway: ["198.18.0.1/15"],
                autoSystemRoutingTable: ["0.0.0.0/0"],
                autoOutboundsInterface: "auto"
            )
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["inbounds"]?[0]?["tag"], .string("tunIn"))
        XCTAssertEqual(value["inbounds"]?[0]?["protocol"], .string("tun"))
        // No descriptor in tests: no env key, and the engine still
        // resolves the tun inbound (validate builds the full instance).
        XCTAssertNil(value["env"])
        try config.validate()
    }

    func testOutboundJsonSource() throws {
        let session = XraySession()
        let outboundOnly = """
        {"tag":"proxy0","protocol":"vless",
         "settings":{"address":"example.com","port":443,
                     "id":"12345678-abcd-abcd-abcd-123456789abc",
                     "encryption":"none"},
         "streamSettings":{"network":"raw","security":"tls",
                           "tlsSettings":{"serverName":"example.com"}}}
        """
        let config = try XrayAssembly(
            source: .outboundJson(outboundOnly),
            socks: XrayAssemblySocksEntry(port: 18084),
            dnsRelay: nil,
            routing: XrayRouting(
                rules: [.init(domains: ["example.com"], destination: .direct)],
                final: .proxy
            )
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        // The provided outbound survives with its tag; destinations resolve.
        XCTAssertEqual(value["outbounds"]?[0]?["tag"], .string("proxy0"))
        XCTAssertNil(value["routing"]?["final"])
        XCTAssertEqual(value["routing"]?["rules"]?.arrayValue?.last?["outboundTag"], .string("proxy0"))
        XCTAssertTrue((value["outbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []).contains("direct"))
        XCTAssertEqual(value["inbounds"]?[0]?["tag"], .string("socks-in"))
        try config.validate()
        try session.start(config)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    func testOutboundJsonRejectsFullDocument() throws {
        let full = #"{"inbounds":[],"outbounds":[{"tag":"proxy0","protocol":"freedom"}]}"#
        XCTAssertThrowsError(try XrayAssembly(source: .outboundJson(full)).assemble()) { error in
            let message = (error as? XrayError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Xray.shared.configuration(.json(...))"), message)
        }
    }

    func testOutboundJsonRejectsArray() throws {
        XCTAssertThrowsError(
            try XrayAssembly(source: .outboundJson(#"[{"tag":"a","protocol":"freedom"}]"#)).assemble()
        ) { error in
            XCTAssertTrue(((error as? XrayError)?.errorDescription ?? "").contains("not an array"))
        }
    }

    func testOutboundJsonRejectsMissingTag() throws {
        XCTAssertThrowsError(
            try XrayAssembly(source: .outboundJson(#"{"protocol":"freedom"}"#)).assemble()
        ) { error in
            XCTAssertTrue(((error as? XrayError)?.errorDescription ?? "").contains("missing its 'tag'"))
        }
    }

    func testObservatorySectionIsWritten() throws {
        let session = XraySession()
        let config = try XrayAssembly(
            source: .shareLinks(link),
            observatory: XrayObservatory(
                subjectSelector: ["fast"],
                probeURL: "https://example.com/generate_204",
                probeInterval: "30s",
                enableConcurrency: true
            ),
            metricsPort: 10085
        ).assemble()
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["observatory"]?["subjectSelector"], .array([.string("fast")]))
        XCTAssertEqual(value["observatory"]?["probeURL"], .string("https://example.com/generate_204"))
        XCTAssertEqual(value["observatory"]?["probeInterval"], .string("30s"))
        XCTAssertEqual(value["observatory"]?["enableConcurrency"], .bool(true))
        // XrayObservatory results surface through the XrayMetrics endpoint, so the
        // assembly keeps the two sections consistent for you.
        XCTAssertNotNil(value["metrics"])
        try config.validate()
        try session.start(config)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }
}
