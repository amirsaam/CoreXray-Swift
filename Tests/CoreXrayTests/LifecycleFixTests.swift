import XCTest
@testable import CoreXray

// Critical + high audit fixes: the deadline timeout must stop its
// orphan (not skip cleanup because the timeout itself is an XrayError),
// every start path must bump the launch epoch, log paths are adopted at
// launch success (never at build), build never touches process state,
// the stale TUN descriptor is cleared at launch, a superseded launch
// stamps nothing, and unparseable feeds are rejected before downloading.
final class LifecycleFixTests: XCTestCase {
    private var tempDir: URL!
    private let minimalJSON = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXrayLifecycleFixTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? Xray.shared.stop()
        unsetenv("xray.tun.fd")
        unsetenv("XRAY_TUN_FD")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func wait(
        upTo seconds: Double = 3,
        for condition: () -> Bool,
        _ message: String
    ) async throws {
        let rounds = Int(seconds * 20)
        for _ in 0 ..< rounds {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail(message)
    }

    // MARK: - C1: the timeout stops its orphan

    func testTimeoutCompensationStopsOrphan() async throws {
        let session = Xray.shared.newSession()
        // Gate the launch on a semaphore instead of a fixed sleep: the
        // launch can never win the deadline race early, so a slow CI
        // runner cannot flip this test — the 50ms timer only has to fire
        // within the 30s backstop below.
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
        // Release the orphan: the parked compensation must settle it,
        // then stop the idle engine.
        release.signal()
        try await wait(for: {
            session.recentLogs().contains(where: { $0.contains("engine stopped") })
        }, "timed-out start left its orphan running")
        XCTAssertNil(session.connectedSince)
        XCTAssertFalse(try session.isRunning())
    }

    // MARK: - C2: every start bumps the epoch

    func testStaleTimeoutCannotKillFreshStart() async throws {
        let session = Xray.shared.newSession()
        // Same semaphore gate as above: the timer only has to fire
        // within the 30s backstop, so CI load cannot flip the race.
        let release = DispatchSemaphore(value: 0)
        session.launchOverride = { _ in _ = release.wait(timeout: .now() + 30) }
        do {
            try await session.start(.json(minimalJSON), deadline: .milliseconds(50))
            XCTFail("expected .timedOut")
        } catch let error as XrayError {
            guard case .timedOut = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        session.launchOverride = nil
        // Fresh sync start on the real engine: bumps the epoch, so the
        // stale compensation above must stand down when the orphan settles.
        try session.start(rawJSON: minimalJSON)
        // Release only after the fresh start: the orphan is guaranteed
        // unsettled while the new instance comes up.
        release.signal()
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(try session.isRunning())
        XCTAssertNotNil(session.connectedSince)
        XCTAssertFalse(
            session.recentLogs().contains(where: { $0.contains("stopping engine") }),
            "stale timeout killed a newer launch"
        )
        try session.stop()
    }

    // MARK: - C3: log paths adopted at launch success

    func testAsyncStartAdoptsLogPaths() async throws {
        let logFile = tempDir.appendingPathComponent("async-error.log")
        try "seeded line\n".write(to: logFile, atomically: true, encoding: .utf8)
        let options = Xray.shared.options(log: Xray.shared.log(error: logFile.path))
        let session = Xray.shared.newSession()
        session.launchOverride = { _ in }
        defer { session.launchOverride = nil }
        try await session.start(.json(minimalJSON), options: options)
        let tail = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(tail.contains(where: { $0.contains("seeded line") }))
    }

    func testDeadlineStartAdoptsLogPaths() async throws {
        let logFile = tempDir.appendingPathComponent("deadline-error.log")
        try "seeded line\n".write(to: logFile, atomically: true, encoding: .utf8)
        let options = Xray.shared.options(log: Xray.shared.log(error: logFile.path))
        let session = Xray.shared.newSession()
        session.launchOverride = { _ in }
        defer { session.launchOverride = nil }
        try await session.start(.json(minimalJSON), options: options, deadline: .seconds(10))
        let tail = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(tail.contains(where: { $0.contains("seeded line") }))
    }

    func testFailedLaunchKeepsPreviousTail() async throws {
        // A successful run first, adopting its log file; then a launch
        // that fails must not clobber the recorded paths.
        let goodFile = tempDir.appendingPathComponent("good-error.log")
        try "good run\n".write(to: goodFile, atomically: true, encoding: .utf8)
        let session = Xray.shared.newSession()
        let options = Xray.shared.options(log: Xray.shared.log(error: goodFile.path))
        let goodJSON = try Xray.shared.configuration(.json(minimalJSON), options: options).json
        try session.start(rawJSON: goodJSON)
        let adopted = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(adopted.contains(where: { $0.contains("good run") }))
        // Rebuild with a different log file but fail the launch through
        // the deadline path (the only path with a launch seam): the
        // recorded path must still be the good run's.
        let badFile = tempDir.appendingPathComponent("bad-error.log")
        try "bad run\n".write(to: badFile, atomically: true, encoding: .utf8)
        let badOptions = Xray.shared.options(log: Xray.shared.log(error: badFile.path))
        let badJSON = try Xray.shared.configuration(.json(minimalJSON), options: badOptions).json
        session.launchOverride = { _ in throw XrayError.bridgeFailed("no engine here") }
        defer { session.launchOverride = nil }
        do {
            try await session.start(.json(badJSON), deadline: .seconds(10))
            XCTFail("expected .bridgeFailed")
        } catch let error as XrayError {
            guard case .bridgeFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let tail = try session.recentEngineLogs(.error, lines: 5)
        XCTAssertTrue(tail.contains(where: { $0.contains("good run") }))
        XCTAssertFalse(tail.contains(where: { $0.contains("bad run") }))
        try session.stop()
    }

    // MARK: - C4: build is pure, launch clears the stale fd

    func testBuildLeavesProcessEnvironmentAlone() throws {
        setenv("xray.tun.fd", "999", 1)
        setenv("XRAY_TUN_FD", "888", 1)
        let tun = try Xray.shared.tun()
        let config = try Xray.shared.configuration(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        XCTAssertEqual(String(cString: getenv("xray.tun.fd")), "999")
        XCTAssertEqual(String(cString: getenv("XRAY_TUN_FD")), "888")
        let object = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertNil(object["env"], "fd-less entry must not write env at build")
    }

    func testLaunchClearsStaleDescriptor() async throws {
        setenv("xray.tun.fd", "999", 1)
        setenv("XRAY_TUN_FD", "888", 1)
        let tun = try Xray.shared.tun()
        let session = Xray.shared.newSession()
        session.launchOverride = { _ in }
        defer { session.launchOverride = nil }
        try await session.start(
            .json(minimalJSON),
            options: Xray.shared.options(tun: tun),
            deadline: .seconds(10)
        )
        XCTAssertNil(getenv("xray.tun.fd"), "stale fd must be cleared at launch")
        XCTAssertNil(getenv("XRAY_TUN_FD"), "stale fd must be cleared at launch")
    }

    func testLaunchKeepsDocumentDescriptor() async throws {
        // A descriptor the document carries wins: a stale process fd is
        // irrelevant, and the document's own entry stays untouched.
        setenv("xray.tun.fd", "999", 1)
        let tun = try Xray.shared.tun(fileDescriptor: 7)
        let session = Xray.shared.newSession()
        session.launchOverride = { _ in }
        defer { session.launchOverride = nil }
        let config = try Xray.shared.configuration(
            .json(minimalJSON), options: Xray.shared.options(tun: tun)
        )
        try await session.start(.json(config.json), deadline: .seconds(10))
        let object = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(object["env"]?["xray.tun.fd"], .string("7"))
        XCTAssertEqual(
            String(cString: getenv("xray.tun.fd")),
            "999",
            "a descriptor the process already holds is not the session's to clear"
        )
    }

    // MARK: - H1: superseded launches stamp nothing

    func testLateSuccessAfterStopDoesNotStamp() async throws {
        let session = Xray.shared.newSession()
        // Semaphore gate: the launch settles only when released, so the
        // stop below always lands first no matter how slow the runner is.
        let release = DispatchSemaphore(value: 0)
        session.launchOverride = { _ in _ = release.wait(timeout: .now() + 30) }
        defer { session.launchOverride = nil }
        let task = Task { try await session.start(.json(minimalJSON), deadline: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        try session.stop()
        release.signal()
        try await task.value
        XCTAssertNil(session.connectedSince, "superseded launch must not stamp")
        XCTAssertFalse(try session.isRunning())
    }

    // MARK: - H2: the deadline bounds the wait itself

    func testDeadlineBoundsTheWait() async throws {
        let session = Xray.shared.newSession()
        // Semaphore gate: the timer cannot lose to the launch no matter
        // how slow the runner is; it only has to fire within the backstop.
        let release = DispatchSemaphore(value: 0)
        session.launchOverride = { _ in _ = release.wait(timeout: .now() + 30) }
        defer { session.launchOverride = nil }
        let started = Date()
        do {
            try await session.start(.json(minimalJSON), deadline: .milliseconds(100))
            XCTFail("expected .timedOut")
        } catch let error as XrayError {
            guard case .timedOut = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        release.signal()
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2.0,
            "the deadline must bound the call, not join the orphan"
        )
        XCTAssertNil(session.connectedSince)
    }

    // MARK: - ensureAssets rejects garbage before downloading

    func testEnsureAssetsRejectsUnparseableConfig() async throws {
        let config = XrayConfig(json: "[[[not json")
        do {
            _ = try await Xray.shared.ensureAssets(for: config, in: tempDir)
            XCTFail("expected .invalidInput")
        } catch let error as XrayError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("could not parse"))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.isEmpty, "nothing may be fetched for garbage input")
    }
}
