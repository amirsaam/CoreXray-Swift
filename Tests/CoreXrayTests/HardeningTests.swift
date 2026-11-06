import XCTest
@testable import CoreXray

// Medium-priority audit follow-ups: input validation at the factories,
// fail-fast assembly rules, overflow-safe telemetry math, error-kind
// fixes, cancellation propagation, ext: geo references, and smarter
// provider preflight. No test here needs a running engine except the
// two that assert on live-launch adoption paths.

final class HardeningTests: XCTestCase {
    private let shared = Xray.shared
    private let minimalJSON = """
    {"log":{"loglevel":"warning"},"inbounds":[{"tag":"socks-in","protocol":"socks","listen":"127.0.0.1","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
    """

    override func tearDown() {
        try? Xray.shared.stop()
        unsetenv("xray.tun.fd")
        unsetenv("XRAY_TUN_FD")
        super.tearDown()
    }

    private func decoded(_ json: String) throws -> XrayJSONValue {
        try JSONDecoder().decode(XrayJSONValue.self, from: Data(json.utf8))
    }

    // MARK: - Port discovery guards

    func testFindAvailablePortsRejectsZeroCount() {
        XCTAssertThrowsError(try shared.findAvailablePorts(count: 0)) { error in
            guard case XrayError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    // MARK: - Metrics port collision

    func testMetricsPortCollisionThrowsAtBuild() throws {
        // minimalJSON's socks-in listens on 1080: aiming metrics there
        // must fail before anything launches.
        let options = shared.options(metricsPort: 1080)
        XCTAssertThrowsError(
            try shared.newSession().build(.json(minimalJSON), options: options)
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("collides"), "got: \(message)")
        }
    }

    // MARK: - Observatory validation

    func testObservatoryRejectsBadInput() {
        XCTAssertThrowsError(try shared.observatory(subjectSelector: []))
        XCTAssertThrowsError(
            try shared.observatory(subjectSelector: ["proxy"], probeURL: "gopher://example.com")
        )
        XCTAssertThrowsError(
            try shared.observatory(subjectSelector: ["proxy"], probeInterval: "soon")
        )
        XCTAssertNoThrow(try shared.observatory(subjectSelector: ["proxy"]))
    }

    // MARK: - Watchdog and monitor validation

    func testWatchdogRejectsNonPositiveCadence() throws {
        let port = try shared.findAvailablePorts()[0]
        XCTAssertThrowsError(
            try shared.trafficWatchdog(port: port, interval: .zero, onStall: {})
        )
        XCTAssertThrowsError(
            try shared.trafficWatchdog(port: port, stalledAfter: .zero, onStall: {})
        )
    }

    func testTrafficMonitorRejectsBadInput() {
        XCTAssertThrowsError(try shared.trafficMonitor(port: 10085, host: ""))
        XCTAssertThrowsError(try shared.trafficMonitor(port: 10085, timeoutSeconds: 0))
    }

    func testTrafficMonitorBracketsIPv6() async throws {
        // A free port on ::1 refuses the connection: the failure must be
        // a failed request (.bridgeFailed), proving the URL formed.
        // Before bracketing this threw .invalidInput at formation.
        let port = try shared.findAvailablePorts()[0]
        let monitor = try shared.trafficMonitor(port: port, host: "::1", timeoutSeconds: 2)
        do {
            _ = try await monitor.snapshot()
        } catch let error as XrayError {
            guard case .bridgeFailed = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
            return
        }
        // Nothing listening is the expectation; a listener would only
        // mean the test env answers loopback IPv6 unexpectedly.
    }

    // MARK: - Ineffective routing rules

    func testEmptyRoutingRuleThrowsAtBuild() throws {
        let options = shared.options(
            routing: shared.routing(rules: [shared.routingRule()])
        )
        XCTAssertThrowsError(
            try shared.newSession().build(.json(minimalJSON), options: options)
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("no conditions"), "got: \(message)")
        }
    }

    // MARK: - Overflow-safe telemetry

    func testCounterSumsWrapInsteadOfTrapping() {
        let snapshot = XrayTrafficSnapshot(
            inbound: [
                "a": XrayTrafficCounter(up: .max, down: 0),
                "b": XrayTrafficCounter(up: 1, down: 0),
            ],
            outbound: ["c": XrayTrafficCounter(up: .max, down: .max)]
        )
        XCTAssertEqual(snapshot.totalUp, Int64.max &+ 1 &+ Int64.max)
        XCTAssertEqual(snapshot.totalDown, Int64.max)
        XCTAssertEqual(snapshot.uplink, Int64.max)
    }

    func testRestartedCountersCountAsNew() {
        let earlier = XrayTrafficCounter(up: 100, down: 100)
        let later = XrayTrafficCounter(up: 5, down: 7)
        let delta = later.delta(since: earlier)
        XCTAssertEqual(delta.up, 5)
        XCTAssertEqual(delta.down, 7)
    }

    func testRemovedTagsAppearInDeltas() {
        let earlier = XrayTrafficSnapshot(inbound: ["gone": XrayTrafficCounter(up: 10, down: 4)])
        let later = XrayTrafficSnapshot()
        let delta = later.delta(since: earlier)
        XCTAssertNotNil(delta.inbound["gone"], "dropped tags must still appear in the delta")
        XCTAssertEqual(delta.inbound["gone"]?.up, 0)
    }

    // MARK: - Error kinds

    func testContentsOfMissingFileIsInvalidInput() {
        let session = shared.newSession()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-config-\(UUID().uuidString).json")
        XCTAssertThrowsError(try session.start(contentsOf: missing)) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains(missing.path), "got: \(message)")
        }
    }

    func testRemoteStartCancellationStaysCancellation() async throws {
        let session = shared.newSession()
        guard let feed = URL(string: "http://10.255.255.1/feed") else {
            return XCTFail("test URL did not form")
        }
        let task = Task {
            try await session.start(
                remoteSubscription: feed,
                deadline: .seconds(30),
                timeoutSeconds: 30
            )
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    // MARK: - Proxy tag heuristic

    func testProxyTagSkipsDirectOutbound() throws {
        let doc = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"},{"protocol":"vless","tag":"v"}]}"#
        let options = shared.options(
            routing: shared.routing(rules: [shared.routingRule(domains: ["example.com"], destination: .proxy)])
        )
        let config = try shared.newSession().build(.json(doc), options: options)
        let object = try decoded(config.json)
        let rules = object["routing"]?["rules"]?.arrayValue ?? []
        XCTAssertEqual(rules.first?["outboundTag"], .string("v"))
        let outbounds = object["outbounds"]?.arrayValue ?? []
        XCTAssertNil(outbounds.first?["tag"]?.stringValue, "direct must not be tagged proxy")
    }

    func testProxyTagFallsBackToDirectOnly() throws {
        let doc = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#
        let options = shared.options(
            routing: shared.routing(rules: [shared.routingRule(domains: ["example.com"], destination: .proxy)])
        )
        let config = try shared.newSession().build(.json(doc), options: options)
        let object = try decoded(config.json)
        let rules = object["routing"]?["rules"]?.arrayValue ?? []
        XCTAssertEqual(rules.first?["outboundTag"], .string("proxy"))
    }

    // MARK: - Transform-added relay route

    func testTransformAddedRelayGetsRoute() throws {
        let doc = #"{"log":{"loglevel":"warning"},"dns":{},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let options = shared.options(transform: { dict in
            var inbounds = dict["inbounds"]?.arrayValue ?? []
            inbounds.append(.object([
                "tag": .string("dns-in"),
                "protocol": .string("dokodemo-door"),
                "port": .int(5353),
            ]))
            dict["inbounds"] = .array(inbounds)
        })
        let config = try shared.newSession().build(.json(doc), options: options)
        let object = try decoded(config.json)
        let rules = object["routing"]?["rules"]?.arrayValue ?? []
        let relayed = rules.contains { rule in
            rule["inboundTag"] == .array([.string("dns-in")])
                && rule["outboundTag"] == .string("dns-out")
        }
        XCTAssertTrue(relayed, "transform-added dns-in must be routed to dns-out")
    }

    // MARK: - ext: geo references

    func testExtReferenceCollection() throws {
        let json = #"{"routing":{"rules":[{"domain":["ext:custom.dat:tag"]}]},"dns":{}}"#
        guard let object = try decoded(json).objectValue else {
            return XCTFail("test document did not decode to an object")
        }
        XCTAssertEqual(XrayGeoAssets.referencedExternalFiles(in: object), ["custom.dat"])
        XCTAssertTrue(XrayGeoAssets.referenced(in: object).isEmpty)
    }

    func testExtReferenceMissingFileThrows() throws {
        guard let object = try decoded(#"{"routing":{"rules":[{"ip":["ext:custom.dat:private"]}]}}"#).objectValue else {
            return XCTFail("test document did not decode to an object")
        }
        XCTAssertThrowsError(
            try XrayGeoAssets.check(externalFiles: XrayGeoAssets.referencedExternalFiles(in: object), env: nil)
        ) { error in
            guard case XrayError.geoAssets(let message) = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
            XCTAssertTrue(message.contains("custom.dat"), "got: \(message)")
        }
    }

    // MARK: - Preflight process-env descriptor

    func testPreflightAcceptsProcessEnvDescriptor() throws {
        setenv("xray.tun.fd", "5", 1)
        let tun = try shared.tun(listen: "127.0.0.1")
        let config = try shared.newSession().build(
            .json(minimalJSON), options: shared.options(tun: tun)
        )
        let problems = try shared.newSession().preflightIssues(.json(config.json))
        XCTAssertFalse(
            problems.contains(where: { $0.contains("file descriptor") }),
            "process-env descriptor must satisfy preflight, got: \(problems)"
        )
    }
}
