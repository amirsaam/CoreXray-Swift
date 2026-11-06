import Foundation

// Latency measurement through the engine. Stopped-engine precondition and
// argument validation live in the friendly layer (`Kit/Ping.swift`); this
// only encodes the task and decodes the answers.

internal final class PingCalls {
    /// Never instantiated: all members are static.
    private init() {}

    internal static func measure(
        targets: [XrayPingTarget],
        timeout: Int,
        url: String
    ) throws -> [XrayPingResult] {
        let payload = Xray.PingTaskPayload(configs: targets, timeout: timeout, url: url)
        let response = try EngineTransport.send(.ping, payload: payload)
        // Happy path first: a strict decode keeps shape errors loud.
        if let answers = try? EngineTransport.envelope(of: response, as: Xray.PingAnswers.self) {
            return try EngineTransport.resolved(answers).outcomes ?? []
        }
        // One bad entry must not poison the batch: decode element-wise
        // and synthesize a failure result for whatever doesn't parse, so
        // result[i] still answers targets[i].
        let raw = try EngineTransport.envelope(of: response, as: Xray.RawPingAnswers.self)
        let outcomes = try EngineTransport.resolved(raw).outcomes ?? []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try outcomes.map { element in
            let data = try encoder.encode(element)
            if let result = try? decoder.decode(XrayPingResult.self, from: data) {
                return result
            }
            return XrayPingResult(
                succeeded: false,
                latencyMilliseconds: 0,
                failureReason: "the engine answered with an undecodable measurement"
            )
        }
    }
}

extension Xray {
    internal struct PingTaskPayload: Encodable {
        let configs: [XrayPingTarget]
        let timeout: Int
        let url: String
    }

    internal struct PingAnswers: Decodable {
        let outcomes: [XrayPingResult]?

        enum CodingKeys: String, CodingKey {
            case outcomes = "results"
        }
    }

    /// Same envelope with untyped outcomes, for the element-wise
    /// fallback when one entry breaks the strict decode.
    internal struct RawPingAnswers: Decodable {
        let outcomes: [XrayJSONValue]?

        enum CodingKeys: String, CodingKey {
            case outcomes = "results"
        }
    }
}
