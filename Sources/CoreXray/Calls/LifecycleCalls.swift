import Foundation

// Engine lifecycle and identity: version, state, launch, stop, and the raw
// escape hatch. No validation, no opinions — the friendly layer in
// `Kit/Lifecycle.swift` and `XraySession` decide when these run.

internal final class LifecycleCalls {
    /// Never instantiated: all members are static.
    private init() {}

    private struct EngineVersion: Decodable, Sendable {
        let version: String
    }

    private struct EngineState: Decodable, Sendable {
        let running: Bool
    }

    internal static func version() throws -> String {
        try EngineTransport.ask(.engineVersion, as: EngineVersion.self).version
    }

    internal static func isRunning() throws -> Bool {
        try EngineTransport.ask(.engineState, as: EngineState.self).running
    }

    internal static func launch(_ configuration: String) throws {
        try EngineTransport.acknowledge(.launchEngine, payload: Xray.ConfigPayload(xrayJson: configuration))
    }

    internal static func stop() throws {
        try EngineTransport.acknowledge(.stopEngine)
    }

    internal static func rawRequest(_ request: String) throws -> String {
        // Size-checked inside the transport, against the final text.
        let response = try EngineTransport.rawCall(request)
        _ = try EngineTransport.resolved(
            EngineTransport.envelope(of: response, as: Xray.EngineEnvelopeNoPayload.self)
        )
        return response
    }
}
