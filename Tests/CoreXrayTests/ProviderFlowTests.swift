import XCTest
@testable import CoreXray

// Provider-side flows: liveness, fd handoff, start deadlines, asset upkeep,
// and the assembly-time guards that keep a bad document from ever launching.

final class ProviderFlowTests: XCTestCase {
    private var tempDir: URL!
    private let minimalJSON = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#

    private var unreachable: URL {
        URL(string: "https://invalid-domain-that-does-not-exist-12345.com/geoip.dat")!
    }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXrayProviderFlowTests")
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? Xray.shared.stop()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Liveness

    func testHealthIsFalseWhenIdle() throws {
        try? Xray.shared.stop()
        XCTAssertFalse(try Xray.shared.health())
    }

    func testHealthIsTrueWhenRunning() throws {
        let session = Xray.shared.newSession()
        try session.start(rawJSON: minimalJSON)
        defer { try? session.stop() }
        XCTAssertTrue(try Xray.shared.health())
    }

    // MARK: - Start deadline

    func testDeadlineStartSucceedsWhenEngineIsFast() async throws {
        let session = Xray.shared.newSession()
        try await session.start(.json(minimalJSON), deadline: .seconds(30))
        defer { try? session.stop() }
        XCTAssertTrue(try session.isRunning())
    }

    // MARK: - XrayAssembly-time guards

    func testObservatoryWithoutMetricsPortThrowsAtBuild() throws {
        let observatory = try Xray.shared.observatory(subjectSelector: ["direct"])
        let options = Xray.shared.options(observatory: observatory)
        XCTAssertThrowsError(
            try XraySession().build(.json(minimalJSON), options: options)
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("metricsPort"), "message should name the missing field: \(message)")
        }
    }

    // MARK: - Provider fd handoff

    func testProviderFileDescriptorPassesThrough() throws {
        let fd = try Xray.shared.providerFileDescriptor(from: FakeFlow(FakeSocket(7)))
        XCTAssertEqual(fd, 7)
    }

    func testProviderFileDescriptorRejectsMissingSocket() {
        XCTAssertThrowsError(
            try Xray.shared.providerFileDescriptor(from: FakeFlow(nil))
        ) { error in
            guard case XrayError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testProviderFileDescriptorRejectsNegative() {
        XCTAssertThrowsError(
            try Xray.shared.providerFileDescriptor(from: FakeFlow(FakeSocket(-1)))
        ) { error in
            guard case XrayError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    // MARK: - Asset upkeep

    func testFetchMissingSkipsPresentFiles() async throws {
        // Both Xray databases begin with protobuf field 1, wiretype 2.
        let framing = Data([0x0A, 0x02, 0x00, 0x00])
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try framing.write(to: tempDir.appendingPathComponent("geoip.dat"))
        try framing.write(to: tempDir.appendingPathComponent("geosite.dat"))
        // Unreachable sources must never be touched: nothing is missing.
        try await Xray.shared.geoDownloader().fetchMissing(
            [.geosite, .geoip], into: tempDir, geoIPURL: unreachable, geoSiteURL: unreachable
        )
    }

    func testEnsureAssetsWithPlainConfigDownloadsNothing() async throws {
        let config = try XraySession().build(.json(minimalJSON))
        let directory = try await Xray.shared.ensureAssets(
            for: config, in: tempDir, geoIPURL: unreachable, geoSiteURL: unreachable
        )
        XCTAssertEqual(directory, tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("geoip.dat").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("geosite.dat").path))
    }

    func testEnsureAssetsDownloadsOnlyReferencedDatabase() async throws {
        let json = #"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["geosite:google"],"outboundTag":"proxy"}]}}"#
        let config = try XraySession().build(.json(json), options: .init(geoCheck: false))
        HTTPStub.replies = [HTTPStub.stubSite: HTTPStub.Reply(status: 200, body: Data([0x0A, 0x02, 0x00, 0x00]))]
        defer { HTTPStub.replies = [:] }
        var downloader = Xray.shared.geoDownloader(geoSiteURL: HTTPStub.stubSite)
        downloader.urlSession = HTTPStub.session()
        _ = try await Xray.shared.ensureAssets(for: config, in: tempDir, downloader: downloader)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("geosite.dat").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("geoip.dat").path))
    }
}

// KVC stand-ins for a packet flow: the helper only touches `socket` and
// `socket.fileDescriptor`, so these two properties are the whole contract.
private final class FakeSocket: NSObject {
    @objc var fileDescriptor: Int32
    init(_ fd: Int32) { fileDescriptor = fd }
}

private final class FakeFlow: NSObject {
    @objc var socket: FakeSocket?
    init(_ socket: FakeSocket?) { self.socket = socket }
}
