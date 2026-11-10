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
    /// own. Every call here blocks its caller thread while queued.
    /// Long `ping` and launch calls block too. Never run a package
    /// call on the main thread, and never call back into the engine from
    /// `transform` or `logger` closures: the lane does not re-enter, and
    /// a callback that calls in wedges its own thread until the outer
    /// call returns.
    private static let lane = DispatchQueue(label: "CoreXray.engine", qos: .userInitiated)

    internal static func guardRequestSize(_ request: String) throws {
        let bytes = request.utf8.count
        if bytes > maxRequestBytes {
            throw XrayError.invalidInput(
                "invoke request exceeds the 16 MiB size limit (requested: \(bytes) bytes)"
            )
        }
    }

    /// Lowest-level call: everything above goes through the serial lane.
    /// Size-checked here. The check covers the final envelope text with framing.
    /// A missing engine answer throws
    /// `.bridgeFailed` outright instead of a fabricated failure envelope,
    /// so a dead bridge can never look like an engine verdict.
    /// `CGoInvoke` takes a NUL-terminated copy of the UTF-8 bytes and the
    /// answer comes back the same way (`String(cString:)`): a response
    /// that is not valid UTF-8 traps at the boundary rather than
    /// producing a mojibake string, and a bridge that returns an
    /// unterminated pointer would over-read. Both are engine-side
    /// invariants this layer trusts, since every bundled binary has held
    /// them. If `CGoInvoke` itself wedges, the lane wedges with it: every
    /// later call queues behind it forever. `health()` detects this state
    /// (bounded round-trip); recovery is a process restart, because only
    /// the engine owns its stuck goroutine.
    internal static func rawCall(_ request: String) throws -> String {
        try guardRequestSize(request)
        // One pass: the byte buffer is built once and handed over
        // NUL-terminated, instead of counting the UTF-8 length and
        // then copying it into a second buffer.
        var bytes = Array(request.utf8)
        bytes.append(0)
        return try lane.sync {
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
            // Programmer error on our side, not a bridge failure: the
            // payload never reached the engine.
            throw XrayError.invalidInput("request payload could not be encoded: \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw XrayError.invalidInput("request payload could not be encoded as UTF-8 JSON")
        }
        return try rawCall("""
        {"apiVersion":\(protocolVersion),"method":"\(method.rawValue)","payload":\(text)}
        """)
    }

    /// Parses a raw engine response into its envelope. The decode cause
    /// is kept in the message: "unreadable" alone never says which key
    /// broke shape. Depth-checked first: the payload decodes
    /// recursively, so a hostile nesting depth (a thousand open braces
    /// in a row) would exhaust the stack. That crash is uncatchable. No
    /// error type can report. Legitimate engine answers nest a dozen
    /// deep at most; anything past 128 is an attack or corruption, and
    /// is rejected before decoding starts.
    internal static func envelope<Payload: Decodable>(
        of response: String,
        as type: Payload.Type
    ) throws -> Xray.EngineEnvelope<Payload> {
        try checkNestingDepth(of: response)
        do {
            return try JSONDecoder().decode(Xray.EngineEnvelope<Payload>.self, from: Data(response.utf8))
        } catch {
            throw XrayError.bridgeFailed("engine answered with an unreadable envelope: \(error.localizedDescription)")
        }
    }

    /// One cheap pass over the response text counting object/array
    /// nesting outside strings. String-aware (escapes honored), so a
    /// brace inside a quoted value never counts.
    private static func checkNestingDepth(of response: String, limit: Int = 128) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in response.utf8 {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > limit {
                    throw XrayError.bridgeFailed("engine answered with JSON nested past \(limit) levels: refusing to decode what would exhaust the stack")
                }
            case 0x7D, 0x5D: depth = max(0, depth - 1)
            default: break
            }
        }
    }

    /// Unwraps an envelope into its payload, raising `XrayError` on
    /// engine-reported failures. For status-only operations the payload is an
    /// empty object, so callers pass that unless they expect structured data.
    internal static func resolved<Payload: Decodable>(
        _ envelope: Xray.EngineEnvelope<Payload>
    ) throws -> Payload {
        guard envelope.succeeded else {
            // An empty message is not information: say the engine stayed
            // silent instead of handing the caller an empty string to
            // switch on.
            let message = envelope.failure.flatMap { $0.isEmpty ? nil : $0 }
            throw XrayError.engineFailed(message ?? "engine failure with no message")
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
    /// The `data` body decodes as an optional value the caller
    /// discards: the Go side has answered success with missing, null,
    /// object, and scalar `data` across versions, and a scalar body is
    /// still a successful operation. Only `success`/`error` decide,
    /// and no body shape can fail the call.
    internal static func acknowledge(_ method: Xray.Method) throws {
        try resolvedStatus(envelope: envelope(of: try send(method), as: XrayJSONValue?.self))
    }

    /// Runs a status-only operation with a payload, checking the envelope.
    internal static func acknowledge<Sent: Encodable>(_ method: Xray.Method, payload: Sent) throws {
        try resolvedStatus(envelope: envelope(of: try send(method, payload: payload), as: XrayJSONValue?.self))
    }

    /// Unwraps a status envelope: engine-reported failure raises
    /// `XrayError`, success returns. Never reads the body, so no body
    /// shape can fail a call the engine reported as successful.
    internal static func resolvedStatus<Payload: Decodable>(envelope: Xray.EngineEnvelope<Payload>) throws {
        guard envelope.succeeded else {
            let message = envelope.failure.flatMap { $0.isEmpty ? nil : $0 }
            throw XrayError.engineFailed(message ?? "engine failure with no message")
        }
    }

    /// Serializes a JSON tree to compact text, keys sorted so two builds of
    /// the same intent diff cleanly. `XrayJSONValue` is always encodable
    /// when read from a document, but transform closures can inject
    /// foreign values. Either way the value never reached the engine,
    /// so a failure here is `invalidInput`, not a bridge failure.
    internal static func serialize(_ value: XrayJSONValue) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(value)
            guard let text = String(data: data, encoding: .utf8) else {
                throw XrayError.invalidInput("assembled JSON tree is not valid UTF-8")
            }
            return text
        } catch let error as XrayError {
            throw error
        } catch {
            throw XrayError.invalidInput("assembled JSON tree could not be serialized (programmer error): \(error.localizedDescription)")
        }
    }
}

extension Xray {
    /// The operations the engine understands, keyed by the strings its Go
    /// side dispatches on.
    internal enum Method: String, Sendable {
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
    internal struct EngineEnvelope<Payload: Decodable>: Decodable, Sendable where Payload: Sendable {
        let succeeded: Bool
        let payload: Payload?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case succeeded = "success"
            case payload = "data"
            case failure = "error"
        }
    }

    /// Wraps a plain `xrayJson` string, the shape engine status operations
    /// and config round-trips read.
    internal struct ConfigPayload: Encodable, Sendable {
        let xrayJson: String
    }
}
