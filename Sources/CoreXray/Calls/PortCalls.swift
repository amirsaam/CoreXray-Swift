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
        try EngineTransport.ask(
            .sparePorts,
            payload: Xray.PortRequest(count: count, excluding: excluding),
            as: Xray.PortList.self
        ).ports ?? []
    }

    internal static func verify(count: Int, excluding: [Int]) throws -> [Int] {
        var verified: [Int] = []
        var excluded = excluding
        // Bounded rounds: each round asks the engine for the still-missing
        // remainder, so one bad round can't spin forever.
        for _ in 0 ..< 10 {
            let candidates = try spare(count: count - verified.count, excluding: excluded)
            if candidates.isEmpty { break }
            for port in candidates where !verified.contains(port) {
                excluded.append(port)
                if canBindTCPPort(port) {
                    verified.append(port)
                    if verified.count == count { return verified }
                }
            }
        }
        throw XrayError.bridgeFailed("could not find \(count) bindable local ports")
    }

    /// True when nothing on this machine is listening on `port` for
    /// 127.0.0.1 TCP — a best-effort check at call time, not a reservation.
    internal static func canBindTCPPort(_ port: Int) -> Bool {
        guard (1 ... 65_535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

extension Xray {
    internal struct PortRequest: Encodable {
        let count: Int
        let excluding: [Int]?

        enum CodingKeys: String, CodingKey {
            case count
            case excluding = "excludePorts"
        }
    }

    internal struct PortList: Decodable {
        let ports: [Int]?
    }
}
