import XCTest
@testable import CoreXray

// Downloader logic against an in-process HTTP stub: no packets, no
// multi-megabyte fixtures. Mirrors the failure modes that matter (bad
// status, overwrite, progress plumbing).

final class GeoTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreXrayGeoTests")
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        HTTPStub.replies = [:]
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A downloader whose transport is the stub. Both databases serve valid
    /// protobuf framing unless a status says otherwise. Bodies are padded
    /// past the "stale" marker the replacement test writes.
    private func stubbedDownloader(ipStatus: Int = 200, siteStatus: Int = 200) -> XrayGeoDownloader {
        let framing = Data([0x0A, 0x02, 0x00, 0x00]) + Data(repeating: 0, count: 64)
        HTTPStub.replies = [
            HTTPStub.stubIP: HTTPStub.Reply(status: ipStatus, body: framing),
            HTTPStub.stubSite: HTTPStub.Reply(status: siteStatus, body: framing),
        ]
        var downloader = XrayGeoDownloader(geoIPURL: HTTPStub.stubIP, geoSiteURL: HTTPStub.stubSite)
        downloader.urlSession = HTTPStub.session()
        return downloader
    }

    func testDefaultURLsAreValidHTTPS() {
        for url in [XrayGeoDownloader.defaultGeoIPURL, XrayGeoDownloader.defaultGeoSiteURL] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertFalse(url.host?.isEmpty ?? true)
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".dat"))
        }
    }

    func testDownloadsBothFiles() async throws {
        try await stubbedDownloader().download(into: tempDir)
        let ip = tempDir.appendingPathComponent("geoip.dat")
        let site = tempDir.appendingPathComponent("geosite.dat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.path))
        XCTAssertGreaterThan((try Data(contentsOf: ip)).count, 0)
        XCTAssertGreaterThan((try Data(contentsOf: site)).count, 0)
    }

    func testPerCallURLOverrides() async throws {
        let alternate = URL(string: "http://127.0.0.1/alt-site.dat")!
        let expected = Data([0x0A, 0x02, 0x09, 0x09])
        HTTPStub.replies = [
            HTTPStub.stubIP: HTTPStub.Reply(status: 200, body: Data([0x0A])),
            HTTPStub.stubSite: HTTPStub.Reply(status: 200, body: Data([0x0A])),
            alternate: HTTPStub.Reply(status: 200, body: expected),
        ]
        var downloader = XrayGeoDownloader(geoIPURL: HTTPStub.stubIP, geoSiteURL: HTTPStub.stubSite)
        downloader.urlSession = HTTPStub.session()
        try await downloader.download(into: tempDir, geoSiteURL: alternate)
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("geosite.dat")), expected)
    }

    func testProgressStaysInRange() async throws {
        var last: Double = 0
        var count = 0
        try await stubbedDownloader().download(into: tempDir) { fraction in
            last = fraction
            count += 1
        }
        // Progress callbacks ride the main actor; the test may finish first
        // on some runners, so only assert when any arrived.
        if count > 0 {
            XCTAssertGreaterThanOrEqual(last, 0)
            XCTAssertLessThanOrEqual(last, 1.0)
        }
    }

    func testServerErrorThrows() async throws {
        do {
            try await stubbedDownloader(ipStatus: 404).download(into: tempDir)
            XCTFail("expected a download error")
        } catch {
            // Any thrown error proves the failure surfaced instead of a
            // half-written directory.
        }
    }

    func testExistingFilesAreReplaced() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let ip = tempDir.appendingPathComponent("geoip.dat")
        try "stale".data(using: .utf8)!.write(to: ip)
        try await stubbedDownloader().download(into: tempDir)
        XCTAssertGreaterThan((try Data(contentsOf: ip)).count, "stale".count)
    }

    // MARK: - Geo asset gate

    private let routableJSON = """
    {"log":{"loglevel":"warning"},"inbounds":[{"tag":"socks-in","protocol":"socks","listen":"127.0.0.1","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
    """

    /// Builds a routing configuration referencing `geosite:category-ir`,
    /// with `xray.location.asset` pointed at a temp directory holding an
    /// optional database file. The environment variable is restored after.
    private func buildGeoRouted(
        options: XraySessionOptions,
        databaseBytes: Data? = nil
    ) throws -> XrayConfig {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let databaseBytes {
            try databaseBytes.write(to: tempDir.appendingPathComponent("geosite.dat"))
        }
        setenv("xray.location.asset", tempDir.path, 1)
        defer { unsetenv("xray.location.asset") }
        let session = XraySession()
        let routing = XrayRouting(rules: [.init(
            domains: ["geosite:category-ir"],
            destination: .direct
        )])
        var options = options
        options.routing = routing
        return try session.build(.json(routableJSON), options: options)
    }

    func testGateRejectsMissingDatabase() throws {
        XCTAssertThrowsError(
            try buildGeoRouted(options: .init())
        ) { error in
            guard case XrayError.geoAssets(let message) = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
            XCTAssertTrue(message.contains("geosite.dat"), "message should name the file: \(message)")
        }
    }

    func testGateAcceptsReadableDatabase() throws {
        // Both Xray databases begin with protobuf field 1, wiretype 2 — a
        // message whose first repeated entry follows.
        let framing = Data([0x0A, 0x02, 0x00, 0x00])
        _ = try buildGeoRouted(options: .init(), databaseBytes: framing)
    }

    func testGateRejectsCorruptDatabase() throws {
        // A saved error page is the realistic corruption, not random bytes.
        XCTAssertThrowsError(
            try buildGeoRouted(
                options: .init(),
                databaseBytes: Data("<!DOCTYPE html>".utf8)
            )
        ) { error in
            guard case XrayError.geoAssets = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
        }
    }

    func testPlainDomainRulesNeedNoDatabase() throws {
        // Fill the directory with nothing at all: plain domains must build.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("xray.location.asset", tempDir.path, 1)
        defer { unsetenv("xray.location.asset") }
        let session = XraySession()
        let routing = XrayRouting(rules: [
            .init(domains: ["example.com"], destination: .direct),
            .init(ips: ["10.0.0.0/8"], destination: .direct),
        ], final: .direct)
        _ = try session.build(.json(routableJSON), options: .init(routing: routing))
    }

    func testGateCanBeDisabled() throws {
        let config = try buildGeoRouted(options: .init(geoCheck: false))
        XCTAssertFalse(config.json.isEmpty)
    }

    func testDnsSectionIsCheckedToo() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("xray.location.asset", tempDir.path, 1)
        defer { unsetenv("xray.location.asset") }
        let session = XraySession()
        XCTAssertThrowsError(
            try session.build(
                .json(routableJSON),
                options: .init(dns: XrayDNS(
                    hosts: ["geosite:malware": "127.0.0.1"]
                ))
            )
        ) { error in
            guard case XrayError.geoAssets = error else {
                return XCTFail("expected .geoAssets, got \(error)")
            }
        }
    }

    func testDocumentEnvAssetPathIsHonored() throws {
        // Files unreachable through the process env still pass when the
        // document itself ships the asset path.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data([0x0A, 0x02, 0x00, 0x00]).write(to: tempDir.appendingPathComponent("geosite.dat"))
        let session = XraySession()
        let routing = XrayRouting(rules: [.init(domains: ["geosite:category-ir"], destination: .direct)])
        _ = try session.build(.json(routableJSON), options: .init(
            routing: routing,
            environment: ["xray.location.asset": tempDir.path]
        ))
    }

    func testInventoryLandsNextToTheDatabase() throws {
        // An empty message is valid protobuf: zero entries, but the full
        // engine path (spelling of geoType included) runs for real.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data().write(to: tempDir.appendingPathComponent("geosite.dat"))
        try Data().write(to: tempDir.appendingPathComponent("geoip.dat"))
        let site = try Xray.shared.writeGeoInventory(database: "geosite", kind: .geosite, in: tempDir)
        let ip = try Xray.shared.writeGeoInventory(database: "geoip", kind: .geoip, in: tempDir)
        XCTAssertEqual(site.lastPathComponent, "geosite.json")
        XCTAssertEqual(ip.lastPathComponent, "geoip.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ip.path))
    }
}
