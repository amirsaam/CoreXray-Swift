import XCTest
@testable import CoreXray

// Live-engine queries: version, idle state, ports, conversion. These download
// the versioned binary artifact once, then run against it like any consumer.

final class XrayTests: XCTestCase {
    func testVersionLooksLikeCalVer() throws {
        let version = try Xray.shared.version()
        XCTAssertFalse(version.isEmpty)
        let parts = version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "expected calver like 26.10.29, got \(version)")
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isNumber) })
    }

    func testEngineStartsIdle() throws {
        try Xray.shared.stop()
        XCTAssertFalse(try Xray.shared.isRunning())
    }

    func testFreePortsCountAndValidity() throws {
        let ports = try Xray.shared.findAvailablePorts(count: 3, excluding: [1, 2, 3])
        XCTAssertEqual(ports.count, 3)
        for port in ports {
            XCTAssertGreaterThan(port, 0)
            XCTAssertLessThan(port, 65536)
            XCTAssertFalse([1, 2, 3].contains(port))
        }
        XCTAssertEqual(Set(ports).count, ports.count, "ports must be unique")
    }

    func testShareLinkRoundTrip() throws {
        let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#TestLink"
        let config = try XrayConfig(shareLinks: link)
        XCTAssertFalse(config.json.isEmpty)
        try config.validate()
        let back = try config.shareLinks()
        XCTAssertTrue(back.contains("vless://"), "expected a vless link back, got: \(back)")
    }

    func testInvalidShareLinkThrows() {
        XCTAssertThrowsError(try XrayConfig(shareLinks: "not-a-link-at-all")) { error in
            XCTAssertTrue(error is XrayError, "expected XrayError, got \(type(of: error))")
        }
    }

    func testValidateRejectsGarbage() {
        XCTAssertThrowsError(try XrayConfig(json: "definitely not json").validate()) { error in
            guard let xrayError = error as? XrayError else {
                return XCTFail("expected XrayError, got \(type(of: error))")
            }
            if case .engineFailed(let message) = xrayError {
                XCTAssertFalse(message.isEmpty)
            } else {
                XCTFail("expected .engineFailed, got \(xrayError)")
            }
        }
    }

    func testAgeKeyPairShape() throws {
        let pair = try Xray.shared.generateAgeKeyPair()
        XCTAssertTrue(pair.secretKey.hasPrefix("AGE-SECRET-KEY-"))
        XCTAssertTrue(pair.publicKey?.hasPrefix("age1") ?? false)
    }

    func testSubscriptionDecode() throws {
        let out = try Xray.shared.decodeSubscription("vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp#X")
        XCTAssertTrue(out.contains("vless://"))
    }

    func testOversizedRequestFailsFastBeforeTheBridge() {
        // The engine refuses anything above 16 MiB; the kit mirrors the
        // bound so oversized requests never cross the bridge at all.
        let oversized = String(repeating: "x", count: EngineTransport.maxRequestBytes + 1)
        do {
            _ = try Xray.shared.sendRawRequest(oversized)
            XCTFail("expected a rejection")
        } catch let error as XrayError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("16 MiB"), "message should state the bound: \(message)")
        } catch {
            XCTFail("expected XrayError, got \(type(of: error))")
        }
    }

    func testSmallRequestStillReachesTheEngine() throws {
        // Proves the guard only trips its own case: a small garbage request
        // reaches the engine and comes back as an engine failure.
        XCTAssertThrowsError(try Xray.shared.sendRawRequest("{\"apiVersion\":3,\"method\":\"no-such-method\"}")) { error in
            guard case XrayError.engineFailed = error else {
                return XCTFail("expected .engineFailed, got \(error)")
            }
        }
    }
}
