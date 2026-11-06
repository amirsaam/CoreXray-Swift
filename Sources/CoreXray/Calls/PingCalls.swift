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
        try EngineTransport.ask(
            .ping,
            payload: Xray.PingTaskPayload(configs: targets, timeout: timeout, url: url),
            as: Xray.PingAnswers.self
        ).outcomes ?? []
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
}
