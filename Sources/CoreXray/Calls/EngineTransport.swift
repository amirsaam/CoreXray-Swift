import Foundation
import LibXray

// The only code that touches the C bridge. Every byte crossing into
// `CGoInvoke` goes through the serial lane here; every answer is decoded and
// unwrapped here. Domain callers (`LifecycleCalls`, `PingCalls`, …) own the
// *what*, this file owns the *how*. Nothing above this layer imports LibXray.

internal final class EngineTransport {
    /// Never instantiated: one serial lane, shared by the whole process.
    private init() {}

    /// Protocol number the engine accepts. This changes only if XTLS/libXray
    /// raises its version constant; a mismatch shows up as an
    /// "unsupported apiVersion" engine failure.
    internal static let protocolVersion = 3

    /// The engine refuses anything above 16 MiB; mirroring the bound here
    /// fails before a request crosses the bridge, saving the serialization
    /// and the round trip. The message matches the engine's own.
    internal static let maxRequestBytes = 16 * 1_024 * 1_024

    /// Serializes every byte that crosses the C boundary. The engine is
    /// process-global, so all traffic shares one lane: no two calls
    /// interleave inside `CGoInvoke`, and callers need no locking of their
    /// own. Do not call back into the engine from `transform` or `logger`
    /// closures.
    private static let lane = DispatchQueue(label: "CoreXray.engine", qos: .userInitiated)

    internal static func guardRequestSize(_ request: String) throws {
        let bytes = request.utf8.count
        if bytes > maxRequestBytes {
            throw XrayError.invalidInput(
                "invoke request exceeds the 16 MiB size limit (requested: \(bytes) bytes)"
            )
        }
    }

    /// Lowest-level call: serializes nothing, checks nothing. Everything
    /// above goes through the serial lane. A missing engine answer throws
    /// `.bridgeFailed` outright instead of a fabricated failure envelope,
    /// so a dead bridge can never look like an engine verdict.
    internal static func rawCall(_ request: String) throws -> String {
        try lane.sync {
            var bytes = Array(request.utf8CString)
            guard let response = CGoInvoke(&bytes) else {
                throw XrayError.bridgeFailed("the engine bridge returned no response: the engine may not be loaded")
            }
            defer { CGoFree(response) }
            return String(cString: response)
        }
    }

    /// Sends an operation with no payload.
    internal static func send(_ method: Xray.Method) throws -> String {
        try rawCall("""
        {"apiVersion":\(protocolVersion),"method":"\(method.rawValue)"}
        """)
    }

    /// Sends an operation with a payload, encoding it as JSON.
    internal static func send<Payload: Encodable>(_ method: Xray.Method, payload: Payload) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw XrayError.bridgeFailed("payload could not be encoded: \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw XrayError.bridgeFailed("payload could not be encoded as UTF-8 JSON")
        }
        try guardRequestSize(text)
        return try rawCall("""
        {"apiVersion":\(protocolVersion),"method":"\(method.rawValue)","payload":\(text)}
        """)
    }

    /// Parses a raw engine response into its envelope.
    internal static func envelope<Payload: Decodable>(
        of response: String,
        as type: Payload.Type
    ) throws -> Xray.EngineEnvelope<Payload> {
        do {
            return try JSONDecoder().decode(Xray.EngineEnvelope<Payload>.self, from: Data(response.utf8))
        } catch {
            throw XrayError.bridgeFailed("engine answered with an unreadable envelope")
        }
    }

    /// Unwraps an envelope into its payload, raising `XrayError` on
    /// engine-reported failures. For status-only operations the payload is an
    /// empty object, so callers pass that unless they expect structured data.
    internal static func resolved<Payload: Decodable>(
        _ envelope: Xray.EngineEnvelope<Payload>
    ) throws -> Payload {
        guard envelope.succeeded else {
            throw XrayError.engineFailed(envelope.failure ?? "engine failure with no message")
        }
        guard let payload = envelope.payload else {
            throw XrayError.bridgeFailed("engine reported success but answered without a payload")
        }
        return payload
    }

    /// Runs an operation and returns its decoded payload.
    internal static func ask<Payload: Decodable>(
        _ method: Xray.Method,
        as type: Payload.Type
    ) throws -> Payload {
        try resolved(envelope(of: try send(method), as: Payload.self))
    }

    /// Runs an operation with a payload and returns its decoded payload.
    internal static func ask<Payload: Decodable, Sent: Encodable>(
        _ method: Xray.Method,
        payload: Sent,
        as type: Payload.Type
    ) throws -> Payload {
        try resolved(envelope(of: try send(method, payload: payload), as: Payload.self))
    }

    /// Runs a status-only operation, checking the envelope for success.
    internal static func acknowledge(_ method: Xray.Method) throws {
        _ = try ask(method, as: Xray.EngineEnvelopeNoPayload.self)
    }

    /// Runs a status-only operation with a payload, checking the envelope.
    internal static func acknowledge<Sent: Encodable>(_ method: Xray.Method, payload: Sent) throws {
        _ = try ask(method, payload: payload, as: Xray.EngineEnvelopeNoPayload.self)
    }

    /// Serializes a JSON tree to compact text, keys sorted so two builds of
    /// the same intent diff cleanly. `XrayJSONValue` is always encodable, so
    /// failure here means programmer error, not bad input.
    internal static func serialize(_ value: XrayJSONValue) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(value)
            guard let text = String(data: data, encoding: .utf8) else {
                throw XrayError.bridgeFailed("assembled JSON is not valid UTF-8")
            }
            return text
        } catch let error as XrayError {
            throw error
        } catch {
            throw XrayError.bridgeFailed("JSON tree could not be serialized: \(error.localizedDescription)")
        }
    }
}

extension Xray {
    /// The operations the engine understands, keyed by the strings its Go
    /// side dispatches on.
    internal enum Method: String {
        case sparePorts = "getFreePorts"
        case decodeSubscription = "decodeSubscriptionText"
        case configFromShareLinks = "convertShareLinksToXrayJson"
        case shareLinksFromConfig = "convertXrayJsonToShareLinks"
        case newAgeKeys = "generateAgeKeyPair"
        case catalogGeoData = "countGeoData"
        case ping = "pingBatch"
        case checkConfig = "testXray"
        case launchEngine = "runXray"
        case stopEngine = "stopXray"
        case engineVersion = "xrayVersion"
        case engineState = "getXrayState"
    }

    /// Envelope every engine answer arrives in.
    internal struct EngineEnvelope<Payload: Decodable>: Decodable {
        let succeeded: Bool
        let payload: Payload?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case succeeded = "success"
            case payload = "data"
            case failure = "error"
        }
    }

    /// Stand-in payload for operations that only report success or failure.
    internal struct EngineEnvelopeNoPayload: Decodable {}

    /// Wraps a plain `xrayJson` string, the shape engine status operations
    /// and config round-trips read.
    internal struct ConfigPayload: Encodable {
        let xrayJson: String
    }
}
