import Foundation

// Live traffic insight without new dependencies: the engine already ships a
// Metrics HTTP endpoint that publishes per-tag byte counters. Point the
// assembly at a `metricsPort`, launch, then poll the endpoint with
// `TrafficMonitor` — speed is the delta between snapshots, totals are the
// running sum. Works with the stock engine on every supported OS.

extension Xray {
    /// The engine's Metrics HTTP service: one object, one localhost listener.
    /// Wired in by `metricsPort`, so you never spell the section by hand:
    ///
    /// ```swift
    /// var assembly = Xray.shared.assembler(.shareLinks(text))
    /// assembly.metricsPort = 10085
    /// let config = try assembly.assemble()
    /// ```
    public struct Metrics: Sendable {
        /// Section tag. The reference app reads per-tag counters by inbound
        /// tag, so this only matters if you rename it deliberately.
        public var tag: String
        /// Localhost port serving `/debug/vars`. Keep it out of the ports
        /// your entries listen on; `verifyAvailablePorts` finds a safe one.
        public var port: Int

        internal init(tag: String = "Metrics", port: Int) {
            self.tag = tag
            self.port = port
        }

        var wireObject: JSONObject {
            [
                "tag": .string(tag),
                "listen": .string("127.0.0.1:\(port)"),
            ]
        }
    }

    /// Byte counters for one inbound or outbound tag, as published by the
    /// engine. Cumulative since engine start; the engine zeroes them only on
    /// restart, so deltas across a restart clamp instead of going negative.
    public struct TrafficCounter: Sendable {
        public var up: Int64
        public var down: Int64

        internal init(up: Int64 = 0, down: Int64 = 0) {
            self.up = up
            self.down = down
        }

        public var total: Int64 { up + down }

        /// Later minus earlier. If the later reading is smaller, the engine
        /// restarted between snapshots and "before" is meaningless — so the
        /// whole later reading counts as new traffic instead of clamping to
        /// zero and silently dropping post-restart bytes.
        func delta(since earlier: TrafficCounter) -> TrafficCounter {
            TrafficCounter(
                up: up >= earlier.up ? up - earlier.up : up,
                down: down >= earlier.down ? down - earlier.down : down
            )
        }
    }

    /// Per-outbound health probing, told to the engine as the `observatory`
    /// section. Every outbound whose tag matches one of the `subjectSelector`
    /// prefixes gets an HTTP probe through itself on the configured interval;
    /// results land in the Metrics endpoint and surface as
    /// `TrafficSnapshot.observatory`. Requires `metricsPort` to be set —
    /// probing without metrics has no readable results.
    ///
    /// ```swift
    /// Xray.shared.options(
    ///     metricsPort: 10085,
    ///     observatory: Xray.shared.observatory(subjectSelector: ["fast", "ua:icast"])
    /// )
    /// ```
    public struct Observatory: Sendable {
        /// Tag prefixes to probe. A list ends up as plain prefix matching:
        /// `"fast"` matches `"fast-v1"` and `"fastest"`; the empty string
        /// matches every outbound.
        public var subjectSelector: [String]

        /// The URL the probe requests.
        public var probeURL: String

        /// How often to probe. Go duration syntax: `"30s"`, `"1m"`, `"2h"`.
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

        var wireObject: JSONObject {
            [
                "subjectSelector": .array(subjectSelector.map(JSONValue.string)),
                "probeURL": .string(probeURL),
                "probeInterval": .string(probeInterval),
                "enableConcurrency": .bool(enableConcurrency),
            ]
        }
    }

    /// What one health probe knows about an outbound: whether it relayed the
    /// probe request, how long the relay took, and when it was last seen.
    /// One entry per selected outbound tag, under
    /// `TrafficSnapshot.observatory`.
    public struct OutboundProbe: Sendable {
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

    /// One reading of the Metrics endpoint: every tagged inbound and
    /// outbound, plus summed totals.
    public struct TrafficSnapshot: Sendable {
        public var taken: Date
        public var inbound: [String: TrafficCounter]
        public var outbound: [String: TrafficCounter]
        /// Health probes from the `observatory` section, when the assembly
        /// set one up. Empty otherwise.
        public var observatory: [String: OutboundProbe]

        internal init(
            taken: Date = Date(),
            inbound: [String: TrafficCounter] = [:],
            outbound: [String: TrafficCounter] = [:],
            observatory: [String: OutboundProbe] = [:]
        ) {
            self.taken = taken
            self.inbound = inbound
            self.outbound = outbound
            self.observatory = observatory
        }

        public var totalUp: Int64 {
            inbound.values.reduce(0) { $0 + $1.up } + outbound.values.reduce(0) { $0 + $1.up }
        }

        public var totalDown: Int64 {
            inbound.values.reduce(0) { $0 + $1.down } + outbound.values.reduce(0) { $0 + $1.down }
        }

        /// Uplink/downlink counted on the outbound side only. The engine
        /// counts every byte twice — once on the inbound it entered
        /// through, once on the outbound it left through — so `totalUp` /
        /// `totalDown` are 2x the bytes on the wire. Dashboard totals and
        /// speeds want this side: for proxy mode it equals the bytes the
        /// device exchanged with the network.
        public var uplink: Int64 {
            outbound.values.reduce(0) { $0 + $1.up }
        }

        /// Outbound-side downlink; see `uplink`.
        public var downlink: Int64 {
            outbound.values.reduce(0) { $0 + $1.down }
        }

        /// Bytes moved between two snapshots, with per-second rates derived
        /// from the wall-clock gap between them.
        public func delta(since earlier: TrafficSnapshot) -> TrafficDelta {
            let seconds = max(0, taken.timeIntervalSince(earlier.taken))
            func diffed(
                _ later: [String: TrafficCounter],
                _ before: [String: TrafficCounter]
            ) -> [String: TrafficCounter] {
                var out: [String: TrafficCounter] = [:]
                for (tag, counter) in later {
                    out[tag] = counter.delta(since: before[tag] ?? TrafficCounter())
                }
                return out
            }
            let inboundDelta = diffed(inbound, earlier.inbound)
            let outboundDelta = diffed(outbound, earlier.outbound)
            let up = inboundDelta.values.reduce(0) { $0 + $1.up } + outboundDelta.values.reduce(0) { $0 + $1.up }
            let down = inboundDelta.values.reduce(0) { $0 + $1.down } + outboundDelta.values.reduce(0) { $0 + $1.down }
            return TrafficDelta(
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
    public struct TrafficDelta: Sendable {
        public var seconds: Double
        public var inbound: [String: TrafficCounter]
        public var outbound: [String: TrafficCounter]
        public var totalUp: Int64
        public var totalDown: Int64

        /// Outbound-side bytes up over the interval; see `TrafficSnapshot.uplink`.
        public var uplink: Int64 {
            outbound.values.reduce(0) { $0 + $1.up }
        }

        /// Outbound-side bytes down over the interval.
        public var downlink: Int64 {
            outbound.values.reduce(0) { $0 + $1.down }
        }

        public var upPerSecond: Double {
            seconds > 0 ? Double(totalUp) / seconds : 0
        }

        public var downPerSecond: Double {
            seconds > 0 ? Double(totalDown) / seconds : 0
        }

        /// Outbound-side upload speed; prefer this for dashboards.
        public var uplinkPerSecond: Double {
            seconds > 0 ? Double(uplink) / seconds : 0
        }

        /// Outbound-side download speed; prefer this for dashboards.
        public var downlinkPerSecond: Double {
            seconds > 0 ? Double(downlink) / seconds : 0
        }
    }

    /// Polls the engine's Metrics endpoint (`/debug/vars`) and returns typed
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
    public struct TrafficMonitor: Sendable {
        public var host: String
        public var port: Int
        /// Per request, so a wedged endpoint can't hang the poll loop.
        public var timeoutSeconds: Double

        internal init(port: Int, host: String = "127.0.0.1", timeoutSeconds: Double = 5) {
            self.port = port
            self.host = host
            self.timeoutSeconds = timeoutSeconds
        }

        public func snapshot() async throws -> TrafficSnapshot {
            guard (1 ... 65_535).contains(port) else {
                throw Error.invalidInput("metrics port \(port) is outside 1...65535")
            }
            guard let url = URL(string: "http://\(host):\(port)/debug/vars") else {
                throw Error.invalidInput("metrics host \(host) does not form a valid URL")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeoutSeconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw Error.bridgeFailed("metrics request to \(host):\(port) failed: \(error.localizedDescription)")
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw Error.bridgeFailed("metrics endpoint returned HTTP \(code)")
            }
            return try Self.decodeSnapshot(from: data)
        }

        /// Parses one `/debug/vars` body. Separate from `snapshot` so the
        /// shape is unit-testable without a running engine.
        static func decodeSnapshot(from data: Data) throws -> TrafficSnapshot {
            do {
                let payload = try JSONDecoder().decode(VarsPayload.self, from: data)
                return TrafficSnapshot(
                    inbound: payload.stats?.inbound?.mapValues { $0.counter } ?? [:],
                    outbound: payload.stats?.outbound?.mapValues { $0.counter } ?? [:],
                    observatory: payload.observatory?.compactMapValues { $0.probe } ?? [:]
                )
            } catch {
                throw Error.bridgeFailed("metrics response is not the expected JSON: \(error.localizedDescription)")
            }
        }
    }
}

extension Xray {
    /// Fires `onStall` when engine traffic totals stop advancing for
    /// `stalledAfter`: the bridge answers but nothing moves — dead routing,
    /// a severed path, a wedged engine. Polls `snapshot()` every `interval`
    /// and latches: one fire per stall episode, reset by any movement. An
    /// idle tunnel reads as stalled, so start the watchdog after first
    /// traffic or set `stalledAfter` generously. `onStall` runs on the
    /// watchdog's task — hop to your queue inside it. Create, `start`, and
    /// `stop` from one serial context.
    public final class TrafficWatchdog {
        private let monitor: TrafficMonitor
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
            onStall: @escaping @Sendable () -> Void
        ) throws {
            guard (1 ... 65_535).contains(port) else {
                throw Error.invalidInput("metrics port \(port) is outside 1...65535")
            }
            self.monitor = TrafficMonitor(port: port, host: host)
            self.interval = interval
            self.stalledAfter = stalledAfter
            self.onStall = onStall
        }

        deinit {
            task?.cancel()
        }

        /// Begins polling. Restartable: starting again stops the old loop,
        /// and the old loop exits at its next check via the epoch — the two
        /// never poll or fire together.
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
                    if let previous = last,
                       now.totalUp + now.totalDown > previous.totalUp + previous.totalDown {
                        lastAdvance = ContinuousClock.now
                        fired = false
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

    /// Starts a stall watchdog over the metrics endpoint on `port`: same
    /// listener `trafficMonitor` reads, so the port must be assembled in
    /// (see `metricsPort`).
    public func trafficWatchdog(
        port: Int,
        host: String = "127.0.0.1",
        interval: Duration = .seconds(10),
        stalledAfter: Duration = .seconds(60),
        onStall: @escaping @Sendable () -> Void
    ) throws -> TrafficWatchdog {
        try TrafficWatchdog(port: port, host: host, interval: interval, stalledAfter: stalledAfter, onStall: onStall)
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
    var uplink: Int64?
    var downlink: Int64?

    var counter: Xray.TrafficCounter {
        Xray.TrafficCounter(up: uplink ?? 0, down: downlink ?? 0)
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

    var probe: Xray.OutboundProbe {
        Xray.OutboundProbe(
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
    public func metrics(tag: String = "Metrics", port: Int) throws -> Metrics {
        try Self.validPort(port, name: "metrics")
        return Metrics(tag: tag, port: port)
    }

    public func observatory(
        subjectSelector: [String],
        probeURL: String = "https://www.google.com/generate_204",
        probeInterval: String = "1m",
        enableConcurrency: Bool = false
    ) -> Observatory {
        Observatory(
            subjectSelector: subjectSelector, probeURL: probeURL,
            probeInterval: probeInterval, enableConcurrency: enableConcurrency
        )
    }

    public func trafficMonitor(
        port: Int,
        host: String = "127.0.0.1",
        timeoutSeconds: Double = 5
    ) throws -> TrafficMonitor {
        try Self.validPort(port, name: "traffic monitor")
        return TrafficMonitor(port: port, host: host, timeoutSeconds: timeoutSeconds)
    }
}
