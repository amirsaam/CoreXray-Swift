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
            XCTAssertTrue(message.contains("no destination"), "got: \(message)")
        }
    }

    // MARK: - Overflow-safe telemetry

    func testCounterSumsSaturateInsteadOfTrapping() {
        let snapshot = XrayTrafficSnapshot(
            inbound: [
                "a": XrayTrafficCounter(up: .max, down: 0),
                "b": XrayTrafficCounter(up: 1, down: 0),
            ],
            outbound: ["c": XrayTrafficCounter(up: .max, down: .max)]
        )
        // Saturating, not wrapping or trapping: dashboard math never
        // reads a wrapped-around total as a restart, and never traps.
        XCTAssertEqual(snapshot.totalUp, Int64.max)
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
        // Fail-closed: a freedom-only document has no proxy, and aliasing
        // `.proxy` to `direct` once sent tunnel traffic around the
        // tunnel. The error names the fix.
        let doc = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#
        let options = shared.options(
            routing: shared.routing(rules: [shared.routingRule(domains: ["example.com"], destination: .proxy)])
        )
        XCTAssertThrowsError(
            try shared.newSession().build(.json(doc), options: options)
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains(".direct"), "got: \(message)")
        }
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
        // The factory already refuses it; the monitor itself refuses too,
        // so a hand-built monitor from another path still fails fast.
        let monitor = XrayTrafficMonitor(port: 24242, host: "example.com:8080")
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

    // MARK: - Re-audit fixes: cross-session epochs

    func testStaleTimeoutCleanupStandsDownForNewerStart() async throws {
        // The first session's launch hangs past its deadline, so its
        // cleanup parks in the background. A second session starting
        // before the orphan settles must survive the orphan's arrival.
        let first = shared.newSession()
        first.launchOverride = { _ in Thread.sleep(forTimeInterval: 0.4) }
        defer {
            first.launchOverride = nil
            try? Xray.shared.stop()
        }
        do {
            try await first.start(.json(minimalJSON), deadline: .milliseconds(50))
            XCTFail("expected a timeout")
        } catch let error as XrayError {
            guard case .timedOut = error else {
                return XCTFail("expected .timedOut, got \(error)")
            }
        }
        XCTAssertNil(first.connectedSince)
        let second = shared.newSession()
        try second.start(rawJSON: minimalJSON)
        XCTAssertTrue(try shared.isRunning())
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(
            try shared.isRunning(),
            "the stale timeout cleanup killed the newer instance"
        )
        XCTAssertNotNil(second.connectedSince)
    }

    func testDeadlineStartCancellationIsPrompt() async throws {
        let session = shared.newSession()
        session.launchOverride = { _ in Thread.sleep(forTimeInterval: 5) }
        defer { session.launchOverride = nil }
        let task = Task {
            try await session.start(.json(minimalJSON), deadline: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let waited = Date()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(waited), 5)
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
        XCTAssertFalse(try shared.isRunning())
    }

    // MARK: - Re-audit fixes: credentials, relay, preflight, routing

    func testTransformAddedSocksWithoutCredentialsThrows() {
        var assembly = shared.assembler(
            .outboundJson(#"{"protocol":"freedom","tag":"proxy"}"#)
        )
        assembly.credentials = shared.credentials(username: "u", password: "p")
        assembly.patch = { dict in
            var inbounds = dict["inbounds"]?.arrayValue ?? []
            // A transform-added SOCKS inbound carrying its own guard:
            // applying the assembly credentials over it must throw
            // instead of silently replacing someone else's auth.
            inbounds.append(.object([
                "tag": .string("evil"), "protocol": .string("socks"),
                "listen": .string("127.0.0.1"), "port": .int(1099),
                "settings": .object(["auth": .string("password")]),
            ]))
            dict["inbounds"] = .array(inbounds)
        }
        XCTAssertThrowsError(try assembly.assemble()) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("auth"), "got: \(message)")
        }
    }

    func testCredentialsWithNoSocksInboundThrows() {
        var assembly = shared.assembler(
            .outboundJson(#"{"protocol":"freedom","tag":"proxy"}"#)
        )
        assembly.socks = nil
        assembly.credentials = shared.credentials(username: "u", password: "p")
        XCTAssertThrowsError(try assembly.assemble()) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("SOCKS inbound"), "got: \(message)")
        }
    }

    func testAssemblyWithoutDNSSectionStillRoutesRelay() throws {
        // The default assembly carries a dnsRelay but no dns section:
        // the relay route and its `dns-out` must still be backfilled.
        let config = try shared.proxyConfiguration(
            .outboundJson(#"{"protocol":"freedom","tag":"proxy"}"#)
        )
        let document = try decoded(config.json)
        guard case .object(let dict) = document,
              case .array(let outbounds) = dict["outbounds"] else {
            return XCTFail("assembled document has no outbounds")
        }
        XCTAssertTrue(
            outbounds.contains {
                $0.objectValue?["tag"]?.stringValue == "dns-out"
            },
            "dns-out was not backfilled"
        )
        guard case .object(let routing) = dict["routing"],
              case .array(let rules) = routing["rules"] else {
            return XCTFail("assembled document has no routing rules")
        }
        XCTAssertTrue(
            rules.contains {
                guard let rule = $0.objectValue else { return false }
                return rule["outboundTag"]?.stringValue == "dns-out"
                    && rule["inboundTag"]?.arrayValue?.compactMap({ $0.stringValue }).contains("dns-in") == true
            },
            "dns-in -> dns-out route missing"
        )
    }

    func testPreflightFlagsNativeMetricsCollision() throws {
        let json = """
        {"inbounds":[{"tag":"socks-in","protocol":"socks","listen":"127.0.0.1","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}],"metrics":{"listen":"127.0.0.1:1080"}}
        """
        let problems = try shared.newSession().preflightIssues(.json(json))
        XCTAssertTrue(
            problems.contains { $0.contains("metrics listener") && $0.contains("1080") },
            "got: \(problems)"
        )
    }

    func testPreflightFlagsDuplicateInboundPorts() throws {
        let json = """
        {"inbounds":[{"tag":"a","protocol":"socks","listen":"127.0.0.1","port":1080},{"tag":"b","protocol":"http","listen":"127.0.0.1","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
        """
        let problems = try shared.newSession().preflightIssues(.json(json))
        XCTAssertTrue(
            problems.contains { $0.contains("both listen on") },
            "got: \(problems)"
        )
    }

    func testBuildRejectsEmptyRoutingFields() {
        for rule in [
            shared.routingRule(domains: ["example.com"], port: ""),
            shared.routingRule(domains: ["example.com"], network: " "),
            shared.routingRule(domains: ["example.com"], protocols: [""]),
        ] {
            let options = shared.options(routing: shared.routing(rules: [rule]))
            XCTAssertThrowsError(
                try shared.newSession().build(.json(minimalJSON), options: options)
            ) { error in
                guard case XrayError.invalidInput = error else {
                    return XCTFail("expected .invalidInput, got \(error)")
                }
            }
        }
    }

    func testCustomTagWarningDoesNotThrow() throws {
        var lines: [String] = []
        let session = Xray.shared.newSession { lines.append($0) }
        let options = shared.options(
            routing: shared.routing(rules: [
                shared.routingRule(domains: ["example.com"], destination: .custom("typo"))
            ])
        )
        // Unknown to the document, so it warns — but the transform may
        // still add it, so it must not throw at build.
        XCTAssertNoThrow(try session.build(.json(minimalJSON), options: options))
        XCTAssertTrue(lines.contains { $0.contains("typo") }, "got: \(lines)")
    }

    func testDuplicateMatchAllAboveFinalWarns() throws {
        var lines: [String] = []
        let session = Xray.shared.newSession { lines.append($0) }
        let options = shared.options(
            routing: shared.routing(
                rules: [
                    shared.routingRule(network: "tcp,udp", destination: .direct),
                    shared.routingRule(network: "tcp,udp", destination: .direct),
                ],
                final: .direct
            )
        )
        XCTAssertNoThrow(try session.build(.json(minimalJSON), options: options))
        XCTAssertTrue(lines.contains { $0.contains("never fires") }, "got: \(lines)")
    }

    func testValidateOfflineRejectsNonArraySections() {
        let json = #"{"inbounds":{},"outbounds":[]}"#
        let config = XrayConfig(json: json)
        XCTAssertThrowsError(try config.validateOffline()) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("inbounds"), "got: \(message)")
        }
    }

    // MARK: - Status envelope body tolerance

    func testStatusEnvelopeToleratesEveryBodyShape() throws {
        // The Go side has answered status calls with missing, null,
        // object, and scalar `data` across versions. Only success/error
        // decide; the body shape never fails the call.
        for body in ["", "\"data\":42,", "\"data\":null,", "\"data\":{\"x\":1},"] {
            let raw = "{\"success\":true,\(body)\"error\":\"\"}"
            let envelope = try EngineTransport.envelope(of: raw, as: XrayJSONValue?.self)
            XCTAssertNoThrow(try EngineTransport.resolvedStatus(envelope: envelope))
        }
        let failed = try EngineTransport.envelope(
            of: "{\"success\":false,\"error\":\"boom\"}", as: XrayJSONValue?.self)
        XCTAssertThrowsError(try EngineTransport.resolvedStatus(envelope: failed)) { error in
            guard case XrayError.engineFailed(let message) = error else {
                return XCTFail("expected .engineFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("boom"), "got: \(message)")
        }
    }

    func testNestingDepthGuardRejectsAttack() {
        // A thousand open brackets would exhaust the stack in recursive
        // decode — an uncatchable crash. The depth pre-scan refuses first.
        let hostile = String(repeating: "[", count: 200)
        XCTAssertThrowsError(
            try EngineTransport.envelope(of: hostile, as: XrayJSONValue?.self)
        ) { error in
            guard case XrayError.bridgeFailed(let message) = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("nested"), "got: \(message)")
        }
    }

    // MARK: - Monitor host fail-fast

    func testMonitorFactoryRejectsHostPort() {
        XCTAssertThrowsError(try shared.trafficMonitor(port: 8080, host: "127.0.0.1:9090")) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("port"), "got: \(message)")
        }
    }

    // MARK: - Geo download error taxonomy

    func testGeoDownload404IsBridgeFailure() async throws {
        HTTPStub.replies = [
            HTTPStub.stubIP: HTTPStub.Reply(status: 200, body: Data([0x0A, 0x02, 0x00, 0x00])),
            HTTPStub.stubSite: HTTPStub.Reply(status: 404, body: Data()),
        ]
        var downloader = XrayGeoDownloader(geoIPURL: HTTPStub.stubIP, geoSiteURL: HTTPStub.stubSite)
        downloader.urlSession = HTTPStub.session()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXrayGeoTaxonomyTests")
            .appendingPathComponent(UUID().uuidString)
        do {
            try await downloader.download(into: dir)
            XCTFail("expected a download error")
        } catch {
            // A server failure is a bridge failure naming the URL and the
            // status — never a raw URLError leaking the transport.
            guard case XrayError.bridgeFailed(let message) = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("404"), "got: \(message)")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Config+options launch overloads

    func testStartConfigWithOptionsAndDeadline() async throws {
        let config = try shared.configuration(.json(minimalJSON))
        let session = shared.newSession()
        try await session.start(config, options: shared.options(), deadline: .seconds(30))
        XCTAssertTrue(try session.isRunning())
        try session.stop()
    }

    func testProxyConfigurationDiagnosticsReceivesBuildNotes() throws {
        var lines: [String] = []
        let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"
        let config = try shared.proxyConfiguration(
            .shareLinks(link), socksPort: 18080, httpPort: 18081,
            diagnostics: { lines.append($0) })
        // Assembly diagnostics flow into the throwaway session's logger,
        // so build notes reach the caller-supplied sink.
        XCTAssertFalse(config.json.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("assembled configuration") }, "got: \(lines)")
    }

    func testProxyConfigurationDropsDNSRelayOnRequest() throws {
        let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"
        let dropped = try shared.proxyConfiguration(.shareLinks(link), dnsRelay: false)
        let droppedObject = try decoded(dropped.json)
        let droppedTags = droppedObject["inbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertFalse(droppedTags.contains("dns-in"), "dnsRelay: false must drop the relay, got: \(droppedTags)")
        let kept = try shared.proxyConfiguration(.shareLinks(link))
        let keptObject = try decoded(kept.json)
        let keptTags = keptObject["inbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertTrue(keptTags.contains("dns-in"), "the relay ships by default, got: \(keptTags)")
    }
}
