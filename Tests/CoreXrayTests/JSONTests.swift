import XCTest
@testable import CoreXray

// The typed JSON tree: literals, subscripts, dynamic members, and a Codable
// round trip that preserves ints as ints.

final class JSONTests: XCTestCase {
    func testLiteralsBuildTrees() {
        let doc: XrayJSONValue = ["log": ["loglevel": "warning"], "retries": 3, "debug": false]
        XCTAssertEqual(doc["log"]?["loglevel"], .string("warning"))
        XCTAssertEqual(doc["retries"], .int(3))
        XCTAssertEqual(doc["debug"], .bool(false))
        XCTAssertNil(doc["missing"])
    }

    func testSubscriptWritesAndRemoves() {
        var doc: XrayJSONValue = ["a": 1]
        doc["b"] = ["nested": true]
        XCTAssertEqual(doc["b"]?["nested"], .bool(true))
        doc["a"] = nil
        XCTAssertNil(doc["a"])
        var scalar: XrayJSONValue = "text"
        scalar["key"] = 1
        XCTAssertEqual(scalar, .string("text"), "writing a field onto a scalar must not corrupt it")
    }

    func testArraySubscriptBoundsChecked() {
        var doc: XrayJSONValue = ["items": [1, 2, 3]]
        XCTAssertEqual(doc["items"]?[5], nil)
        XCTAssertEqual(doc["items"]?[1], .int(2))
        doc["items"]?[1] = 9
        XCTAssertEqual(doc["items"]?[1], .int(9))
        doc["items"]?[9] = 0
        XCTAssertEqual(doc["items"]?.arrayValue?.count, 3, "out-of-range write must not grow the array")
    }

    func testDynamicMemberInspection() {
        let doc: XrayJSONValue = ["log": ["loglevel": "warning"]]
        XCTAssertEqual(doc.log?.loglevel?.stringValue, "warning")
        XCTAssertNil(doc.nothing?.anything)
    }

    func testCodableRoundTrip() throws {
        let original: XrayJSONValue = [
            "int": 3,
            "double": 1.5,
            "text": "x",
            "flag": true,
            "nothing": nil,
            "list": [1, "two"],
            "nested": ["a": 1],
        ]
        let data = try JSONEncoder().encode(original)
        let revived = try JSONDecoder().decode(XrayJSONValue.self, from: data)
        XCTAssertEqual(revived, original)
        XCTAssertEqual(revived["int"], .int(3), "ints must survive as ints, not doubles")
    }

    func testInvalidJSONThrowsInvalidInput() {
        let session = XraySession()
        XCTAssertThrowsError(try session.build(.json("{oops"))) { error in
            guard let xrayError = error as? XrayError, case .invalidInput = xrayError else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }
}
