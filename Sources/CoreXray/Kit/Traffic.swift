import Foundation

// Live traffic insight without new dependencies: the engine already ships a
// XrayMetrics HTTP endpoint that publishes per-tag byte counters. Point the
// assembly at a `metricsPort`, launch, then poll the endpoint with
// `XrayTrafficMonitor` — speed is the delta between snapshots, totals are the
// running sum. Works with the stock engine on every supported OS.

/// The engine's XrayMetrics HTTP service: one object, one localhost listener.
/// Wired in by `metricsPort`, so you never spell the section by hand:
///
/// ```swift
/// var assembly = Xray.shared.assembler(.shareLinks(text))
/// assembly.metricsPort = 10085
/// let config = try assembly.assemble()
/// ```
public struct XrayMetrics: Sendable {
    /// Section tag. Cosmetic to the engine — counters are keyed by
    /// inbound/outbound tag, not by this — it only labels the section
    /// for readers of the JSON. `options(metricsPort:)` always wires
    /// the default tag; a custom tag travels only when you place the
    /// section yourself (raw JSON or a transform).
    public var tag: String
    /// Localhost port serving `/debug/vars`. Keep it out of the ports
    /// your entries listen on; `verifyAvailablePorts` finds a safe one.
    public var port: Int

    internal init(tag: String = "XrayMetrics", port: Int) {
        self.tag = tag
        self.port = port
    }

    var wireObject: XrayJSONObject {
        [
            "tag": .string(tag),
            "listen": .string("127.0.0.1:\(port)"),
        ]
    }
}

/// Byte counters for one inbound or outbound tag, as published by the
/// engine. Cumulative since engine start; the engine zeroes them only on
/// restart, so deltas across a restart clamp instead of going negative.
public struct XrayTrafficCounter: Sendable {
    public var up: Int64
    public var down: Int64

    internal init(up: Int64 = 0, down: Int64 = 0) {
        self.up = up
        self.down = down
    }

    public var total: Int64 { up &+ down }

    /// Later minus earlier. If the later reading is smaller, the engine
    /// restarted between snapshots and "before" is meaningless — so the
    /// whole later reading counts as new traffic instead of clamping to
    /// zero and silently dropping post-restart bytes.
    func delta(since earlier: XrayTrafficCounter) -> XrayTrafficCounter {
        XrayTrafficCounter(
            up: up >= earlier.up ? up - earlier.up : up,
            down: down >= earlier.down ? down - earlier.down : down
        )
    }
}

/// Per-outbound health probing, told to the engine as the `observatory`
/// section. Every outbound whose tag matches one of the `subjectSelector`
/// prefixes gets an HTTP probe through itself on the configured interval;
/// results land in the XrayMetrics endpoint and surface as
/// `XrayTrafficSnapshot.observatory`. Requires `metricsPort` to be set —
/// probing without metrics has no readable results.
///
/// The factory rejects an empty selector, a non-http(s) probe URL, and a
/// malformed Go interval up front. What it cannot check is whether the
/// selector matches anything: a selector no outbound tag starts with
/// probes nothing and reports nothing — silently. After launch, confirm
/// your tags appear in the snapshot before trusting an empty delay map.
///
/// ```swift
/// Xray.shared.options(
///     metricsPort: 10085,
///     observatory: Xray.shared.observatory(subjectSelector: ["fast", "ua:icast"])
/// )
/// ```
public struct XrayObservatory: Sendable {
    /// Tag prefixes to probe. A list ends up as plain prefix matching:
    /// `"fast"` matches `"fast-v1"` and `"fastest"`; the empty string
    /// matches every outbound — including `direct` and `block` if their
    /// tags start the same way, so scope selectors to proxy tags.
    public var subjectSelector: [String]

    /// The URL the probe requests. Probed through every selected outbound
    /// on every interval, so a heavy page here is per-outbound traffic —
    /// keep it a light endpoint that answers 204.
    public var probeURL: String

    /// How often to probe. Go duration syntax: `"30s"`, `"1m"`, `"2h"`.
    /// Shorter intervals refresh delays faster and burn more data across
    /// every selected outbound; `"0s"` disables probing at the engine.
    public var probeInterval: String

    /// Whether all selected outbounds are probed at once instead of
    /// round-robin. Faster but burstier on the network.
    public var enableConcurrency: Bool

    internal init(
        subjectSelector: [String],
        probeURL: String = "https://www.google.com/generate_204",
        probeInterval: String = "1m",
        enableConcurrency: Bool = false
    ) {
        self.subjectSelector = subjectSelector
        self.probeURL = probeURL
        self.probeInterval = probeInterval
        self.enableConcurrency = enableConcurrency
    }

    var wireObject: XrayJSONObject {
        [
            "subjectSelector": .array(subjectSelector.map(XrayJSONValue.string)),
            "probeURL": .string(probeURL),
            "probeInterval": .string(probeInterval),
            "enableConcurrency": .bool(enableConcurrency),
        ]
    }
}

/// What one health probe knows about an outbound: whether it relayed the
/// probe request, how long the relay took, and when it was last seen.
/// One entry per selected outbound tag, under
/// `XrayTrafficSnapshot.observatory`.
public struct XrayOutboundProbe: Sendable {
    /// Whether the outbound relayed the last probe.
    public var alive: Bool

    /// Round trip of the last successful probe, in milliseconds. Nil when
    /// the outbound has no successful probe on record.
    public var delayMilliseconds: Int64?

    /// The engine's own text for why the last probe failed. Nil when the
    /// last probe succeeded or no probe was made yet.
    public var failureReason: String?

    /// When the outbound was last known alive (millisecond precision).
    public var lastSeen: Date?

    /// When the outbound was last tried, alive or not.
    public var lastTry: Date?

    init(alive: Bool, delayMilliseconds: Int64?, failureReason: String?, lastSeen: Date?, lastTry: Date?) {
        self.alive = alive
        self.delayMilliseconds = delayMilliseconds
        self.failureReason = failureReason
        self.lastSeen = lastSeen
        self.lastTry = lastTry
    }
}

/// One reading of the XrayMetrics endpoint: every tagged inbound and
/// outbound, plus summed totals.
public struct XrayTrafficSnapshot: Sendable {
    public var taken: Date
    public var inbound: [String: XrayTrafficCounter]
    public var outbound: [String: XrayTrafficCounter]
    /// Health probes from the `observatory` section, when the assembly
    /// set one up. Empty otherwise.
    public var observatory: [String: XrayOutboundProbe]

    internal init(
        taken: Date = Date(),
        inbound: [String: XrayTrafficCounter] = [:],
        outbound: [String: XrayTrafficCounter] = [:],
        observatory: [String: XrayOutboundProbe] = [:]
    ) {
        self.taken = taken
        self.inbound = inbound
        self.outbound = outbound
        self.observatory = observatory
    }

    /// Byte counters are cumulative and saturating: sums clamp at
    /// `Int64.max` instead of wrapping, so months of uptime must not
    /// turn totals negative and read as a restart to the watchdog.
    public var totalUp: Int64 {
        saturatingSum(inbound.values.map(\.up) + outbound.values.map(\.up))
    }

    public var totalDown: Int64 {
        saturatingSum(inbound.values.map(\.down) + outbound.values.map(\.down))
    }

    /// Uplink/downlink counted on the outbound side only. The engine
    /// counts every byte twice — once on the inbound it entered
    /// through, once on the outbound it left through — so `totalUp` /
    /// `totalDown` are 2x the bytes on the wire. Dashboard totals and
    /// speeds want this side: for proxy mode it equals the bytes the
    /// device exchanged with the network.
    public var uplink: Int64 {
        saturatingSum(outbound.values.map(\.up))
    }

    /// Outbound-side downlink; see `uplink`.
    public var downlink: Int64 {
        saturatingSum(outbound.values.map(\.down))
    }

    /// Bytes moved between two snapshots, with per-second rates derived
    /// from the wall-clock gap between them.
    public func delta(since earlier: XrayTrafficSnapshot) -> XrayTrafficDelta {
        let seconds = max(0, taken.timeIntervalSince(earlier.taken))
        func diffed(
            _ later: [String: XrayTrafficCounter],
            _ before: [String: XrayTrafficCounter]
        ) -> [String: XrayTrafficCounter] {
            // Union, not just the later keys: a tag dropped on restart
            // still appears (at zero), instead of silently vanishing.
            var out: [String: XrayTrafficCounter] = [:]
            for tag in Set(later.keys).union(before.keys) {
                out[tag] = (later[tag] ?? XrayTrafficCounter()).delta(since: before[tag] ?? XrayTrafficCounter())
            }
            return out
        }
        let inboundDelta = diffed(inbound, earlier.inbound)
        let outboundDelta = diffed(outbound, earlier.outbound)
        let up = saturatingSum(inboundDelta.values.map(\.up) + outboundDelta.values.map(\.up))
        let down = saturatingSum(inboundDelta.values.map(\.down) + outboundDelta.values.map(\.down))
        return XrayTrafficDelta(
            seconds: seconds,
            inbound: inboundDelta,
            outbound: outboundDelta,
            totalUp: up,
            totalDown: down
        )
    }
}

/// What moved during an interval: per-tag byte deltas with totals and
/// rates. `uplinkPerSecond` over a one-second poll *is* the upload
/// speed. Like the snapshot, `totalUp` / `totalDown` double-count
/// (inbound plus outbound); `uplink` / `downlink` count the outbound
/// side only and match the bytes on the wire.
public struct XrayTrafficDelta: Sendable {
    public var seconds: Double
    public var inbound: [String: XrayTrafficCounter]
    public var outbound: [String: XrayTrafficCounter]
    public var totalUp: Int64
    public var totalDown: Int64

    /// Outbound-side bytes up over the interval; see `XrayTrafficSnapshot.uplink`.
    public var uplink: Int64 {
        saturatingSum(outbound.values.map(\.up))
    }

    /// Outbound-side bytes down over the interval.
    public var downlink: Int64 {
        saturatingSum(outbound.values.map(\.down))
    }

    public var upPerSecond: Double {
        seconds > 0 ? max(0, Double(totalUp) / seconds) : 0
    }

    public var downPerSecond: Double {
        seconds > 0 ? max(0, Double(totalDown) / seconds) : 0
    }

    /// Outbound-side upload speed; prefer this for dashboards.
    public var uplinkPerSecond: Double {
        seconds > 0 ? max(0, Double(uplink) / seconds) : 0
    }

    /// Outbound-side download speed; prefer this for dashboards.
    public var downlinkPerSecond: Double {
        seconds > 0 ? max(0, Double(downlink) / seconds) : 0
    }
}

/// Polls the engine's XrayMetrics endpoint (`/debug/vars`) and returns typed
/// snapshots. One monitor per metrics port; poll about once a second and
/// diff consecutive snapshots for speed:
///
/// ```swift
/// let monitor = try Xray.shared.trafficMonitor(port: 10085)
/// var previous = try await monitor.snapshot()
/// while session alive {
///     try await Task.sleep(for: .seconds(1))
///     let now = try await monitor.snapshot()
///     let speed = now.delta(since: previous) // uplinkPerSecond / downlinkPerSecond
///     totals.up += speed.uplink
///     previous = now
/// }
/// ```
public struct XrayTrafficMonitor: Sendable {
    public var host: String
    public var port: Int
    /// Per request, so a wedged endpoint can't hang the poll loop.
    public var timeoutSeconds: Double

    internal init(port: Int, host: String = "127.0.0.1", timeoutSeconds: Double = 5) {
        self.port = port
        self.host = host
        self.timeoutSeconds = timeoutSeconds
    }

    public func snapshot() async throws -> XrayTrafficSnapshot {
        guard (1 ... 65_535).contains(port) else {
            throw XrayError.invalidInput("metrics port \(port) is outside 1...65535")
        }
        // Stamp before the request: `delta` divides by the gap between
        // stamps, and stamping after the read would silently drop the
        // request latency from sub-second polls.
        let taken = Date()
        // Reject host:port shapes before bracketing confuses them with
        // an IPv6 literal: the port belongs in `port`, not in `host`.
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if (host.hasPrefix("[") && host.contains("]:")) ||
            (!host.hasPrefix("[") && host.contains(":") && parts.count == 2 && parts.last?.allSatisfy(\.isNumber) == true) {
            throw XrayError.invalidInput("metrics host \(host) includes a port: pass the bare host and put the port in `port`")
        }
        // Bracket bare IPv6 literals, or the port after the final colon
        // reads as part of the address and URL formation fails.
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(hostPart):\(port)/debug/vars") else {
            throw XrayError.invalidInput("metrics host \(host) does not form a valid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            // A cancelled poll loop must stay cancellable: don't wrap
            // cooperative cancellation as a bridge failure.
            throw CancellationError()
        } catch {
            throw XrayError.bridgeFailed("metrics request to \(host):\(port) failed: \(error.localizedDescription)")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw XrayError.bridgeFailed("metrics endpoint returned HTTP \(code)")
        }
        return try Self.decodeSnapshot(from: data, taken: taken)
    }

    /// Parses one `/debug/vars` body. Separate from `snapshot` so the
    /// shape is unit-testable without a running engine. The stamp is a
    /// parameter (defaulting to now) so callers control it — but two
    /// snapshots stamped in the same instant still diff to a zero
    /// interval and silent zero rates, so sub-second polling needs the
    /// real stamps `snapshot()` takes.
    static func decodeSnapshot(from data: Data, taken: Date = Date()) throws -> XrayTrafficSnapshot {
        do {
            let payload = try JSONDecoder().decode(VarsPayload.self, from: data)
            return XrayTrafficSnapshot(
                taken: taken,
                inbound: payload.stats?.inbound?.mapValues { $0.counter } ?? [:],
                outbound: payload.stats?.outbound?.mapValues { $0.counter } ?? [:],
                observatory: payload.observatory?.compactMapValues { $0.probe } ?? [:]
            )
        } catch {
            throw XrayError.bridgeFailed("metrics response is not the expected JSON: \(error.localizedDescription)")
        }
    }
}

/// Fires `onStall` when engine traffic totals stop advancing for
/// `stalledAfter`: the bridge answers but nothing moves — dead routing,
/// a severed path, a wedged engine. Polls `snapshot()` every `interval`
/// and latches: one fire per stall episode, reset by any movement. An
/// idle tunnel reads as stalled, so start the watchdog after first
/// traffic or set `stalledAfter` generously. `onStall` runs on the
/// watchdog's task — hop to your queue inside it. Create, `start`, and
/// `stop` from one serial context.
public final class XrayTrafficWatchdog: @unchecked Sendable {
    private let monitor: XrayTrafficMonitor
    private let interval: Duration
    private let stalledAfter: Duration
    private let onStall: @Sendable () -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Which `start` owns the current loop. `stop` cancels the task but
    /// cannot join it, so an old loop may still be between its checks
    /// when a new one begins — the epoch lets the loser stand down
    /// instead of double-polling and double-firing.
    private var epoch: Int = 0

    internal init(
        port: Int,
        host: String,
        interval: Duration,
        stalledAfter: Duration,
        timeoutSeconds: Double = 5,
        onStall: @escaping @Sendable () -> Void
    ) throws {
        guard (1 ... 65_535).contains(port) else {
            throw XrayError.invalidInput("metrics port \(port) is outside 1...65535")
        }
        guard interval >= .milliseconds(10) else {
            throw XrayError.invalidInput("traffic watchdog interval must be at least 10ms: sub-millisecond polling is socket churn that starves the poll loop it measures")
        }
        guard stalledAfter >= interval else {
            throw XrayError.invalidInput("traffic watchdog stalledAfter (\(stalledAfter)) must be at least the poll interval (\(interval)): anything shorter fires on the first late poll, not on a stall")
        }
        guard timeoutSeconds > 0 else {
            throw XrayError.invalidInput("traffic watchdog timeoutSeconds must be positive")
        }
        guard !host.isEmpty else {
            throw XrayError.invalidInput("traffic watchdog host must not be empty")
        }
        // Same shape rule as `snapshot()`: a `host:port` here would
        // otherwise fail every poll and read as a permanent stall.
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if (host.hasPrefix("[") && host.contains("]:")) ||
            (!host.hasPrefix("[") && host.contains(":") && parts.count == 2 && parts.last?.allSatisfy(\.isNumber) == true) {
            throw XrayError.invalidInput("traffic watchdog host \(host) includes a port: pass the bare host and put the port in `port`")
        }
        self.monitor = XrayTrafficMonitor(port: port, host: host, timeoutSeconds: timeoutSeconds)
        self.interval = interval
        self.stalledAfter = stalledAfter
        self.onStall = onStall
    }

    deinit {
        task?.cancel()
    }

    /// Begins polling. Restartable: starting again stops the old loop,
    /// and the old loop exits at its next check via the epoch — the two
    /// never fire together. Polls can briefly overlap (`stop` cannot
    /// abort an in-flight HTTP read), so keep `onStall` idempotent: the
    /// epoch guarantees at most one fire per stall episode.
    public func start() {
        lock.withLock {
            task?.cancel()
            epoch += 1
            let current = epoch
            task = Task { [weak self] in await self?.run(epoch: current) }
        }
    }

    /// Stops polling. Safe when idle. The in-flight loop exits at its
    /// next cancellation check.
    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
            epoch += 1
        }
    }

    private func run(epoch: Int) async {
        func current() -> Bool { lock.withLock { epoch == self.epoch } }
        var last = try? await monitor.snapshot()
        var lastAdvance = ContinuousClock.now
        var fired = false
        while !Task.isCancelled, current() {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, current() else { return }
            // A failed snapshot counts the same as a stale one: the
            // endpoint answering nothing is the stall, whether the
            // engine died or only its listener did. No baseline, slow
            // listener startup, and a dead port all converge here — so
            // start the watchdog after one manual `snapshot()` or set
            // `stalledAfter` generously.
            if let now = try? await monitor.snapshot() {
                if let previous = last {
                    // Any movement counts: growth is traffic, a drop is an
                    // engine restart resetting its counters — fresh traffic,
                    // not a stall. Only exactly-equal totals mean silence.
                    // Saturating sides only: totals wrap nothing anymore.
                    if now.uplink != previous.uplink || now.downlink != previous.downlink {
                        lastAdvance = ContinuousClock.now
                        fired = false
                    }
                } else {
                    // First successful reading: the stall clock starts at
                    // first data, not at start(). A metrics endpoint that
                    // is still coming up must not read as a stall before
                    // it ever answered.
                    lastAdvance = ContinuousClock.now
                }
                last = now
            }
            if !fired, ContinuousClock.now - lastAdvance >= stalledAfter {
                fired = true
                onStall()
            }
        }
    }
}

extension Xray {

    /// Starts a stall watchdog over the metrics endpoint on `port`: same
    /// listener `trafficMonitor` reads, so the port must be assembled in
    /// (see `metricsPort`). Slow endpoints get their own budget instead
    /// of the 5s monitor default.
    public func trafficWatchdog(
        port: Int,
        host: String = "127.0.0.1",
        interval: Duration = .seconds(10),
        stalledAfter: Duration = .seconds(60),
        timeoutSeconds: Double = 5,
        onStall: @escaping @Sendable () -> Void
    ) throws -> XrayTrafficWatchdog {
        try XrayTrafficWatchdog(port: port, host: host, interval: interval, stalledAfter: stalledAfter, timeoutSeconds: timeoutSeconds, onStall: onStall)
    }
}

// Saturating sum of counters: clamps at `Int64.max` instead of
// wrapping. A wrapped total turns negative, which the watchdog reads
// as a restart (fresh traffic) and a dashboard reads as a drop —
// saturation keeps the series monotonic so both stay truthful.
private func saturatingSum(_ values: [Int64]) -> Int64 {
    values.reduce(0) { total, next in
        let (sum, overflow) = total.addingReportingOverflow(next)
        return overflow ? .max : sum
    }
}

// MARK: - Wire decoding (tolerant: the endpoint also serves Go runtime keys)

private struct VarsPayload: Decodable {
    var stats: VarsStats?
    /// The key the engine publishes probe results under, plainly absent when
    /// no `observatory` section was assembled.
    var observatory: [String: VarsProbe]?
}

private struct VarsStats: Decodable {
    var inbound: [String: VarsCounter]?
    var outbound: [String: VarsCounter]?
}

private struct VarsCounter: Decodable {
    var uplink: Int64
    var downlink: Int64

    var counter: XrayTrafficCounter {
        XrayTrafficCounter(up: uplink, down: downlink)
    }

    enum CodingKeys: String, CodingKey {
        case uplink, downlink
    }

    init(from decoder: any Decoder) throws {
        // Clamp, don't fail: one counter past Int64.max (or briefly a
        // non-number mid-rotation) must not kill the whole snapshot —
        // every other tag still reports. Absent stays zero as before.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uplink = (try? container.decodeIfPresent(Int64.self, forKey: .uplink)) ?? 0
        downlink = (try? container.decodeIfPresent(Int64.self, forKey: .downlink)) ?? 0
    }
}

/// Field spellings come straight from the engine's protobuf JSON tags:
/// `alive`, `delay`, `last_error_reason`, `last_seen_time`, `last_try_time`,
/// all `omitempty`, so timestamps are in milliseconds since epoch and bools
/// may be absent when false.
private struct VarsProbe: Decodable {
    var alive: Bool?
    var delay: Int64?
    var last_error_reason: String?
    var last_seen_time: Int64?
    var last_try_time: Int64?

    var probe: XrayOutboundProbe {
        XrayOutboundProbe(
            alive: alive ?? false,
            delayMilliseconds: normalizedDelay,
            failureReason: last_error_reason.flatMap { $0.isEmpty ? nil : $0 },
            lastSeen: last_seen_time.flatMap(Self.date),
            lastTry: last_try_time.flatMap(Self.date)
        )
    }

    /// A non-positive delay means the probe never completed; nil reads
    /// better than zero as "no successful probe on record".
    private var normalizedDelay: Int64? {
        guard let delay, delay > 0 else { return nil }
        return delay
    }

    /// Engine timestamps are milliseconds since epoch; anything nonsensical
    /// (negative, zero) means "no data yet", so nil is the honest answer.
    private static func date(_ milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

// Value factories for metrics, observatory, and the monitor. Ports are
// checked here; snapshots and deltas are read-models from the engine and
// need no factories.
extension Xray {
    /// Builds a metrics section by hand — for raw documents and
    /// transforms. The tag labels the section only (the engine keys
    /// counters by inbound/outbound tag); the normal path is
    /// `options(metricsPort:)`, which always wires the default tag.
    public func metrics(tag: String = "XrayMetrics", port: Int) throws -> XrayMetrics {
        try Self.validPort(port, name: "metrics")
        return XrayMetrics(tag: tag, port: port)
    }

    public func observatory(
        subjectSelector: [String],
        probeURL: String = "https://www.google.com/generate_204",
        probeInterval: String = "1m",
        enableConcurrency: Bool = false
    ) throws -> XrayObservatory {
        guard !subjectSelector.isEmpty else {
            throw XrayError.invalidInput("observatory needs at least one subjectSelector: an empty selector probes nothing")
        }
        guard let url = URL(string: probeURL), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw XrayError.invalidInput("observatory probeURL must be an http(s) URL, got \(probeURL)")
        }
        guard Self.isGoDuration(probeInterval) else {
            throw XrayError.invalidInput("observatory probeInterval must be a Go duration like \"30s\" or \"1m\", got \(probeInterval)")
        }
        return XrayObservatory(
            subjectSelector: subjectSelector, probeURL: probeURL,
            probeInterval: probeInterval, enableConcurrency: enableConcurrency
        )
    }

    /// Go duration syntax (`ParseDuration`): a sign-optional run of
    /// number+unit pairs like `30s`, `1m30s`, or `500ms`.
    private static func isGoDuration(_ text: String) -> Bool {
        text.range(of: #"^[+-]?(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$"#, options: .regularExpression) != nil
    }

    public func trafficMonitor(
        port: Int,
        host: String = "127.0.0.1",
        timeoutSeconds: Double = 5
    ) throws -> XrayTrafficMonitor {
        try Self.validPort(port, name: "traffic monitor")
        guard !host.isEmpty else {
            throw XrayError.invalidInput("traffic monitor host must not be empty")
        }
        guard timeoutSeconds > 0 else {
            throw XrayError.invalidInput("traffic monitor timeoutSeconds must be positive, got \(timeoutSeconds)")
        }
        return XrayTrafficMonitor(port: port, host: host, timeoutSeconds: timeoutSeconds)
    }
}
