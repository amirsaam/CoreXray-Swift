import XCTest
@testable import CoreXray

// Third-party audit follow-ups: restart semantics, deadline bounds, provider
// preflight gaps, TUN defaults, log-path retention, one-sided traffic,
// sniffing inheritance, the XrayDNS relay route, ping sentinel handling,
// geo candidate order, the timedOut case, and watchdog restart behavior.

final class AuditFixTests: XCTestCase {
    private var tempDir: URL!
    private let minimalJSON = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
    private let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXrayAuditFixTests")
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? Xray.shared.stop()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func decoded(_ json: String) throws -> XrayJSONValue {
        try JSONDecoder().decode(XrayJSONValue.self, from: Data(json.utf8))
    }

    // MARK: - H1: second start replaces the first

    func testSecondStartReplacesFirst() throws {
        let session = Xray.shared.newSession()
        try session.start(rawJSON: minimalJSON)
        XCTAssertTrue(try session.isRunning())
        XCTAssertNotNil(session.connectedSince)
        // Same session, second launch: no AlreadyRunning, engine still up.
        try session.start(rawJSON: minimalJSON)
        XCTAssertTrue(try session.isRunning())
        XCTAssertNotNil(session.connectedSince)
        try session.stop()
        XCTAssertFalse(try session.isRunning())
    }

    // MARK: - H2: deadline start succeeds inside the bound

    func testDeadlineStartSucceeds() async throws {
        let session = Xray.shared.newSession()
        try await session.start(.json(minimalJSON), deadline: .seconds(30))
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    // MARK: - H4: "auto" mirrors the engine's own implication

    func testTunFDEmitsAutoInterface() throws {
        // `TunConfig.Build` implies "auto" when a routing table is set
        // without an explicit interface; the wire says it outright, so the
        // document shows what the engine will do.
        let tun = try Xray.shared.tun(
            autoSystemRoutingTable: ["0.0.0.0/0"], fileDescriptor: 7
        )
        let config = try Xray.shared.newSession().build(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        let entry = try decoded(config.json)["inbounds"]?.arrayValue?.first
        XCTAssertEqual(entry?["tag"], .string("tunIn"))
        XCTAssertEqual(entry?["settings"]?["autoOutboundsInterface"], .string("auto"))
    }

    func testTunFDWithoutTableWritesNoAutoInterface() throws {
        // Without a table the engine leaves the key unset — and forcing
        // "auto" there breaks descriptor hand-off, so this does not.
        let tun = try Xray.shared.tun(fileDescriptor: 7)
        let config = try Xray.shared.newSession().build(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        let entry = try decoded(config.json)["inbounds"]?.arrayValue?.first
        XCTAssertNil(entry?["settings"]?["autoOutboundsInterface"])
    }

    func testTunWithoutFDWritesNoAutoInterface() throws {
        let tun = try Xray.shared.tun()
        let config = try Xray.shared.newSession().build(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        let entry = try decoded(config.json)["inbounds"]?.arrayValue?.first
        XCTAssertNil(entry?["settings"]?["autoOutboundsInterface"])
    }

    // MARK: - H5: log paths survive stop

    func testRecentEngineLogsSurviveStop() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let errorLog = tempDir.appendingPathComponent("xray-error.log")
        try "boom\n".write(to: errorLog, atomically: true, encoding: .utf8)
        let json = #"{"log":{"loglevel":"warning","error":"\#(errorLog.path)"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let session = Xray.shared.newSession()
        try session.start(rawJSON: json)
        try session.stop()
        let tail = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(tail.contains("boom"), "expected the seeded line, got \(tail)")
    }

    // MARK: - M1: one-sided traffic

    func testUplinkCountsOutboundSideOnly() {
        let first = XrayTrafficSnapshot(
            inbound: ["tun-in": XrayTrafficCounter(up: 100, down: 200)],
            outbound: ["proxy": XrayTrafficCounter(up: 60, down: 140)]
        )
        // Totals double-count (inbound + outbound sides of the same bytes).
        XCTAssertEqual(first.totalUp, 160)
        XCTAssertEqual(first.totalDown, 340)
        // One-sided counters count the outbound side only.
        XCTAssertEqual(first.uplink, 60)
        XCTAssertEqual(first.downlink, 140)
        let later = XrayTrafficSnapshot(
            inbound: ["tun-in": XrayTrafficCounter(up: 150, down: 260)],
            outbound: ["proxy": XrayTrafficCounter(up: 160, down: 240)]
        )
        let delta = later.delta(since: first)
        XCTAssertEqual(delta.totalUp, 150)
        XCTAssertEqual(delta.uplink, 100)
        XCTAssertEqual(delta.downlink, 100)
    }

    // MARK: - M2: entries inherit assembly sniffing

    func testAssemblySniffingReachesDefaultEntries() throws {
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: XrayAssemblySocksEntry(port: 18085),
            sniffing: Xray.shared.sniffing(destOverride: ["tls"], routeOnly: true)
        ).assemble()
        let sniffing = try decoded(config.json)["inbounds"]?.arrayValue?
            .first(where: { $0["tag"] == .string("socks-in") })?["sniffing"]
        XCTAssertEqual(sniffing?["destOverride"], .array([.string("tls")]))
        XCTAssertEqual(sniffing?["routeOnly"], .bool(true))
    }

    func testExplicitEntrySniffingWins() throws {
        let config = try XrayAssembly(
            source: .shareLinks(link),
            socks: XrayAssemblySocksEntry(
                port: 18086,
                sniffing: Xray.shared.sniffing(destOverride: ["http"], routeOnly: true)
            ),
            sniffing: Xray.shared.sniffing(destOverride: ["tls"])
        ).assemble()
        let sniffing = try decoded(config.json)["inbounds"]?.arrayValue?
            .first(where: { $0["tag"] == .string("socks-in") })?["sniffing"]
        XCTAssertEqual(sniffing?["destOverride"], .array([.string("http")]))
        XCTAssertEqual(sniffing?["routeOnly"], .bool(true))
    }

    // MARK: - M3: missing listen address

    func testPreflightRejectsMissingListen() throws {
        let json = #"{"inbounds":[{"tag":"x","protocol":"socks","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let tun = try Xray.shared.tun(fileDescriptor: 99)
        let issues = try Xray.shared.newSession().preflightIssues(
            .json(json), options: Xray.shared.options(tun: tun)
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("listen") }), "unexpected: \(issues)")
    }

    // MARK: - M4: the dns-in to dns-out route

    func testDNSRelayRouteAppended() throws {
        let json = #"{"inbounds":[{"tag":"dns-in","protocol":"dokodemo-door","listen":"127.0.0.1","port":1053,"settings":{"address":"1.1.1.1","port":53,"network":"udp"}}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let config = try Xray.shared.newSession().build(
            .json(json),
            options: Xray.shared.options(
                routing: Xray.shared.routing(final: .direct),
                geoCheck: false,
                dns: Xray.shared.dns()
            )
        )
        let value = try decoded(config.json)
        let rules = value["routing"]?["rules"]?.arrayValue ?? []
        XCTAssertTrue(
            rules.contains(where: {
                $0["inboundTag"]?.arrayValue?.compactMap { $0.stringValue } == ["dns-in"]
                    && $0["outboundTag"]?.stringValue == "dns-out"
            }),
            "expected a dns-in → dns-out rule"
        )
        XCTAssertTrue(
            (value["outbounds"]?.arrayValue ?? []).contains(where: { $0["tag"]?.stringValue == "dns-out" })
        )
    }

    func testDNSRelayRouteNotDuplicated() throws {
        let json = #"{"inbounds":[{"tag":"dns-in","protocol":"dokodemo-door","listen":"127.0.0.1","port":1053,"settings":{"address":"1.1.1.1","port":53,"network":"udp"}}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let already = Xray.shared.routingRule(inboundTags: ["dns-in"], destination: .dns)
        let config = try Xray.shared.newSession().build(
            .json(json),
            options: Xray.shared.options(
                routing: Xray.shared.routing(rules: [already], final: .direct),
                geoCheck: false,
                dns: Xray.shared.dns()
            )
        )
        let rules = try decoded(config.json)["routing"]?["rules"]?.arrayValue ?? []
        let relayRules = rules.filter {
            $0["inboundTag"]?.arrayValue?.compactMap { $0.stringValue } == ["dns-in"]
        }
        // The user's rule plus the trailing match-all final; no injected twin.
        XCTAssertEqual(relayRules.count, 1)
    }

    // MARK: - M5: ping sentinel delays read as zero

    func testPingFailureNormalizesSentinelDelay() throws {
        let decoder = JSONDecoder()
        let timeout = try decoder.decode(
            XrayPingResult.self, from: Data(#"{"success":false,"delay":10000,"error":"timeout"}"#.utf8)
        )
        XCTAssertFalse(timeout.succeeded)
        XCTAssertEqual(timeout.latencyMilliseconds, 0)
        XCTAssertEqual(timeout.failureReason, "timeout")
        let routing = try decoder.decode(
            XrayPingResult.self, from: Data(#"{"success":false,"delay":11000,"error":"routing"}"#.utf8)
        )
        XCTAssertEqual(routing.latencyMilliseconds, 0)
        let ok = try decoder.decode(
            XrayPingResult.self, from: Data(#"{"success":true,"delay":42}"#.utf8)
        )
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.latencyMilliseconds, 42)
    }

    // MARK: - M9: underscore asset spelling through the document env

    func testUnderscoreAssetEnvSpellingIsHonored() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let framing = Data([0x0A, 0x02, 0x00, 0x00]) + Data(repeating: 0, count: 64)
        try framing.write(to: tempDir.appendingPathComponent("geosite.dat"))
        let json = #"{"env":{"XRAY_LOCATION_ASSET":"\#(tempDir.path)"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let routing = Xray.shared.routing(
            rules: [Xray.shared.routingRule(domains: ["geosite:category-ads-all"], destination: .direct)],
            final: .direct
        )
        // Geo check on: the underscore spelling must locate the database.
        _ = try Xray.shared.newSession().build(.json(json), options: Xray.shared.options(routing: routing))
    }

    // MARK: - L1: the timedOut case

    func testTimedOutCarriesHint() {
        let error = XrayError.timedOut("the bridge did not answer within 5.0s; it may be wedged")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.recoveryHint?.isEmpty ?? true)
    }

    // MARK: - L4: watchdog restart fires once

    func testWatchdogRestartFiresOnce() async throws {
        let port = try Xray.shared.findAvailablePorts()[0]
        let fired = XCTestExpectation(description: "single stall fire across restart")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true
        let watchdog = try Xray.shared.trafficWatchdog(
            port: port, interval: .milliseconds(20), stalledAfter: .milliseconds(200)
        ) { fired.fulfill() }
        watchdog.start()
        watchdog.start()
        defer { watchdog.stop() }
        await fulfillment(of: [fired], timeout: 5)
    }

    // MARK: - L4: the deadline-exceeded path

    func testDeadlineExceededThrowsTimedOut() async throws {
        let session = Xray.shared.newSession()
        // Semaphore gate, not a fixed sleep: the launch cannot win early
        // no matter how slow the runner is; the timer only has to fire
        // within the backstop.
        let release = DispatchSemaphore(value: 0)
        session.launchOverride = { _ in _ = release.wait(timeout: .now() + 30) }
        defer { session.launchOverride = nil }
        do {
            try await session.start(.json(minimalJSON), deadline: .milliseconds(50))
            XCTFail("expected .timedOut")
        } catch let error as XrayError {
            guard case .timedOut = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        release.signal()
        XCTAssertNil(session.connectedSince)
        XCTAssertFalse(try session.isRunning())
    }

    // MARK: - L5: TUN dns servers ride the wire

    func testTunDNSServersSerialize() throws {
        let tun = try Xray.shared.tun(dns: ["1.1.1.1", "8.8.8.8"])
        let config = try Xray.shared.newSession().build(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        let entry = try decoded(config.json)["inbounds"]?.arrayValue?.first
        XCTAssertEqual(
            entry?["settings"]?["dns"],
            .array([.string("1.1.1.1"), .string("8.8.8.8")])
        )
    }

    // MARK: - L6: serialization sorts keys

    func testSerializeSortsKeys() throws {
        let text = try EngineTransport.serialize(
            ["zebra": .int(1), "apple": .int(2), "mango": .object(["y": .bool(true), "b": .bool(false)])]
        )
        XCTAssertEqual(text, #"{"apple":2,"mango":{"b":false,"y":true},"zebra":1}"#)
    }
}
