import Darwin
import XCTest
@testable import CoreXray

// XrayMetrics-over-HTTP: the assembly writes the metrics/stats/policy sections,
// the monitor parses /debug/vars, deltas turn snapshots into speed.

final class TrafficTests: XCTestCase {
    private let minimalOutbounds = #"{"outbounds":[{"protocol":"freedom","tag":"direct"}]}"#

    private func buildMetricsConfig(port: Int, baseJSON: String? = nil) throws -> XrayConfig {
        try XraySession().build(
            .json(baseJSON ?? minimalOutbounds),
            options: .init(metricsPort: port)
        )
    }

    private func document(_ config: XrayConfig) throws -> XrayJSONObject {
        let decoded = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        guard case .object(let dict) = decoded else {
            throw XCTSkip("assembled config is not an object")
        }
        return dict
    }

    // MARK: - XrayAssembly

    func testMetricsSectionsAreWritten() throws {
        let dict = try document(try buildMetricsConfig(port: 10085))
        XCTAssertEqual(dict["metrics"]?["listen"]?.stringValue, "127.0.0.1:10085")
        XCTAssertEqual(dict["metrics"]?["tag"]?.stringValue, "XrayMetrics")
        XCTAssertNotNil(dict["stats"]?.objectValue)
        let system = dict["policy"]?["system"]?.objectValue
        XCTAssertEqual(system?["statsInboundUplink"], .bool(true))
        XCTAssertEqual(system?["statsInboundDownlink"], .bool(true))
        XCTAssertEqual(system?["statsOutboundUplink"], .bool(true))
        XCTAssertEqual(system?["statsOutboundDownlink"], .bool(true))
    }

    func testPolicyMergeKeepsExistingKeys() throws {
        let base = #"{"outbounds":[{"protocol":"freedom","tag":"direct"}],"policy":{"levels":{"8":{"connIdle":300}},"system":{"connIdle":5}}}"#
        let dict = try document(try buildMetricsConfig(port: 10085, baseJSON: base))
        let system = dict["policy"]?["system"]?.objectValue
        XCTAssertEqual(system?["connIdle"]?.intValue, 5)
        XCTAssertEqual(system?["statsOutboundDownlink"], .bool(true))
        XCTAssertEqual(dict["policy"]?["levels"]?["8"]?["connIdle"]?.intValue, 300)
    }

    func testMetricsPortRangeIsRejectedAtAssembly() {
        XCTAssertThrowsError(try buildMetricsConfig(port: 0))
        XCTAssertThrowsError(try buildMetricsConfig(port: 70_000))
        do {
            _ = try buildMetricsConfig(port: 0)
            XCTFail("expected .invalidInput")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
    }

    // MARK: - Parsing

    private let cannedVars = """
    {
        "cmdline": ["xray"],
        "memstats": {"Alloc": 12345},
        "stats": {
            "inbound": {"tun-in": {"uplink": 100, "downlink": 200}},
            "outbound": {
                "proxy": {"uplink": 100, "downlink": 200},
                "direct": {"uplink": 0, "downlink": 0}
            }
        },
        "uptime": 42
    }
    """

    func testCannedVarsPayloadParses() throws {
        let snapshot = try XrayTrafficMonitor.decodeSnapshot(from: Data(cannedVars.utf8))
        XCTAssertEqual(snapshot.inbound["tun-in"]?.up, 100)
        XCTAssertEqual(snapshot.inbound["tun-in"]?.down, 200)
        XCTAssertEqual(snapshot.outbound["proxy"]?.total, 300)
        XCTAssertEqual(snapshot.outbound["direct"]?.total, 0)
        XCTAssertEqual(snapshot.totalUp, 200)
        XCTAssertEqual(snapshot.totalDown, 400)
    }

    func testMissingStatsDecodesToEmpty() throws {
        let snapshot = try XrayTrafficMonitor.decodeSnapshot(from: Data(#"{"memstats":{}}"#.utf8))
        XCTAssertTrue(snapshot.inbound.isEmpty)
        XCTAssertTrue(snapshot.outbound.isEmpty)
        XCTAssertEqual(snapshot.totalUp, 0)
    }

    func testGarbageVarsPayloadThrowsBridgeFailed() {
        XCTAssertThrowsError(try XrayTrafficMonitor.decodeSnapshot(from: Data("not json".utf8)))
    }

    func testObservatorySectionParsesWithEngineSpelling() throws {
        // Field names come straight off the engine's protobuf JSON tags
        // (metrics.go marshals OutboundStatus with encoding/json): alive,
        // delay, last_error_reason, last_seen_time, last_try_time, all
        // omitempty — so a dead outbound omits alive and delay entirely.
        let body = #"""
        {
          "handler": "v2ray.com.core.app.metrics.handler",
          "observatory": {
            "proxy-01": {
              "alive": true,
              "delay": 812,
              "outbound_tag": "proxy-01",
              "last_seen_time": 1699999999000,
              "last_try_time": 1699999999500
            },
            "dead-01": {
              "last_error_reason": "connection refused",
              "last_try_time": 1699999999510
            }
          }
        }
        """#
        let snapshot = try XrayTrafficMonitor.decodeSnapshot(from: Data(body.utf8))
        XCTAssertTrue(snapshot.inbound.isEmpty)
        let alive = try XCTUnwrap(snapshot.observatory["proxy-01"])
        XCTAssertTrue(alive.alive)
        XCTAssertEqual(alive.delayMilliseconds, 812)
        XCTAssertNil(alive.failureReason)
        XCTAssertEqual(alive.lastSeen, Date(timeIntervalSince1970: 1_699_999_999))
        XCTAssertEqual(alive.lastTry, Date(timeIntervalSince1970: 1_699_999_999.5))
        let dead = try XCTUnwrap(snapshot.observatory["dead-01"])
        XCTAssertFalse(dead.alive)
        XCTAssertNil(dead.delayMilliseconds) // failed probe: delay not reported
        XCTAssertEqual(dead.failureReason, "connection refused")
        XCTAssertNil(dead.lastSeen)
        XCTAssertEqual(dead.lastTry, Date(timeIntervalSince1970: 1_699_999_999.51))
    }

    func testObservatoryAbsentDecodesToEmpty() throws {
        let snapshot = try XrayTrafficMonitor.decodeSnapshot(from: Data(#"{"memstats":{}}"#.utf8))
        XCTAssertTrue(snapshot.observatory.isEmpty)
    }

    // MARK: - Deltas

    func testDeltaProducesRates() {
        let earlier = XrayTrafficSnapshot(
            taken: Date(timeIntervalSince1970: 1_000),
            outbound: ["proxy": XrayTrafficCounter(up: 1_000, down: 2_000)]
        )
        let later = XrayTrafficSnapshot(
            taken: Date(timeIntervalSince1970: 1_002),
            outbound: ["proxy": XrayTrafficCounter(up: 1_500, down: 3_000)]
        )
        let delta = later.delta(since: earlier)
        XCTAssertEqual(delta.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(delta.totalUp, 500)
        XCTAssertEqual(delta.totalDown, 1_000)
        XCTAssertEqual(delta.upPerSecond, 250, accuracy: 0.001)
        XCTAssertEqual(delta.downPerSecond, 500, accuracy: 0.001)
        XCTAssertEqual(delta.outbound["proxy"]?.up, 500)
    }

    func testDeltaClampsAcrossEngineRestart() {
        let earlier = XrayTrafficSnapshot(
            taken: Date(timeIntervalSince1970: 1_000),
            outbound: ["proxy": XrayTrafficCounter(up: 9_000, down: 9_000)]
        )
        let later = XrayTrafficSnapshot(
            taken: Date(timeIntervalSince1970: 1_001),
            outbound: ["proxy": XrayTrafficCounter(up: 10, down: 20)]
        )
        let delta = later.delta(since: earlier)
        XCTAssertEqual(delta.totalUp, 10)
        XCTAssertEqual(delta.totalDown, 20)
    }

    // MARK: - Bind check

    private func occupy(_ port: Int) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "could not occupy port \(port)")
        return descriptor
    }

    func testBindCheckSeesOccupiedPort() throws {
        let port = try Xray.shared.findAvailablePorts(count: 1)[0]
        XCTAssertTrue(PortCalls.canBindTCPPort(port))
        let held = occupy(port)
        defer { close(held) }
        XCTAssertFalse(PortCalls.canBindTCPPort(port))
    }

    func testBindCheckRejectsGarbage() {
        XCTAssertFalse(PortCalls.canBindTCPPort(0))
        XCTAssertFalse(PortCalls.canBindTCPPort(99_999))
        XCTAssertFalse(PortCalls.canBindTCPPort(-1))
    }

    func testVerifiedPortsAreBindable() throws {
        let ports = try Xray.shared.verifyAvailablePorts(count: 2)
        XCTAssertEqual(ports.count, 2)
        XCTAssertTrue(ports.allSatisfy(PortCalls.canBindTCPPort))
    }

    func testVerifiedPortsRejectsZeroCount() {
        XCTAssertThrowsError(try Xray.shared.verifyAvailablePorts(count: 0))
    }

    // MARK: - Live endpoint

    func testLiveMetricsEndpointServes() async throws {
        let port = try Xray.shared.verifyAvailablePorts(count: 1)[0]
        let config = try buildMetricsConfig(port: port)
        let session = XraySession()
        try session.start(config)
        defer { try? session.stop() }
        let monitor = XrayTrafficMonitor(port: port)
        var snapshot: XrayTrafficSnapshot?
        for _ in 0 ..< 40 {
            if let got = try? await monitor.snapshot() {
                snapshot = got
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(snapshot, "metrics endpoint never served a decodable body")
    }

    func testLiveTrafficCountersMove() async throws {
        let metricsPort = try Xray.shared.verifyAvailablePorts(count: 2)
        let socksPort = metricsPort[1]
        let base = #"{"outbounds":[{"protocol":"freedom","tag":"direct"}]}"#
        let config = try XraySession().build(
            .json(base),
            options: .init(
                transform: { dict in
                    dict["inbounds"] = .array([.object([
                        "tag": .string("socks-in"),
                        "protocol": .string("socks"),
                        "listen": .string("127.0.0.1"),
                        "port": .int(socksPort),
                        "settings": .object(["auth": .string("noauth"), "udp": .bool(true)]),
                    ])])
                },
                metricsPort: metricsPort[0]
            )
        )
        let session = XraySession()
        try session.start(config)
        defer { try? session.stop() }
        let monitor = XrayTrafficMonitor(port: metricsPort[0])
        var first: XrayTrafficSnapshot?
        for _ in 0 ..< 40 {
            if let got = try? await monitor.snapshot() {
                first = got
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let before = first else {
            throw XCTSkip("metrics endpoint never came up")
        }
        // Push bytes through the local SOCKS entry.
        let proxyConfig = URLSessionConfiguration.default
        proxyConfig.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": socksPort,
        ]
        let probeSession = URLSession(configuration: proxyConfig)
        _ = try? await probeSession.data(from: URL(string: "http://127.0.0.1:\(metricsPort[0])/debug/vars")!)
        var after: XrayTrafficSnapshot?
        for _ in 0 ..< 40 {
            if let got = try? await monitor.snapshot(), got.totalDown > before.totalDown {
                after = got
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(after, "counters never moved after traffic through the SOCKS entry")
    }

    func testMonitorRejectsBadPort() async {
        let monitor = XrayTrafficMonitor(port: 0)
        do {
            _ = try await monitor.snapshot()
            XCTFail("expected .invalidInput")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        } catch {
            XCTFail("expected XrayError, got \(error)")
        }
    }
}
