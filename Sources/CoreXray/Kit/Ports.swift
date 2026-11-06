import Foundation

// Port discovery on the shared instance. `findAvailablePorts` is the cheap
// snapshot for anything that just needs a free number; `verifyAvailablePorts`
// adds the local bind check for ports the engine will actually listen on.

extension Xray {
    /// Asks the engine for TCP ports nothing else on this machine is
    /// currently listening on, by checking. Nothing is killed, closed, or
    /// reserved: the answer is a snapshot, and a port can be taken between
    /// the answer and your launch. Handy for the inbound `port` fields of
    /// configurations that listen locally, so every launch can sit on a
    /// fresh pocket instead of a hardcoded port.
    public func findAvailablePorts(count: Int = 1, excluding: [Int] = []) throws -> [Int] {
        try PortCalls.spare(count: count, excluding: excluding)
    }

    /// Same as `findAvailablePorts`, but every returned port also passes a
    /// real TCP bind against 127.0.0.1 first — the engine's answer is a
    /// snapshot, and something else can grab a port between the answer and
    /// your launch. Ports that fail the bind are skipped (and never
    /// returned twice); throws `.bridgeFailed` when not enough bindable
    /// ports turn up. Prefer it for any port the engine will listen on.
    public func verifyAvailablePorts(count: Int = 1, excluding: [Int] = []) throws -> [Int] {
        guard count > 0 else {
            throw XrayError.invalidInput("verifyAvailablePorts needs a count of at least 1")
        }
        return try PortCalls.verify(count: count, excluding: excluding)
    }
}
