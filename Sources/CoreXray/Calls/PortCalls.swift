import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Port discovery: the engine's candidate list, plus the local bind check that
// closes the check-then-use hole. The friendly layer (`Kit/Ports.swift`)
// validates input; everything here assumes sane arguments.

internal final class PortCalls {
    /// Never instantiated: all members are static.
    private init() {}

    internal static func spare(count: Int, excluding: [Int]) throws -> [Int] {
        // Strict about shape, lenient about count: a missing list is a
        // broken answer, but `verify` legitimately asks for remainders —
        // and an answer with fewer ports than asked just yields fewer.
        let ports = try EngineTransport.ask(
            .sparePorts,
            payload: Xray.PortRequest(count: count, excluding: excluding),
            as: Xray.PortList.self
        ).ports
        guard ports.allSatisfy({ (1 ... 65_535).contains($0) }) else {
            throw XrayError.bridgeFailed("the engine answered with ports outside 1...65535")
        }
        // Order-preserving dedupe: the engine may repeat a port across
        // its answer, and a duplicate handed out twice would collide
        // two listeners with each other.
        var seen: Set<Int> = []
        return ports.filter { seen.insert($0).inserted }
    }

    internal static func verify(count: Int, excluding: [Int]) throws -> [Int] {
        var verified: [Int] = []
        var excluded = excluding
        // A privileged port is skipped, not fatal: the engine's
        // candidates may include one, and a single privileged port
        // must not poison the good ones around it. Remembered, so an
        // exhausted search can still name privileges as the cause.
        var sawPrivileged = false
        // Bounded rounds: each round asks the engine for the still-missing
        // remainder, so one bad round can't spin forever.
        for _ in 0 ..< 10 {
            let candidates = try spare(count: count - verified.count, excluding: excluded)
            if candidates.isEmpty { break }
            for port in candidates where !verified.contains(port) {
                excluded.append(port)
                // One probe per family: TCP first (the listener the
                // package itself opens), then UDP (engine inbounds
                // listen on UDP by default). A refusal names itself —
                // EACCES is privileges, anything else is in use.
                if let failure = bindErrno(for: port, udp: false) ?? bindErrno(for: port, udp: true) {
                    if failure == EACCES { sawPrivileged = true }
                    continue
                }
                verified.append(port)
                if verified.count == count { return verified }
            }
        }
        if sawPrivileged {
            throw XrayError.invalidInput("could not find \(count) bindable local ports and some candidates needed privileges the app does not have (ports below 1024): exclude them or add the right entitlement")
        }
        throw XrayError.bridgeFailed("could not find \(count) bindable local ports")
    }

    /// True when nothing on this machine is listening on `port` for
    /// 127.0.0.1 TCP — a best-effort check at call time, not a reservation.
    internal static func canBindTCPPort(_ port: Int) -> Bool {
        bindErrno(for: port, udp: false) == nil
    }

    /// Same check for UDP: engine inbounds listen on UDP by default
    /// (SOCKS especially), so a TCP-only check can clear a port the
    /// launch then fails on.
    internal static func canBindUDPPort(_ port: Int) -> Bool {
        bindErrno(for: port, udp: true) == nil
    }

    /// The raw bind probe: nil means the port bound (and was released),
    /// otherwise the errno. UDP probes skip `SO_REUSEADDR` — the engine
    /// binds raw, so the check must too. Wildcard and IPv6 listeners are
    /// out of scope: this only sees 127.0.0.1, which the probe, and the
    /// package's own listeners, all use.
    internal static func bindErrno(for port: Int, udp: Bool) -> Int32? {
        guard (1 ... 65_535).contains(port) else { return EINVAL }
        let descriptor = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, udp ? IPPROTO_UDP : IPPROTO_TCP)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var address = sockaddr_in()
        // `sin_len` exists only on Darwin; the Glibc layout has no such
        // field, so setting it must stay Apple-only.
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound: Bool = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return bound ? nil : errno
    }
}

extension Xray {
    internal struct PortRequest: Encodable, Sendable {
        let count: Int
        let excluding: [Int]?

        enum CodingKeys: String, CodingKey {
            case count
            case excluding = "excludePorts"
        }
    }

    internal struct PortList: Decodable, Sendable {
        let ports: [Int]
    }
}
