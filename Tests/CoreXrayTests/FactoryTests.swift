import XCTest
@testable import CoreXray

// Every user-constructed value has a factory twin on the shared instance.
// These tests pin the twins: same defaults as the inits, validation where
// a rule exists.

final class FactoryTests: XCTestCase {
    private let shared = Xray.shared

    func testSectionFactories() throws {
        let rule = shared.routingRule(domains: ["geosite:ads"], destination: .block)
        XCTAssertEqual(rule.domains, ["geosite:ads"])
        let routing = shared.routing(rules: [rule], final: .proxy)
        XCTAssertEqual(routing.rules.count, 1)

        let dns = shared.dns(hosts: ["example.com": "1.2.3.4"], queryStrategy: .useIPv4)
        XCTAssertEqual(dns.hosts["example.com"], "1.2.3.4")
        let pool = shared.fakeDNS(ipPool: "198.18.0.0/16", poolSize: 512)
        XCTAssertEqual(pool.poolSize, 512)

        XCTAssertEqual(shared.log(level: .warning).level, .warning)
    }

    func testEntryFactories() throws {
        let socks = try shared.socksEntry(port: 10880)
        XCTAssertEqual(socks.port, 10880)
        let http = try shared.httpEntry(port: 10881)
        XCTAssertEqual(http.port, 10881)
        let relay = try shared.dnsRelay()
        XCTAssertEqual(relay.remotePort, 53)

        XCTAssertThrowsError(try shared.socksEntry(port: 0))
        XCTAssertThrowsError(try shared.httpEntry(port: 99_999))
        XCTAssertThrowsError(try shared.dnsRelay(remotePort: -1))
    }

    func testSessionValueFactories() throws {
        let creds = shared.credentials(username: "u", password: "p")
        XCTAssertEqual(creds.username, "u")
        XCTAssertTrue(shared.sniffing().enabled)
        let opts = shared.options(routing: shared.routing(final: .proxy), geoCheck: false)
        XCTAssertFalse(opts.geoCheck)
    }

    func testTunFactory() throws {
        let tun = try shared.tun(name: "utun7", fileDescriptor: 9)
        XCTAssertEqual(tun.fileDescriptor, 9)
        XCTAssertThrowsError(try shared.tun(fileDescriptor: -1))
    }

    func testTrafficFactories() throws {
        let metrics = try shared.metrics(port: 24242)
        XCTAssertEqual(metrics.port, 24242)
        XCTAssertThrowsError(try shared.metrics(port: 0))
        let monitor = try shared.trafficMonitor(port: 24242)
        XCTAssertEqual(monitor.host, "127.0.0.1")
        XCTAssertEqual(try shared.observatory(subjectSelector: ["proxy"]).probeInterval, "1m")
    }

    func testPingFactories() throws {
        let target = shared.pingTarget(config: "{}", outboundTag: "proxy")
        XCTAssertEqual(target.outboundTag, "proxy")
        XCTAssertEqual(try shared.pingOptions().timeoutSeconds, 10)
        XCTAssertThrowsError(try shared.pingOptions(timeoutSeconds: 0))
    }

    func testProxyConfigurationPortValidation() throws {
        let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#F"
        XCTAssertThrowsError(try shared.proxyConfiguration(.shareLinks(link), socksPort: 0))
        XCTAssertThrowsError(try shared.proxyConfiguration(.shareLinks(link), httpPort: 70_000))
    }
}
