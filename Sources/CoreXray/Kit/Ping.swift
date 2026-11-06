import Foundation

// Network measurements the engine offers: per-server latency. Port discovery
// lives in `Ports.swift`; the wire encoding lives in `Calls/PingCalls.swift`.
// All validation happens here, before anything crosses the bridge.

/// One server to measure: its own compact Xray JSON plus the tag of the
/// outbound inside it that should be requested through. The JSON only
/// needs its `outbounds` — nothing else is read. A nil tag lets the
/// engine choose: the outbound tagged `"proxy"`, else the first one.
///
/// ```swift
/// Xray.shared.pingTarget(
///     config: #"{"outbounds":[{"tag":"proxy","protocol":"vless",...}]}"#,
///     outboundTag: "proxy"
/// )
/// ```
public struct XrayPingTarget: Encodable, Sendable {
    public var config: String
    public var outboundTag: String?

    internal init(config: String, outboundTag: String? = nil) {
        self.config = config
        self.outboundTag = outboundTag
    }

    enum CodingKeys: String, CodingKey {
        case config = "xrayJson"
        case outboundTag
    }
}

/// Measurement result for one target of `Xray.shared.ping`.
public struct XrayPingResult: Decodable, Sendable {
    /// Whether a full request completed through the outbound inside the
    /// timeout.
    public let succeeded: Bool

    /// Milliseconds from request start to completion. Zero when the
    /// request failed: the engine reports its own sentinels (10000 for
    /// timeouts, 11000 for routing failures) in `delay`, which are
    /// engine internals, not measurements — so they are normalized
    /// away here and the reason stays in `failureReason`.
    public let latencyMilliseconds: Int

    /// The engine's failure reason when `succeeded` is false.
    public let failureReason: String?

    /// Synthesized locally when the engine's answer for one target of
    /// a batch doesn't parse — the slot still answers its target.
    internal init(succeeded: Bool, latencyMilliseconds: Int, failureReason: String?) {
        self.succeeded = succeeded
        self.latencyMilliseconds = latencyMilliseconds
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case succeeded = "success"
        case latencyMilliseconds = "delay"
        case failureReason = "error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let succeeded = try container.decode(Bool.self, forKey: .succeeded)
        let delay = try container.decode(Int.self, forKey: .latencyMilliseconds)
        self.succeeded = succeeded
        self.latencyMilliseconds = succeeded ? delay : 0
        self.failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    }
}

/// Knobs for `Xray.shared.ping`. Defaults suit a quick server list; raise the
/// timeout for slow networks, point `testURL` at your own endpoint for
/// representative routing.
public struct XrayPingOptions: Sendable {
    /// Whole-batch deadline in seconds.
    public var timeoutSeconds: Int

    /// The HTTP endpoint fetched through every outbound.
    public var testURL: String

    internal init(
        timeoutSeconds: Int = 10,
        testURL: String = "https://www.google.com/generate_204"
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.testURL = testURL
    }
}

extension Xray {
    /// Measures connect latency, opening one engine connection per target.
    /// Same idea as the native Xray apps: each measurement completes a full
    /// HTTP request through the outbound, so success covers routing and TLS
    /// handshakes, not just a bare TCP probe. Blocks until every request
    /// finishes or the deadline passes.
    ///
    /// The engine measures in an isolated instance of its own, so it must be
    /// stopped first — measuring while running throws `.invalidInput`
    /// instead of the engine's refusal. The stopped check happens at call
    /// time: a start racing the call still fails at the engine, loudly.
    /// At most five targets per call.
    public func ping(_ targets: [XrayPingTarget], options: XrayPingOptions? = nil) throws -> [XrayPingResult] {
        guard !targets.isEmpty else {
            throw XrayError.invalidInput("ping needs at least one target")
        }
        let options = try options ?? pingOptions()
        guard targets.count <= 5 else {
            throw XrayError.invalidInput("ping measures at most 5 targets at once; split larger pools into batches")
        }
        // Batch inputs are checked before touching the engine: a blank
        // target poisons the whole batch (results are positional —
        // result[i] answers target[i]), so it fails here with its index
        // instead of somewhere inside the engine's converter. An empty
        // tag is a different mistake: nil means "the default outbound",
        // "" matches no outbound, so "" fails instead of measuring the
        // wrong thing.
        for (index, target) in targets.enumerated() {
            guard !target.config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw XrayError.invalidInput("ping target at index \(index) has an empty config")
            }
            if let tag = target.outboundTag, tag.isEmpty {
                throw XrayError.invalidInput("ping target at index \(index) has an empty outboundTag: use nil for the default outbound, not \"\"")
            }
        }
        guard options.timeoutSeconds > 0 else {
            throw XrayError.invalidInput("ping timeout must be greater than zero seconds")
        }
        guard let url = URL(string: options.testURL),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else {
            throw XrayError.invalidInput("ping testURL must be an absolute HTTP or HTTPS URL")
        }
        if try LifecycleCalls.isRunning() {
            throw XrayError.invalidInput("ping needs the engine stopped: stop the session first, measure, then start again")
        }
        return try PingCalls.measure(targets: targets, timeout: options.timeoutSeconds, url: options.testURL)
    }

    // MARK: - Types

}

// Value factories for ping inputs. The timeout is checked here so a bad
// value fails before the engine is even stopped.
extension Xray {
    public func pingTarget(config: String, outboundTag: String? = nil) -> XrayPingTarget {
        XrayPingTarget(config: config, outboundTag: outboundTag)
    }

    public func pingOptions(
        timeoutSeconds: Int = 10,
        testURL: String = "https://www.google.com/generate_204"
    ) throws -> XrayPingOptions {
        guard timeoutSeconds > 0 else {
            throw XrayError.invalidInput("ping timeout must be greater than zero seconds")
        }
        guard let url = URL(string: testURL),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else {
            throw XrayError.invalidInput("ping testURL must be an absolute HTTP or HTTPS URL")
        }
        return XrayPingOptions(timeoutSeconds: timeoutSeconds, testURL: testURL)
    }
}
