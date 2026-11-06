import XCTest
@testable import CoreXray

// Client-side guards for the engine's ping contract: at most five targets,
// positive timeout, absolute HTTP(S) URL, engine stopped, optional tag.

final class PingTests: XCTestCase {
    private func invalidInput(_ expression: @autoclosure () throws -> [XrayPingResult]) {
        do {
            _ = try expression()
            XCTFail("expected .invalidInput")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
    }

    func testEmptyTargetsThrow() {
        invalidInput(try Xray.shared.ping([]))
    }

    func testMoreThanFiveTargetsThrow() {
        let targets = (0..<6).map { _ in XrayPingTarget(config: #"{"outbounds":[]}"#) }
        invalidInput(try Xray.shared.ping(targets))
    }

    func testNonPositiveTimeoutThrows() {
        let target = XrayPingTarget(config: #"{"outbounds":[]}"#)
        invalidInput(try Xray.shared.ping([target], options: XrayPingOptions(timeoutSeconds: 0)))
        invalidInput(try Xray.shared.ping([target], options: XrayPingOptions(timeoutSeconds: -3)))
    }

    func testBadTestURLThrows() {
        let target = XrayPingTarget(config: #"{"outbounds":[]}"#)
        invalidInput(try Xray.shared.ping([target], options: XrayPingOptions(testURL: "not a url")))
        invalidInput(try Xray.shared.ping([target], options: XrayPingOptions(testURL: "/relative/path")))
        invalidInput(try Xray.shared.ping([target], options: XrayPingOptions(testURL: "ftp://files.example.com/x")))
    }

    func testNilOutboundTagEncodesAsNull() throws {
        let data = try JSONEncoder().encode(XrayPingTarget(config: #"{"outbounds":[]}"#))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: data)
        // A nil tag is omitted from the wire, which the engine reads as
        // empty and auto-selects from.
        XCTAssertNil(value["outboundTag"])
        XCTAssertEqual(value["xrayJson"], .string(#"{"outbounds":[]}"#))
    }

    func testPingWhileRunningThrowsWithoutDisturbingTheEngine() throws {
        let session = XraySession()
        try session.start(.json(#"{"outbounds":[{"protocol":"freedom"}]}"#))
        defer { try? session.stop() }
        let target = XrayPingTarget(config: #"{"outbounds":[{"protocol":"freedom"}]}"#)
        invalidInput(try Xray.shared.ping([target]))
        XCTAssertTrue(try session.isRunning())
    }

    func testEmptyLinkListDecodesAsEmptyString() throws {
        let list = try JSONDecoder().decode(Xray.LinkList.self, from: Data("{}".utf8))
        XCTAssertEqual(list.text, "")
    }
}
