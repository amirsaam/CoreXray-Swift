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
            XCTAssertTrue(message.contains("selects nothing"), "got: \(message)")
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

    func testPreflightRejectsProcessEnvOnlyDescriptor() throws {
        setenv("xray.tun.fd", "5", 1)
        defer { unsetenv("xray.tun.fd") }
        let tun = try shared.tun(listen: "127.0.0.1")
        let config = try shared.newSession().build(
            .json(minimalJSON), options: shared.options(tun: tun)
        )
        let problems = try shared.newSession().preflightIssues(.json(config.json))
        XCTAssertTrue(
            problems.contains(where: { $0.contains("only in the process environment") }),
            "a process-only descriptor must be flagged for moving into the document, got: \(problems)"
        )
    }

    // MARK: - Low-batch: strict answers, stream paths, ping validation

    func testPingOptionsRejectsBadURL() {
        XCTAssertThrowsError(try shared.pingOptions(testURL: "not a url"))
        XCTAssertThrowsError(try shared.pingOptions(testURL: "ftp://example.com/x"))
        XCTAssertNoThrow(try shared.pingOptions(testURL: "https://example.com/generate_204"))
    }

    func testRawPingAnswersKeepResultsKey() throws {
        let raw = try JSONDecoder().decode(
            Xray.RawPingAnswers.self,
            from: Data(#"{"results":[{"success":true,"delay":42}]}"#.utf8)
        )
        XCTAssertEqual(raw.outcomes.count, 1)
        // The entry the strict decode accepts still parses the same way,
        // so the element-wise fallback only diverges on broken entries.
        let strict = try JSONDecoder().decode(
            Xray.PingAnswers.self,
            from: Data(#"{"results":[{"success":true,"delay":42}]}"#.utf8)
        )
        XCTAssertEqual(strict.outcomes.first?.latencyMilliseconds, 42)
        // A broken entry fails the strict decode — the synthesized
        // failure result takes its slot instead of poisoning the batch.
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                XrayPingResult.self,
                from: Data(#"{"success":false}"#.utf8)
            )
        )
        let synthesized = XrayPingResult(
            succeeded: false,
            latencyMilliseconds: 0,
            failureReason: "the engine answered with an undecodable measurement"
        )
        XCTAssertFalse(synthesized.succeeded)
    }

    func testStderrLogPathRecordsNothing() async throws {
        let session = shared.newSession()
        session.launchOverride = { _ in }
        defer {
            session.launchOverride = nil
            try? session.stop()
        }
        // The deadline path honors `launchOverride`, so no engine runs
        // and no file is touched — only the path adoption is exercised.
        try await session.start(
            .json(#"{"log":{"error":"stderr"},"inbounds":[],"outbounds":[]}"#),
            deadline: .seconds(5)
        )
        XCTAssertThrowsError(try session.recentEngineLogs(.error)) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("no error log file recorded"), message)
        }
    }

    func testFileLogPathIsRecordedOnLaunch() async throws {
        let session = shared.newSession()
        session.launchOverride = { _ in }
        defer {
            session.launchOverride = nil
            try? session.stop()
        }
        try await session.start(
            .json(#"{"log":{"error":"/tmp/does-not-exist-corexray.log"},"inbounds":[],"outbounds":[]}"#),
            deadline: .seconds(5)
        )
        // A recorded-but-missing file fails at the read, proving the
        // path survived `filePath` — unlike a stream name.
        XCTAssertThrowsError(try session.recentEngineLogs(.error)) { error in
            guard case XrayError.bridgeFailed(let message) = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("could not read engine log"), message)
        }
    }

    // MARK: - Re-audit fixes: destinations, bounds, ext:, clamping

    func testDestinationOnlyRoutingRuleThrowsAtBuild() throws {
        let options = shared.options(
            routing: shared.routing(rules: [shared.routingRule(destination: .direct)])
        )
        XCTAssertThrowsError(
            try shared.newSession().build(.json(minimalJSON), options: options)
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("selects nothing"), "got: \(message)")
        }
    }

    func testPortCountAndExcludingBounds() {
        XCTAssertThrowsError(try shared.findAvailablePorts(count: 10_000))
        XCTAssertThrowsError(try shared.verifyAvailablePorts(count: 10_000))
        XCTAssertThrowsError(try shared.findAvailablePorts(excluding: [0]))
        XCTAssertThrowsError(try shared.findAvailablePorts(excluding: [99_999]))
        XCTAssertThrowsError(try shared.verifyAvailablePorts(excluding: [-1]))
    }

    func testWatchdogRejectsEmptyHostAndHostPort() {
        XCTAssertThrowsError(
            try shared.trafficWatchdog(port: 24242, host: "", onStall: {})
        )
        XCTAssertThrowsError(
            try shared.trafficWatchdog(port: 24242, host: "example.com:8080", onStall: {})
        )
    }

    func testSnapshotRejectsHostPortShape() async throws {
        let monitor = try shared.trafficMonitor(port: 24242, host: "example.com:8080")
        do {
            _ = try await monitor.snapshot()
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("includes a port"), "got: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
    }

    func testExternalFilesRejectEmptyFilename() {
        XCTAssertThrowsError(
            try XrayGeoAssets.check(externalFiles: [""], env: nil)
        ) { error in
            guard case XrayError.geoAssets(let message) = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
            XCTAssertTrue(message.contains("no filename"), "got: \(message)")
        }
    }

    func testRemoteStartRejectsMissingExternalFile() async throws {
        let feed = """
        {"routing":{"rules":[{"type":"field","outboundTag":"direct","domains":["ext:custom.dat"]}]},"outbounds":[{"tag":"direct","protocol":"freedom"}]}
        """
        HTTPStub.replies = [HTTPStub.stubFeed: HTTPStub.Reply(status: 200, body: Data(feed.utf8))]
        defer { HTTPStub.replies = [:] }
        let session = shared.newSession()
        session.urlSession = HTTPStub.session()
        do {
            try await session.start(
                remoteSubscription: HTTPStub.stubFeed,
                assetDirectory: FileManager.default.temporaryDirectory
            )
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .geoAssets(let message) = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
            XCTAssertTrue(message.contains("custom.dat"), "got: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    func testCorruptCounterClampsInsteadOfFailingSnapshot() throws {
        let body = """
        {"stats":{"inbound":{"good":{"uplink":10,"downlink":20}},"outbound":{"broken":{"uplink":99999999999999999999,"downlink":5}}}}
        """
        let snapshot = try XrayTrafficMonitor.decodeSnapshot(from: Data(body.utf8))
        XCTAssertEqual(snapshot.inbound["good"]?.up, 10)
        XCTAssertEqual(snapshot.outbound["broken"]?.up, 0)
        XCTAssertEqual(snapshot.outbound["broken"]?.down, 5)
    }
}
