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
        // Happy path first. The strict failure is kept, so the fallback
        // can report both causes instead of discarding the more
        // informative one.
        let strictOutcomes: [XrayPingResult]?
        let strictError: Error?
        do {
            let answers = try EngineTransport.envelope(of: response, as: Xray.PingAnswers.self)
            strictOutcomes = try EngineTransport.resolved(answers).outcomes
            strictError = nil
        } catch {
            strictOutcomes = nil
            strictError = error
        }
        // A missing `results` key is a shape error, not an empty batch:
        // strict decoding keeps it loud instead of returning silence.
        if let strictOutcomes {
            guard strictOutcomes.count == targets.count else {
                throw XrayError.bridgeFailed(
                    "the engine answered \(strictOutcomes.count) measurements for \(targets.count) targets: result[i] would no longer answer targets[i]"
                )
            }
            return strictOutcomes
        }
        // One bad entry must not poison the batch: decode element-wise
        // and synthesize a failure result for whatever doesn't parse, so
        // result[i] still answers targets[i].
        let rawOutcomes: [XrayJSONValue]
        do {
            let raw = try EngineTransport.envelope(of: response, as: Xray.RawPingAnswers.self)
            rawOutcomes = try EngineTransport.resolved(raw).outcomes
        } catch {
            throw XrayError.bridgeFailed(
                "ping answers undecodable (strict: \(strictError.map { "\($0)" } ?? "none"); raw: \(error))"
            )
        }
        guard rawOutcomes.count == targets.count else {
            throw XrayError.bridgeFailed(
                "the engine answered \(rawOutcomes.count) measurements for \(targets.count) targets: result[i] would no longer answer targets[i]"
            )
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try rawOutcomes.map { element in
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
    internal struct PingTaskPayload: Encodable, Sendable {
        let configs: [XrayPingTarget]
        let timeout: Int
        let url: String
    }

    internal struct PingAnswers: Decodable, Sendable {
        let outcomes: [XrayPingResult]

        enum CodingKeys: String, CodingKey {
            case outcomes = "results"
        }
    }

    /// Same envelope with untyped outcomes, for the element-wise
    /// fallback when one entry breaks the strict decode.
    internal struct RawPingAnswers: Decodable, Sendable {
        let outcomes: [XrayJSONValue]

        enum CodingKeys: String, CodingKey {
            case outcomes = "results"
        }
    }
}
