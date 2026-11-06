import XCTest
@testable import CoreXray

// Supervision: flight recorder, uptime stamp, engine log tailing, stall
// watchdog, provider preflight, one-call remote start, and the mockable
// session protocol.

final class SupervisionTests: XCTestCase {
    private var tempDir: URL!
    private let minimalJSON = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
    private let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXraySupervisionTests")
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? Xray.shared.stop()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Flight recorder and uptime

    func testRecentLogsRecordLaunches() throws {
        let session = Xray.shared.newSession()
        XCTAssertTrue(session.recentLogs().isEmpty)
        try session.start(rawJSON: minimalJSON)
        defer { try? session.stop() }
        let entries = session.recentLogs()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains(where: { $0.contains("engine launched") }))
    }

    func testConnectedSinceTracksLifecycle() throws {
        let session = Xray.shared.newSession()
        XCTAssertNil(session.connectedSince)
        try session.start(rawJSON: minimalJSON)
        XCTAssertNotNil(session.connectedSince)
        try session.stop()
        XCTAssertNil(session.connectedSince)
    }

    // MARK: - Engine log tailing

    func testRecentEngineLogsThrowWithoutFilePaths() throws {
        let session = Xray.shared.newSession()
        _ = try session.build(.json(minimalJSON))
        XCTAssertThrowsError(try session.recentEngineLogs(.error)) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("file path"))
        }
    }

    func testRecentEngineLogsTailRecordedFiles() throws {
        // Log paths are adopted at launch success, never at build: tailing
        // follows the run that actually launched.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let access = tempDir.appendingPathComponent("access.log")
        try (1 ... 10).map { "line \($0)\n" }.joined().write(to: access, atomically: true, encoding: .utf8)
        let json = #"{"log":{"loglevel":"warning","access":"\#(access.path)"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let session = Xray.shared.newSession()
        try session.start(rawJSON: json)
        defer { try? session.stop() }
        let tail = try session.recentEngineLogs(.access, lines: 3)
        XCTAssertEqual(tail, ["line 8", "line 9", "line 10"])
    }

    func testRawStartRecordsLogPaths() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let errorLog = tempDir.appendingPathComponent("xray-error.log")
        try "boom\n".write(to: errorLog, atomically: true, encoding: .utf8)
        let json = #"{"log":{"loglevel":"warning","access":"\#(tempDir.path)/xray-access.log","error":"\#(errorLog.path)"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let session = Xray.shared.newSession()
        try session.start(rawJSON: json)
        defer { try? session.stop() }
        let tail = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(tail.contains("boom"), "expected the seeded line, got \(tail)")
    }

    // MARK: - Stall watchdog

    func testWatchdogRejectsBadPort() {
        XCTAssertThrowsError(
            try Xray.shared.trafficWatchdog(port: 0, onStall: {})
        ) { error in
            guard case XrayError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testWatchdogFiresOnDeadEndpoint() async throws {
        let port = try Xray.shared.findAvailablePorts()[0]
        let fired = XCTestExpectation(description: "stall fires on a dead endpoint")
        let watchdog = try Xray.shared.trafficWatchdog(
            port: port, interval: 0.2, stalledAfter: 1
        ) { fired.fulfill() }
        watchdog.start()
        defer { watchdog.stop() }
        await fulfillment(of: [fired], timeout: 10)
    }

    func testWatchdogFiresOnIdleEngine() async throws {
        let port = try Xray.shared.findAvailablePorts()[0]
        let session = Xray.shared.newSession()
        let config = try session.build(.json(minimalJSON), options: Xray.shared.options(metricsPort: port))
        try session.start(config)
        defer { try? session.stop() }
        let fired = XCTestExpectation(description: "stall fires on an idle engine")
        let watchdog = try Xray.shared.trafficWatchdog(
            port: port, interval: 0.2, stalledAfter: 1
        ) { fired.fulfill() }
        watchdog.start()
        defer { watchdog.stop() }
        await fulfillment(of: [fired], timeout: 10)
    }

    // MARK: - Provider preflight

    func testPreflightRejectsProxyOnlyDocument() throws {
        XCTAssertThrowsError(
            try Xray.shared.newSession().preflightForProvider(.json(minimalJSON))
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("no tun inbound"), "message should name the gap: \(message)")
        }
    }

    func testPreflightRejectsPublicListen() throws {
        let json = #"{"log":{"loglevel":"warning"},"inbounds":[{"tag":"x","protocol":"socks","listen":"0.0.0.0","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let tun = try Xray.shared.tun()
        XCTAssertThrowsError(
            try Xray.shared.newSession().preflightForProvider(
                .json(json), options: Xray.shared.options(tun: tun)
            )
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("loopback"), "message should name the rule: \(message)")
            XCTAssertFalse(message.contains("no tun inbound"))
        }
    }

    func testPreflightPassesTunOnLoopback() throws {
        let tun = try Xray.shared.tun(fileDescriptor: 99)
        try Xray.shared.newSession().preflightForProvider(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
    }

    func testPreflightRejectsTunWithoutDescriptor() throws {
        let tun = try Xray.shared.tun()
        XCTAssertThrowsError(
            try Xray.shared.newSession().preflightForProvider(
                .json(minimalJSON), options: Xray.shared.options(tun: tun)
            )
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("file descriptor"), "message should name the gap: \(message)")
        }
    }

    func testPreflightIssuesReturnsProblemsAsValues() throws {
        let proxyOnly = try Xray.shared.newSession().preflightIssues(.json(minimalJSON))
        XCTAssertEqual(proxyOnly.count, 1)
        XCTAssertTrue(proxyOnly[0].contains("no tun inbound"), "unexpected: \(proxyOnly)")

        let tun = try Xray.shared.tun(fileDescriptor: 99)
        let clean = try Xray.shared.newSession().preflightIssues(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        XCTAssertTrue(clean.isEmpty, "unexpected: \(clean)")
    }

    // MARK: - One-call remote start

    func testRemoteStartFromFileURL() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let feed = tempDir.appendingPathComponent("feed.txt")
        try link.write(to: feed, atomically: true, encoding: .utf8)
        let session = Xray.shared.newSession()
        try await session.start(remoteSubscription: feed)
        defer { try? session.stop() }
        XCTAssertTrue(try session.isRunning())
        XCTAssertNotNil(session.connectedSince)
    }

    func testRemoteStartRejectsUnreachableFeed() async {
        let session = Xray.shared.newSession()
        do {
            try await session.start(
                remoteSubscription: URL(string: "https://invalid-domain-that-does-not-exist-12345.com/feed.txt")!
            )
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .bridgeFailed = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    func testRemoteStartRejectsOversizedFeed() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let feed = tempDir.appendingPathComponent("big.txt")
        try String(repeating: "vless://x\n", count: 2_000_000).write(to: feed, atomically: true, encoding: .utf8)
        let session = Xray.shared.newSession()
        do {
            try await session.start(remoteSubscription: feed)
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("cap"), "message should name the cap: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    func testRemoteStartRejectsServerError() async throws {
        HTTPStub.replies = [HTTPStub.stubFeed: HTTPStub.Reply(status: 404, body: Data("nope".utf8))]
        defer { HTTPStub.replies = [:] }
        let session = Xray.shared.newSession()
        session.urlSession = HTTPStub.session()
        do {
            try await session.start(remoteSubscription: HTTPStub.stubFeed)
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .bridgeFailed(let message) = error else {
                return XCTFail("expected .bridgeFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("404"), "message should name the status: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    func testRemoteStartRejectsLyingContentLength() async throws {
        HTTPStub.replies = [HTTPStub.stubFeed: HTTPStub.Reply(
            status: 200,
            headers: ["Content-Length": "999999999"],
            body: Data("tiny".utf8)
        )]
        defer { HTTPStub.replies = [:] }
        let session = Xray.shared.newSession()
        session.urlSession = HTTPStub.session()
        do {
            try await session.start(remoteSubscription: HTTPStub.stubFeed)
            XCTFail("expected a throw")
        } catch let error as XrayError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("cap"), "message should name the cap: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
        XCTAssertNil(session.connectedSince)
    }

    func testSessionConformsToProviding() throws {
        let providing: XraySessionProviding = Xray.shared.newSession()
        let config = try providing.build(.json(minimalJSON))
        XCTAssertTrue(config.json.contains("freedom"))
        XCTAssertTrue(providing.recentLogs().contains(where: { $0.contains("assembled") }))
        XCTAssertNil(providing.connectedSince)
    }

    // MARK: - M7: the bridge protocol tripwire

    func testBridgeProtocolVersionStillAccepted() throws {
        // Every bridge call sends apiVersion 3. If upstream ever requires
        // a newer envelope, this live round-trip — not just the constant
        // below — fails and forces a conscious update of
        // `EngineTransport.protocolVersion` before any release is cut
        // (the nightly workflow only tags after this suite passes).
        XCTAssertEqual(EngineTransport.protocolVersion, 3)
        XCTAssertFalse(try Xray.shared.version().isEmpty)
    }
}
