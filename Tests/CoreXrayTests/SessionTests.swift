import XCTest
@testable import CoreXray

// XraySession assembly without launching: sniffing injection, transforms,
// dry-runs, logging. No engine contact except share-link conversion.

final class SessionTests: XCTestCase {
    private let minimalJSON = """
    {"log":{"loglevel":"warning"},"inbounds":[{"tag":"socks-in","protocol":"socks","listen":"127.0.0.1","port":1080}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
    """

    func testBuildFromJSONKeepsContent() throws {
        let session = XraySession()
        let config = try session.build(.json(minimalJSON))
        XCTAssertTrue(config.json.contains("socks-in"))
    }

    func testBuildRejectsNonObject() throws {
        let session = XraySession()
        do {
            _ = try session.build(.json("[1,2,3]"))
            XCTFail("expected an error")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testSniffingInjectedIntoBareInbounds() throws {
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(sniffing: XraySniffing(destOverride: ["http", "tls"]))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["inbounds"]?[0]?["sniffing"]?["enabled"], .bool(true))
        XCTAssertEqual(value["inbounds"]?[0]?["sniffing"]?["destOverride"], .array([.string("http"), .string("tls")]))
    }

    func testSniffingRespectsExistingSettings() throws {
        let withSniffing = """
        {"inbounds":[{"tag":"in","protocol":"socks","sniffing":{"enabled":false}}],"outbounds":[]}
        """
        let session = XraySession()
        let config = try session.build(
            .json(withSniffing),
            options: .init(sniffing: XraySniffing(enabled: true))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["inbounds"]?[0]?["sniffing"]?["enabled"], .bool(false))
    }

    func testTransformGetsLastWord() throws {
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(transform: { $0["log"] = ["loglevel": "error"] })
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["log"]?["loglevel"], .string("error"))
    }

    func testBuildDoesNotStartEngine() throws {
        try Xray.shared.stop()
        let session = XraySession()
        _ = try session.build(.json(minimalJSON))
        XCTAssertFalse(try session.isRunning())
    }

    func testLoggerSeesBuild() throws {
        var notes: [String] = []
        let session = XraySession(logger: { notes.append($0) })
        _ = try session.build(.json(minimalJSON))
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.joined().contains("assembled"))
    }

    func testShareLinkInputBuildsWithoutLaunching() throws {
        try Xray.shared.stop()
        let session = XraySession()
        let link = "vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"
        let config = try session.build(.shareLinks(link))
        XCTAssertTrue(config.json.contains("outbounds"))
        XCTAssertFalse(try session.isRunning())
    }

    func testStartStopLifecycle() throws {
        let session = XraySession()
        try session.start(rawJSON: """
        {"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
        """)
        XCTAssertTrue(try session.isRunning())
        try session.stop()
        XCTAssertFalse(try session.isRunning())
    }

    func testCredentialsGuardSocksInbound() throws {
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(credentials: XrayCredentials(username: "tun-user", password: "s3cret"))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let settings = value["inbounds"]?[0]?["settings"]
        XCTAssertEqual(settings?["auth"], .string("password"))
        XCTAssertEqual(settings?["users"]?[0]?["user"], .string("tun-user"))
        XCTAssertEqual(settings?["users"]?[0]?["pass"], .string("s3cret"))
    }

    func testCredentialsWithoutSocksInboundThrow() throws {
        let session = XraySession()
        do {
            _ = try session.build(
                .json(#"{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#),
                options: .init(credentials: XrayCredentials(username: "u", password: "p"))
            )
            XCTFail("expected an error")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testTunBuildAddsRealInboundWithoutLaunching() throws {
        try Xray.shared.stop()
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(tun: XrayTunEntry(
                gateway: ["198.18.0.1/15"],
                autoSystemRoutingTable: ["0.0.0.0/0"],
                autoOutboundsInterface: "auto"
            ))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let entry: XrayJSONValue = value["inbounds"]?.arrayValue?.first {
            $0["tag"]?.stringValue == "tunIn"
        } ?? .null
        XCTAssertEqual(entry["protocol"], .string("tun"))
        XCTAssertNil(entry["port"])
        XCTAssertEqual(entry["listen"], .string("127.0.0.1"))
        XCTAssertEqual(entry["settings"]?["mtu"], .int(1500))
        XCTAssertEqual(entry["settings"]?["gateway"], .array([.string("198.18.0.1/15")]))
        XCTAssertEqual(entry["settings"]?["autoSystemRoutingTable"], .array([.string("0.0.0.0/0")]))
        XCTAssertEqual(entry["settings"]?["autoOutboundsInterface"], .string("auto"))
        XCTAssertFalse(try session.isRunning())
    }

    func testTunEntryDefaultsAreMinimal() throws {
        let session = XraySession()
        let config = try session.build(.json(minimalJSON), options: .init(tun: XrayTunEntry()))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let entry: XrayJSONValue = value["inbounds"]?.arrayValue?.first {
            $0["tag"]?.stringValue == "tunIn"
        } ?? .null
        XCTAssertEqual(entry["settings"], .object(["mtu": .int(1500)]))
        // Default entries carry no sniffing of their own: with no session
        // sniffing either, no key is written (minimal stays minimal).
        XCTAssertNil(entry["sniffing"])
        // No descriptor, no env key: proxy-mode documents carry no tunnel state.
        XCTAssertNil(value["env"])
    }

    func testTunFullSettingsSerializeVerbatim() throws {
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(tun: XrayTunEntry(
                tag: "vpn",
                name: "utun10",
                mtu: 9000,
                gateway: ["10.0.0.1/16", "fc00::1/64"],
                userLevel: 8,
                autoSystemRoutingTable: ["0.0.0.0/0", "::/0"],
                autoOutboundsInterface: "en0"
            ))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let settings: XrayJSONValue = value["inbounds"]?.arrayValue?.first {
            $0["tag"]?.stringValue == "vpn"
        }?["settings"] ?? .null
        XCTAssertEqual(settings["name"], .string("utun10"))
        XCTAssertEqual(settings["mtu"], .int(9000))
        XCTAssertEqual(settings["gateway"], .array([.string("10.0.0.1/16"), .string("fc00::1/64")]))
        XCTAssertEqual(settings["userLevel"], .int(8))
        XCTAssertEqual(settings["autoSystemRoutingTable"], .array([.string("0.0.0.0/0"), .string("::/0")]))
        XCTAssertEqual(settings["autoOutboundsInterface"], .string("en0"))
    }

    func testTunFileDescriptorMergesIntoEnv() throws {
        let session = XraySession()
        let config = try session.build(
            .json(#"{"env":{"existing":"kept"},"inbounds":[],"outbounds":[]}"#),
            options: .init(tun: XrayTunEntry(fileDescriptor: 7))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["env"]?["xray.tun.fd"], .string("7"))
        XCTAssertEqual(value["env"]?["existing"], .string("kept"))
    }

    func testTunWithoutDescriptorClearsAtLaunch() async throws {
        // The engine applies document env into its process at launch and
        // never unsets; a descriptor from an earlier tunnel session must not
        // hijack the next fd-less launch. Building alone is pure and leaves
        // the process env untouched; launching clears the stale descriptor.
        // (The instant override stands in for the bridge: no engine runs.)
        setenv("xray.tun.fd", "99", 1)
        setenv("XRAY_TUN_FD", "99", 1)
        defer {
            unsetenv("xray.tun.fd")
            unsetenv("XRAY_TUN_FD")
        }
        let session = XraySession()
        _ = try session.build(.json(minimalJSON), options: .init(tun: XrayTunEntry()))
        XCTAssertEqual(String(cString: getenv("xray.tun.fd")), "99")
        XCTAssertEqual(String(cString: getenv("XRAY_TUN_FD")), "99")
        session.launchOverride = { _ in }
        defer { session.launchOverride = nil }
        try await session.start(
            .json(minimalJSON), options: .init(tun: XrayTunEntry()), deadline: .seconds(10)
        )
        XCTAssertNil(getenv("xray.tun.fd"))
        XCTAssertNil(getenv("XRAY_TUN_FD"))
    }

    func testEnvironmentMergesIntoDocumentEnv() throws {
        let session = XraySession()
        let config = try session.build(
            .json(#"{"env":{"existing":"kept"},"inbounds":[],"outbounds":[]}"#),
            options: .init(environment: ["xray.location.asset": "/var/db/geo"])
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["env"]?["xray.location.asset"], .string("/var/db/geo"))
        XCTAssertEqual(value["env"]?["existing"], .string("kept"))
    }

    func testEnvironmentDoesNotOverwriteDocumentEnv() throws {
        let session = XraySession()
        let config = try session.build(
            .json(#"{"env":{"xray.location.asset":"/document/path"},"inbounds":[],"outbounds":[]}"#),
            options: .init(environment: ["xray.location.asset": "/options/path"])
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["env"]?["xray.location.asset"], .string("/document/path"))
    }

    func testTunCredentialsLeaveTunInboundAlone() throws {
        let session = XraySession()
        let config = try session.build(
            .json(minimalJSON),
            options: .init(
                credentials: XrayCredentials(username: "app-user", password: "s3cret"),
                tun: XrayTunEntry()
            )
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        // The SOCKS entry is guarded...
        XCTAssertEqual(value["inbounds"]?[0]?["settings"]?["auth"], .string("password"))
        // ...the TUN entry carries no auth at all.
        let tun: XrayJSONValue = value["inbounds"]?.arrayValue?.first {
            $0["tag"]?.stringValue == "tunIn"
        } ?? .null
        XCTAssertNil(tun["settings"]?["auth"])
    }

    func testTunValidatePassesAgainstEngine() throws {
        // Proves the shipped stock engine resolves "protocol": "tun":
        // validate constructs the full instance without starting it.
        let session = XraySession()
        try session.validate(.json(minimalJSON), options: .init(tun: XrayTunEntry(
            gateway: ["198.18.0.1/15"],
            autoSystemRoutingTable: ["0.0.0.0/0"]
        )))
    }

    func testNilTunEntryMeansProxyMode() throws {
        let session = XraySession()
        let config = try session.build(.json(minimalJSON))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let tags = value["inbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertFalse(tags.contains("tunIn"))
        XCTAssertNil(value["env"])
    }

    func testVerbatimRoutingWrittenAsIs() throws {
        let session = XraySession()
        let routing = XrayRouting(
            domainStrategy: .ipIfNonMatch,
            rules: [
                .init(
                    domains: ["geosite:ads", "full:tracker.example.com"],
                    destination: .custom("proxy")
                ),
                .init(
                    ips: ["geoip:private", "192.168.0.0/16"],
                    port: "80,443",
                    network: "tcp",
                    protocols: ["http", "tls"],
                    inboundTags: ["tunIn"],
                    destination: .direct
                ),
            ],
            final: .custom("proxy")
        )
        let config = try session.build(.json(minimalJSON), options: .init(
            routing: routing,
            // Wire-shape test: the geo references are spellings under test,
            // not files that need to exist.
            geoCheck: false
        ))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["routing"]?["domainStrategy"], .string("IPIfNonMatch"))
        XCTAssertEqual(value["routing"]?["rules"]?[0]?["domain"], .array([.string("geosite:ads"), .string("full:tracker.example.com")]))
        XCTAssertEqual(value["routing"]?["rules"]?[0]?["outboundTag"], .string("proxy"))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["ip"], .array([.string("geoip:private"), .string("192.168.0.0/16")]))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["port"], .string("80,443"))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["network"], .string("tcp"))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["protocol"], .array([.string("http"), .string("tls")]))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["inboundTag"], .array([.string("tunIn")]))
        XCTAssertEqual(value["routing"]?["rules"]?[1]?["outboundTag"], .string("direct"))
        // No "final" key (the engine ignores it): the destination arrives
        // as a trailing `network: "tcp,udp"` rule instead — the engine
        // rejects a condition-less rule, and every connection it routes is
        // TCP or UDP.
        XCTAssertNil(value["routing"]?["final"])
        let lastRule = value["routing"]?["rules"]?.arrayValue?.last
        XCTAssertEqual(lastRule?["type"], .string("field"))
        XCTAssertEqual(lastRule?["outboundTag"], .string("proxy"))
        XCTAssertEqual(lastRule?["network"], .string("tcp,udp"))
        XCTAssertEqual(Set((lastRule?.objectValue ?? [:]).keys), ["type", "network", "outboundTag"])
        // "direct" already exists in the skeleton, so nothing is duplicated.
        let tags = value["outbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? []
        XCTAssertEqual(tags.filter { $0 == "direct" }.count, 1)
    }

    func testProxyDestinationResolvesToConvertedTag() throws {
        let session = XraySession()
        let config = try session.build(
            .shareLinks("vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node"),
            options: .init(routing: XrayRouting(final: .proxy))
        )
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["outbounds"]?[0]?["tag"], .string("Node"))
        XCTAssertNil(value["routing"]?["final"])
        XCTAssertEqual(value["routing"]?["rules"]?.arrayValue?.last?["outboundTag"], .string("Node"))
    }

    func testUntaggedProxyGetsProxyTag() throws {
        let session = XraySession()
        // A real proxy without a tag earns the name: later stages agree
        // on "proxy" for it.
        let proxied = #"{"inbounds":[],"outbounds":[{"protocol":"vless","settings":{}}]}"#
        let config = try session.build(.json(proxied), options: .init(routing: XrayRouting(final: .proxy)))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertEqual(value["outbounds"]?[0]?["tag"], .string("proxy"))
        XCTAssertNil(value["routing"]?["final"])
        XCTAssertEqual(value["routing"]?["rules"]?.arrayValue?.last?["outboundTag"], .string("proxy"))
    }

    func testFreedomNeverMasqueradesAsProxy() throws {
        let session = XraySession()
        // Labelling a freedom outbound "proxy" once sent tunnel traffic
        // around the tunnel. Now it throws and names the fix instead.
        let bare = #"{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#
        XCTAssertThrowsError(
            try session.build(.json(bare), options: .init(routing: XrayRouting(final: .proxy)))
        ) { error in
            guard case XrayError.invalidInput(let message) = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains(".direct"), "got: \(message)")
        }
    }

    func testRoutingToProxyWithoutOutboundsThrows() throws {
        let session = XraySession()
        do {
            _ = try session.build(.json(#"{"inbounds":[]}"#), options: .init(routing: XrayRouting(final: .proxy)))
            XCTFail("expected an error")
        } catch let error as XrayError {
            guard case .invalidInput = error else {
                XCTFail("wrong error: \(error)")
                return
            }
        }
    }

    func testMissingStandardsAreAddedOnce() throws {
        let session = XraySession()
        let bare = #"{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#
        let routing = XrayRouting(
            rules: [
                .init(domains: ["example.com"], destination: .block),
                .init(inboundTags: ["dns-in"], destination: .dns),
            ],
            final: .direct
        )
        let config = try session.build(.json(bare), options: .init(routing: routing))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        let outbounds = value["outbounds"]?.arrayValue ?? []
        let tags = outbounds.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags.filter { $0 == "direct" }.count, 1)
        XCTAssertTrue(tags.contains("block"))
        XCTAssertTrue(tags.contains("dns-out"))
        XCTAssertEqual(value["outbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("block") })?["protocol"], .string("blackhole"))
        XCTAssertEqual(value["outbounds"]?.arrayValue?.first(where: { $0["tag"] == .string("dns-out") })?["protocol"], .string("dns"))
    }

    func testNoRoutingLeavesDocumentAlone() throws {
        let session = XraySession()
        let config = try session.build(.json(minimalJSON))
        let value = try JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8))
        XCTAssertNil(value["routing"])
    }

    // MARK: - Live TUN file-descriptor hand-off

    func testTunLaunchesWithHandedOffDescriptor() throws {
        // Proves the `xray.tun.fd` carrier works against the shipped stock
        // engine: the pipe's read end is offered the way NetworkExtension
        // would offer a utun descriptor, and the engine launches with it
        // instead of creating an interface of its own. Creating a utun
        // itself fails unprivileged ("operation not permitted") — which is
        // exactly why interfaces are handed over rather than created — so a
        // successful start proves the descriptor was adopted, not ignored.
        try Xray.shared.stop()
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw XrayError.bridgeFailed("pipe for descriptor hand-off failed")
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        let session = XraySession()
        try session.start(
            .json(#"{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#),
            options: .init(tun: XrayTunEntry(fileDescriptor: fds[0]))
        )
        XCTAssertTrue(try session.isRunning())
        try session.stop()
        XCTAssertFalse(try session.isRunning())
    }

    /// Opens one utun interface through the same control socket Xray-core's
    /// darwin tun code uses; no privileged operations involved.
    private static func openUtunDevice() throws -> Int32 {
        /// `_IOWR('N', 132, struct ctl_info)` — the kernel's id-lookup ioctl.
        /// Not a plain constant on the Swift side, hence spelled out.
        let ctlIOCGInfo: UInt = 0xC064_4E84

        var info = ctl_info()
        let identifier = "com.apple.net.utun_control"
        let nameLength = identifier.utf8.count
        precondition(nameLength < MemoryLayout.size(ofValue: info.ctl_name))
        identifier.data(using: .utf8)!.withUnsafeBytes { bytes in
            _ = memcpy(&info.ctl_name, bytes.baseAddress, nameLength)
        }
        let socketFD = socket(AF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard socketFD >= 0 else {
            throw XrayError.bridgeFailed("utun control socket could not be opened")
        }
        guard ioctl(socketFD, ctlIOCGInfo, &info) == 0 else {
            close(socketFD)
            throw XrayError.bridgeFailed("utun control id lookup failed")
        }
        var address = sockaddr_ctl()
        address.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        address.sc_family = UInt8(AF_SYSTEM)
        address.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        address.sc_id = info.ctl_id
        address.sc_unit = 0 // any free unit
        var connected = false
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                connected = Darwin.connect(socketFD, sockPointer, socklen_t(MemoryLayout<sockaddr_ctl>.size)) == 0
            }
        }
        guard connected else {
            close(socketFD)
            throw XrayError.bridgeFailed("utun connect failed")
        }
        return socketFD
    }
}
