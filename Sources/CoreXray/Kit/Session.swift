import Foundation

// App-facing session over the engine: owns one launch lifecycle, assembles
// configurations from JSON or share links, and offers the hooks integrators
// always end up needing (inspect-before-run, last-minute tweaks, log sink).
// The static `Xray` API is the thin binding underneath; this is the layer a
// VPN app holds onto.

/// Knobs for `build` and `start`. Everything defaults to plain proxy
/// mode, so `session.start(.json(text))` behaves exactly as before.
public struct XraySessionOptions {
    /// XraySniffing injected into inbounds that lack their own settings.
    public var sniffing: XraySniffing?

    /// Last-minute document patch, applied after everything else.
    public var transform: ((inout XrayJSONObject) -> Void)?

    /// A complete routing section, written verbatim. Replaces any
    /// routing section already in the document.
    public var routing: XrayRouting?

    /// Username + password guarding the local SOCKS entry points.
    /// Only SOCKS inbounds are touched; other inbound types pass
    /// through unchanged.
    public var credentials: XrayCredentials?

    /// Device-wide capture through the engine's own TUN inbound (see
    /// `XrayTunEntry` and the TUN section in the README). Assembling
    /// appends a `protocol: tun` inbound and, when the entry carries
    /// a file descriptor, merges `xray.tun.fd` into the document's
    /// `env`. Nil means proxy mode: no TUN inbound, no `env` key.
    /// Launch the result where the interface lives — inside the
    /// NetworkExtension on iOS, in the app on macOS.
    public var tun: XrayTunEntry?

    /// Extra document environment entries, merged into `env` before
    /// the TUN descriptor is applied. The engine turns `env` into
    /// its own process environment at launch — the documented carrier
    /// for `xray.location.asset` (geo database lookup directory),
    /// `xray.location.cert`, and similar engine settings. Keys here
    /// never overwrite ones already in the document.
    public var environment: [String: String]?

    /// Per-outbound health probing: writes the `observatory` section
    /// the engine needs, and feeds `XrayTrafficSnapshot.observatory` when
    /// `metricsPort` is also set. The engine probes every outbound
    /// whose tag matches a `subjectSelector` prefix through the
    /// network, so a short interval costs live requests. Nil means
    /// no probing.
    public var observatory: XrayObservatory?

    /// Whether assembling checks that geo databases referenced by the
    /// routing (`geosite:`) or dns (`geosite:` / `geoip:`) sections
    /// actually exist next to the engine, before anything launches.
    /// The engine only complains at traffic time otherwise. Rules
    /// naming plain domains or IPs never trigger it. Default true.
    public var geoCheck: Bool

    /// A dns section, written verbatim. Replaces any dns section
    /// already in the document.
    public var dns: XrayDNS?

    /// XrayFakeDNS pools, written verbatim as the `fakedns` array.
    /// Replaces any fakedns section already in the document.
    public var fakeDNS: [XrayFakeDNS]?

    /// A log section, written verbatim. Replaces any log section
    /// already in the document.
    public var log: XrayLog?

    /// XrayMetrics endpoint port. When set, the build adds a XrayMetrics
    /// listener on 127.0.0.1:`metricsPort`, an empty `stats` section,
    /// and the four `policy.system` stats switches — everything
    /// `XrayTrafficMonitor` needs to read live counters. Replaces any
    /// metrics section already in the document; existing policy keys
    /// are kept, the stats switches are turned on alongside them.
    public var metricsPort: Int?

    internal init(
        sniffing: XraySniffing? = nil,
        transform: ((inout XrayJSONObject) -> Void)? = nil,
        routing: XrayRouting? = nil,
        credentials: XrayCredentials? = nil,
        tun: XrayTunEntry? = nil,
        environment: [String: String]? = nil,
        observatory: XrayObservatory? = nil,
        geoCheck: Bool = true,
        dns: XrayDNS? = nil,
        fakeDNS: [XrayFakeDNS]? = nil,
        log: XrayLog? = nil,
        metricsPort: Int? = nil
    ) {
        self.sniffing = sniffing
        self.transform = transform
        self.routing = routing
        self.credentials = credentials
        self.tun = tun
        self.environment = environment
        self.observatory = observatory
        self.geoCheck = geoCheck
        self.dns = dns
        self.fakeDNS = fakeDNS
        self.log = log
        self.metricsPort = metricsPort
    }
}

/// Which engine-written log file to tail (see `recentEngineLogs`).
public enum XrayEngineLogKind {
    case access
    case error
}

/// One launch lifecycle. Hold onto an instance for as long as its engine
/// should live; stopping is explicit through `stop()`. Confine each
/// session to a single serial context: the engine calls underneath are
/// serialized, but interleaving two sessions' start/stop sequences from
/// different threads is a logic race this type does not referee.
///
/// ```swift
/// let session = Xray.shared.newSession { print("[xray]", $0) }
/// try session.start(.shareLinks(pastedText), options: Xray.shared.options(
///     sniffing: Xray.shared.sniffing(),
///     transform: { $0["log"] = ["loglevel": "warning"] }
/// ))
/// ```
public final class XraySession: @unchecked Sendable {
    // Mutable state lives behind `stateLock`; the bridge calls underneath
    // are serialized by the transport lane. `@unchecked` is the honest
    // marking: `logger` runs on the caller's thread by design, so keep
    // each session on one serial context — interleaving two sessions'
    // start/stop sequences from different threads is a logic race no
    // lock can referee.
    private let stateLock = NSLock()
    private var _logger: ((String) -> Void)?
    private var _entries: [String] = []
    private var _connectedSince: Date?
    private var _accessLogPath: String?
    private var _errorLogPath: String?
    /// Launch epoch: every start attempt and every stop bumps it, so a
    /// timed-out start's compensating stop can tell a stale timeout
    /// from the current instance and never kill a newer launch.
    private var _generation: Int = 0
    private static let stamp = ISO8601DateFormatter()

    /// Transport for feed fetches. `URLSession.shared` in production;
    /// tests swap in a stubbed configuration. Set once before the first
    /// fetch — access is lock-guarded, but swapping it mid-fetch races
    /// the in-flight request, so treat it as set-once configuration.
    internal var urlSession: URLSession {
        get { stateLock.withLock { _urlSession } }
        set { stateLock.withLock { _urlSession = newValue } }
    }
    private var _urlSession: URLSession = .shared

    /// Test seam for the deadline start: replaces the bridge launch so
    /// the timeout path is deterministic (a hanging closure plus a
    /// short deadline). Same set-once discipline as `urlSession`.
    internal var launchOverride: (@Sendable (String) throws -> Void)? {
        get { stateLock.withLock { _launchOverride } }
        set { stateLock.withLock { _launchOverride = newValue } }
    }
    private var _launchOverride: (@Sendable (String) throws -> Void)?

    /// Receives lifecycle notes: what is launching, the byte count of the
    /// final JSON, engine answers. Set at init or any time after. Every
    /// note is also kept in the `recentLogs` ring buffer.
    public var logger: ((String) -> Void)? {
        get { stateLock.withLock { _logger } }
        set { stateLock.withLock { _logger = newValue } }
    }

    /// When the running instance came up, if one did. Nil before the
    /// first start and after every stop. The engine exposes no clock of
    /// its own, so this stamp is the uptime anchor — pair it with traffic
    /// totals, which reset on every launch.
    public var connectedSince: Date? {
        stateLock.withLock { _connectedSince }
    }

    internal init(logger: ((String) -> Void)? = nil) {
        self._logger = logger
    }

    // MARK: - Launch options

    // MARK: - XrayAssembly (no launch)

    /// Assembles everything `start` would launch: conversion, environment,
    /// the tun inbound when set, the observatory section when set,
    /// sniffing, dns, fakedns, log, metrics, routing, credentials, then
    /// `transform` last so it can overrule anything, and finally the geo
    /// asset check. Use the result to inspect, persist, or diff
    /// before committing to a launch.
    ///
    /// The transform works on a typed tree (`XrayJSONObject`), so there
    /// is nothing to cast:
    ///
    /// ```swift
    /// try session.build(.shareLinks(text), options: Xray.shared.options(
    ///     routing: Xray.shared.routing(
    ///         rules: [Xray.shared.routingRule(domains: ["googleadservices.com"],
    ///                                        destination: .proxy)],
    ///         final: .direct
    ///     )
    /// ))
    /// ```
    public func build(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws -> XrayConfig {
        let options = options ?? XraySessionOptions()
        let json: String
        switch source {
        case .json(let text):
            json = text
        case .shareLinks(let links):
            json = try XrayConfig(shareLinks: links).json
        }
        let decoded: XrayJSONValue
        do {
            decoded = try JSONDecoder().decode(XrayJSONValue.self, from: Data(json.utf8))
        } catch {
            throw XrayError.invalidInput("configuration is not valid JSON")
        }
        guard case .object(var dict) = decoded else {
            throw XrayError.invalidInput("configuration is not a JSON object")
        }
        if let environment = options.environment {
            var env = dict["env"]?.objectValue ?? [:]
            for (key, value) in environment where env[key] == nil {
                env[key] = .string(value)
            }
            dict["env"] = .object(env)
        }
        if let tun = options.tun {
            var inbounds = dict["inbounds"]?.arrayValue ?? []
            inbounds.append(.object(tun.wireObject))
            dict["inbounds"] = .array(inbounds)
            tun.applyEnvironment(to: &dict)
        }
        if options.observatory != nil && options.metricsPort == nil {
            throw XrayError.invalidInput(
                "observatory is set but metricsPort is nil: probe answers are published on the metrics endpoint, so set metricsPort to read them"
            )
        }
        if let observatory = options.observatory {
            dict["observatory"] = .object(observatory.wireObject)
        }
        options.sniffing?.inject(into: &dict)
        if let dns = options.dns {
            dict["dns"] = .object(dns.wireObject)
        }
        if let fakeDNS = options.fakeDNS {
            dict["fakedns"] = .array(fakeDNS.map { .object($0.wireObject) })
        }
        if let log = options.log {
            dict["log"] = .object(log.wireObject)
        }
        if let metricsPort = options.metricsPort {
            guard (1 ... 65_535).contains(metricsPort) else {
                throw XrayError.invalidInput("metrics port \(metricsPort) is outside 1...65535")
            }
            dict["metrics"] = .object(XrayMetrics(port: metricsPort).wireObject)
            if dict["stats"] == nil {
                dict["stats"] = .object([:])
            }
            var policy = dict["policy"]?.objectValue ?? [:]
            var system = policy["system"]?.objectValue ?? [:]
            system["statsInboundUplink"] = .bool(true)
            system["statsInboundDownlink"] = .bool(true)
            system["statsOutboundUplink"] = .bool(true)
            system["statsOutboundDownlink"] = .bool(true)
            policy["system"] = .object(system)
            dict["policy"] = .object(policy)
        }
        if let routing = options.routing {
            if routing.rules.contains(where: { $0.isIneffective }) {
                throw XrayError.invalidInput("routing contains a rule that selects nothing: the engine rejects rules with no traffic fields — give it domains, ips, a port, protocols, or inbound tags (a destination alone matches no traffic)")
            }
            let proxyTag: String
            if routing.needsProxy {
                guard let resolved = Self.ensureProxyTag(in: &dict) else {
                    throw XrayError.invalidInput("routing sends traffic to the proxy but the document has no outbounds")
                }
                proxyTag = resolved
            } else {
                proxyTag = Self.firstOutboundTag(in: dict) ?? "proxy"
            }
            dict["routing"] = .object(routing.wireObject(proxyTag: proxyTag))
        }
        try Self.applyCredentials(options.credentials, to: &dict)
        options.transform?(&dict)
        // The relay route is checked after the transform runs, so relays
        // the transform adds are covered too — and standard outbounds are
        // backfilled after that, so a referenced `dns-out` always exists.
        // The check is idempotent, so an explicit route for the tag wins.
        Self.ensureDNSRelayRoute(in: &dict)
        Self.ensureStandardOutbounds(in: &dict)
        if let metricsPort = options.metricsPort {
            var taken: [Int] = []
            if case .array(let inbounds) = dict["inbounds"] {
                for inbound in inbounds {
                    guard case .object(let entry) = inbound else { continue }
                    if case .int(let port) = entry["port"] {
                        taken.append(port)
                    } else if case .string(let text) = entry["port"], let port = Int(text) {
                        taken.append(port)
                    }
                }
            }
            if taken.contains(metricsPort) {
                throw XrayError.invalidInput("metrics port \(metricsPort) collides with an inbound listening on the same port: pick a dedicated port")
            }
        }
        if options.geoCheck {
            try Self.checkGeoAssets(in: dict)
        }
        let text = try EngineTransport.serialize(.object(dict))
        log("assembled configuration (\(text.count) bytes)")
        return XrayConfig(json: text)
    }

    // MARK: - Launch

    /// Builds from `source` with `options` and launches the engine with
    /// the result. Blocks until the engine is up.
    public func start(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws {
        try start(try build(source, options: options))
    }

    /// Launches an assembled configuration. Blocks until the engine is
    /// up, so prefer a background task (or the async variant) from UI code.
    /// Starting again while an instance runs replaces it: a live
    /// instance is stopped first, so the launch never fails with an
    /// already-running refusal. The log section's file paths are adopted
    /// only when the launch succeeds, so engine-file tailing follows
    /// this run — a failed launch keeps the previous run's tail.
    public func start(_ config: XrayConfig) throws {
        try replaceRunningInstance()
        let generation = nextGeneration()
        let dict = documentDict(from: config.json)
        if let dict { clearStaleTunDescriptorIfNeeded(for: dict) }
        log("launching engine (\(config.json.count) bytes of configuration)")
        try LifecycleCalls.launch(config.json)
        if generation == currentGeneration() {
            if let dict { recordLogPaths(from: dict) }
            markLaunched()
            log("engine launched")
        } else {
            // Superseded mid-launch by a newer start: the engine may be
            // up, but the stamps belong to the winner, not to us.
            log("engine launch superseded by a newer start; stamps skipped")
        }
    }

    /// Launches JSON text exactly as given: no conversion, no sniffing,
    /// no transform. For fully pre-built configs you control end to end.
    /// The log section's file paths are adopted only on success, so
    /// `recentEngineLogs` tails this run, never a failed attempt.
    /// Starting again replaces a running instance first.
    public func start(rawJSON json: String) throws {
        try replaceRunningInstance()
        let generation = nextGeneration()
        let dict = documentDict(from: json)
        if let dict { clearStaleTunDescriptorIfNeeded(for: dict) }
        log("launching engine from raw JSON (\(json.count) bytes)")
        try LifecycleCalls.launch(json)
        if generation == currentGeneration() {
            if let dict { recordLogPaths(from: dict) }
            markLaunched()
            log("engine launched")
        } else {
            log("engine launch superseded by a newer start; stamps skipped")
        }
    }

    /// Reads a JSON file and launches it exactly as written.
    public func start(contentsOf url: URL) throws {
        let json: String
        do {
            json = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw XrayError.invalidInput("could not read config file at \(url.path): \(error.localizedDescription)")
        }
        try start(rawJSON: json)
    }

    /// Assembles with `options` and validates the result, so you check
    /// exactly what would launch. The check runs inside the engine, so
    /// it needs the engine stopped — while running, validate the
    /// structure offline with `XrayConfig.validateOffline()` instead.
    public func validate(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws {
        try build(source, options: options).validate()
    }

    /// Stops this process's running engine instance. Safe when idle: the
    /// engine still answers with success. The stop invalidates any
    /// timed-out start still settling in the background, so its
    /// compensating cleanup stands down instead of racing you.
    public func stop() throws {
        _ = nextGeneration()
        log("stopping engine")
        do {
            try LifecycleCalls.stop()
        } catch {
            // The engine state is uncertain now, but an uptime anchor
            // pointing at a possibly-dead engine is the worse lie: it
            // claims health and suppresses reconnects. Clear the stamp
            // (log paths survive for forensics) and rethrow, so the
            // caller knows the instance may still be running.
            markStopped()
            log("engine stop failed: \(error)")
            throw error
        }
        markStopped()
        log("engine stopped")
    }

    /// Whether an engine instance started earlier in this process is
    /// running.
    public func isRunning() throws -> Bool {
        return try LifecycleCalls.isRunning()
    }

    /// Bumps the launch epoch and returns the new value. Every start
    /// attempt calls this before launching; `stop` calls it too, so a
    /// pending compensating stop from an older attempt stands down.
    private func nextGeneration() -> Int {
        stateLock.withLock {
            _generation += 1
            return _generation
        }
    }

    /// The current launch epoch, for guarding post-launch stamps: a
    /// launch that resolves after a newer start or a stop must not
    /// stamp `connectedSince` or adopt log paths for an instance that
    /// is no longer current.
    private func currentGeneration() -> Int {
        stateLock.withLock { _generation }
    }

    /// Decodes launch JSON back to its document, for post-launch
    /// adoption. Documents come out of `build`, so this only fails on
    /// programmer error — nil means skip adoption, never throw.
    private func documentDict(from json: String) -> XrayJSONObject? {
        guard let decoded = try? JSONDecoder().decode(XrayJSONValue.self, from: Data(json.utf8)),
              case .object(let dict) = decoded else { return nil }
        return dict
    }

    /// Clears a stale TUN descriptor from the process before launching
    /// a document that carries a TUN inbound but no descriptor of its
    /// own: the engine applies document `env` into its process at start
    /// and never unsets, so a descriptor left by an earlier TUN session
    /// would hijack this launch into reading a dead fd. Runs at launch,
    /// never at build — inspecting a document must not touch process
    /// state. Swift never installs these variables itself, so anything
    /// found in the process is engine residue by definition: the
    /// document is the only carrier the launch honors, and a process
    /// value with no document counterpart is always cleared, never
    /// inherited.
    private func clearStaleTunDescriptorIfNeeded(for dict: XrayJSONObject) {
        guard case .array(let inbounds) = dict["inbounds"],
              inbounds.contains(where: { $0.objectValue?["protocol"]?.stringValue == "tun" }) else { return }
        let env = dict["env"]?.objectValue ?? [:]
        if env["xray.tun.fd"] == nil && env["XRAY_TUN_FD"] == nil {
            XrayTunEntry.clearStaleFileDescriptor()
        }
    }

    /// First-wins latch for the deadline race below. Two detached tasks
    /// (the timer, the launch waiter) share one continuation, and
    /// continuations trap on a second resume — the gate lets exactly one
    /// side through. Lock-disciplined like the rest of this type.
    private final class StartRaceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false

        func settleOnce(_ action: () -> Void) {
            let first = lock.withLock {
                defer { settled = true }
                return !settled
            }
            if first { action() }
        }
    }

    /// Stops the instance left behind by a timed-out start, but only
    /// when nothing newer began since: a follow-up start or stop bumps
    /// the epoch, and a stale timeout must never kill the current
    /// instance. Best effort — errors are swallowed, success is logged.
    private func stopIfCurrent(generation: Int) {
        let current = stateLock.withLock { _generation == generation }
        guard current else { return }
        try? stop()
    }

    /// Every start replaces: the engine holds one instance per process
    /// and launching over a live one throws, so a running instance is
    /// stopped first. Safe to call idle — the stop is skipped when
    /// nothing runs.
    private func replaceRunningInstance() throws {
        let running: Bool
        do {
            running = try LifecycleCalls.isRunning()
        } catch {
            // Never launch blind silently: if the probe itself failed,
            // say so in the flight log. The launch still proceeds — a
            // live engine answers the launch with a refusal the caller
            // can act on (stop, then retry), which beats deadlocking
            // every start on a broken probe.
            log("engine state probe failed (\(error)); launching without knowing whether an instance runs")
            return
        }
        if running {
            try stop()
        }
    }

    // MARK: - Async conveniences

    /// Assembles off the calling thread with `options`, then launches
    /// without blocking it. Logging still runs on the caller's executor
    /// around the handoff. Starting again replaces a running instance
    /// first, like the sync variant.
    public func start(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) async throws {
        let config = try build(source, options: options)
        try replaceRunningInstance()
        let generation = nextGeneration()
        let dict = documentDict(from: config.json)
        if let dict { clearStaleTunDescriptorIfNeeded(for: dict) }
        log("launching engine (\(config.json.count) bytes of configuration)")
        let json = config.json
        do {
            try await Task.detached { try LifecycleCalls.launch(json) }.value
        } catch is CancellationError {
            // The detached launch doesn't inherit cancellation, so it
            // may still be settling: park a generation-guarded cleanup
            // so the orphan never outlives the attempt that spawned it.
            // A launch that already failed needs no cleanup — the guard
            // stands down on its own — so only cancellation reaps.
            Task.detached { [weak self] in
                self?.stopIfCurrent(generation: generation)
            }
            throw CancellationError()
        }
        if generation == currentGeneration() {
            if let dict { recordLogPaths(from: dict) }
            markLaunched()
            log("engine launched")
        } else {
            log("engine launch superseded by a newer start; stamps skipped")
        }
    }

    /// Starts a source like `start(_:options:)`, but gives up if the
    /// engine is not up within `deadline` and stops the half-started
    /// instance before throwing. Use from providers, where the system
    /// kills a start that overstays its time budget — a thrown error is
    /// recoverable, a watchdog kill is not.
    ///
    /// The launch runs detached so the timeout can truly abandon it: a
    /// child task would pin the group until the engine answered, which
    /// is exactly what the deadline refuses to wait for. If the
    /// deadline wins, the orphaned launch is left to settle and then
    /// stopped in the background — but only when nothing newer began
    /// since, so a follow-up start is never killed by a stale timeout.
    /// `connectedSince` is stamped only when the launch itself
    /// succeeded, never on the timeout path.
    public func start(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil,
        deadline: Duration
    ) async throws {
        let config = try build(source, options: options)
        try replaceRunningInstance()
        // Captured after the replace-stop above: any stop or start
        // from here on invalidates this attempt's cleanup.
        let generation = nextGeneration()
        let dict = documentDict(from: config.json)
        if let dict { clearStaleTunDescriptorIfNeeded(for: dict) }
        log("launching engine (\(config.json.count) bytes of configuration)")
        let json = config.json
        let override = launchOverride
        let launchTask = Task.detached {
            if let override {
                try override(json)
            } else {
                try LifecycleCalls.launch(json)
            }
        }
        // Race the launch against the deadline with two detached tasks
        // and a first-wins gate — deliberately not a task group. A group
        // waits for every child on exit, so a wedged launch would wedge
        // this call past the deadline: exactly what the deadline exists
        // to refuse. The loser is abandoned; a timed-out launch settles
        // on its own and is stopped in the background, but only when
        // nothing newer began since.
        let gate = StartRaceGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return // The launch won and cancelled us; nothing to do.
                }
                gate.settleOnce {
                    Task.detached { [weak self] in
                        _ = try? await launchTask.value
                        self?.stopIfCurrent(generation: generation)
                    }
                    continuation.resume(throwing: XrayError.timedOut(
                        "engine start exceeded its deadline and was stopped; check geo assets and listener ports"
                    ))
                }
            }
            Task.detached {
                do {
                    try await launchTask.value
                    timer.cancel()
                    gate.settleOnce { continuation.resume() }
                } catch {
                    timer.cancel()
                    gate.settleOnce { continuation.resume(throwing: error) }
                }
            }
        }
        if generation == currentGeneration() {
            if let dict { recordLogPaths(from: dict) }
            markLaunched()
            log("engine launched")
        } else {
            log("engine launch superseded by a newer start; stamps skipped")
        }
    }

    /// Assembles on the caller, then validates the result without
    /// blocking it. Only the engine check runs detached, so the
    /// non-Sendable transform never crosses threads. Like the sync
    /// variant this needs the engine stopped; use
    /// `XrayConfig.validateOffline()` while running.
    public func validate(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) async throws {
        let config = try build(source, options: options)
        let json = config.json
        try await Task.detached { try XrayConfig(json: json).validate() }.value
    }

    /// Provider sanity check over an assembled document: every inbound
    /// must listen on loopback (an extension cannot bind public
    /// addresses) and carry an explicit `listen`, a `tun` inbound must
    /// exist and carry its file descriptor (a tunnel with nothing to
    /// pump packets through launches a proxy, not a tunnel). Throws one
    /// `.invalidInput` listing every problem found, so a single run
    /// surfaces the whole list. Runs `build` first, so the geo gate and
    /// every other assembly rule apply. For UI, prefer
    /// `preflightIssues`, which returns the same problems as values.
    public func preflightForProvider(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws {
        let problems = try preflightIssues(source, options: options)
        if !problems.isEmpty {
            throw XrayError.invalidInput("provider preflight: " + problems.joined(separator: "; "))
        }
    }

    /// The same check as `preflightForProvider`, returned instead of
    /// thrown: an empty array means the document is provider-ready.
    /// Render each string next to its fix instead of parsing an error.
    public func preflightIssues(
        _ source: XrayConfigSource,
        options: XraySessionOptions? = nil
    ) throws -> [String] {
        let config = try build(source, options: options)
        guard let document = try? JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8)),
              let object = document.objectValue else {
            throw XrayError.invalidInput("provider preflight could not parse the assembled document")
        }
        var problems: [String] = []
        var sawTun = false
        var sawTunFD = false
        if case .array(let inbounds) = object["inbounds"] {
            for inbound in inbounds {
                guard let entry = inbound.objectValue else { continue }
                let tag = entry["tag"]?.stringValue ?? "?"
                if entry["protocol"]?.stringValue == "tun" {
                    sawTun = true
                    // The document env is the only carrier the launch
                    // honors: it clears the process variables first (the
                    // engine never unsets what an earlier start left),
                    // so a descriptor sitting only in the process would
                    // be wiped before the engine reads it. Without a
                    // document descriptor, the engine has no interface
                    // to read packets from. Empty strings count as
                    // missing on both sides.
                    if let env = object["env"]?.objectValue {
                        let docFDs = [env["xray.tun.fd"]?.stringValue, env["XRAY_TUN_FD"]?.stringValue]
                        if docFDs.contains(where: { !($0 ?? "").isEmpty }) {
                            sawTunFD = true
                        }
                    }
                    if !sawTunFD {
                        let processFDs = ["xray.tun.fd", "XRAY_TUN_FD"].compactMap { name -> String? in
                            guard let raw = getenv(name) else { return nil }
                            return String(cString: raw)
                        }
                        if processFDs.contains(where: { !$0.isEmpty }) {
                            // Seen, but not usable: the launch clears the
                            // process variables, so only the document counts.
                            // Mark it seen to keep the generic missing-fd
                            // message below from doubling this one.
                            sawTunFD = true
                            problems.append(
                                "the tun descriptor lives only in the process environment, which the launch clears: move it into XraySessionOptions.environment (xray.tun.fd) or tun(fileDescriptor:)"
                            )
                        }
                    }
                }
                guard let listen = entry["listen"]?.stringValue else {
                    problems.append(
                        "inbound '\(tag)' sets no listen address: set it to 127.0.0.1 explicitly instead of relying on the engine default"
                    )
                    continue
                }
                if !["127.0.0.1", "localhost", "::1"].contains(listen) {
                    problems.append(
                        "inbound '\(tag)' listens on \(listen): extensions can only bind loopback"
                    )
                }
            }
        }
        if !sawTun {
            problems.append("no tun inbound: a packet tunnel with nothing to pump packets through launches a proxy, not a tunnel")
        } else if !sawTunFD {
            problems.append("the tun inbound has no file descriptor: hand one over through XraySessionOptions.environment (xray.tun.fd)")
        }
        return problems
    }

    /// Fetches a subscription feed, unwraps it, tops up geo assets, and
    /// launches — the whole provider start in one call. The feed is
    /// fetched fresh every call: nothing is cached, nothing
    /// auto-refreshes. `http(s)` requires status 200; anything else
    /// (including `file:` URLs, handy for tests and bundled feeds) is
    /// accepted as-is. When `assetDirectory` is given it becomes
    /// `xray.location.asset` unless the options already set one, missing
    /// referenced databases are fetched into it, and the launch then runs
    /// under `deadline` like `start(_:options:deadline:)`. Feeds are capped
    /// at the engine's own request limit (`timeoutSeconds` bounds the
    /// wait): a declared or actual body past it throws before anything
    /// is decoded, so a hostile feed can't park memory. The top-up scans
    /// the feed text and the typed options without running `transform`,
    /// so the launch assembles exactly once — references a transform
    /// would inject are still caught by the launch-time gate instead.
    /// Keep transforms idempotent regardless: assembly may run them in
    /// other paths.
    public func start(
        remoteSubscription url: URL,
        ageSecret: String? = nil,
        assetDirectory: URL? = nil,
        options: XraySessionOptions? = nil,
        deadline: Duration = .seconds(30),
        timeoutSeconds: TimeInterval = 30
    ) async throws {
        log("fetching subscription from \(url.host ?? url.path)")
        let text: String
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeoutSeconds
            // Stream, don't buffer: `data(for:)` would park an entire
            // hostile body in memory before the cap below ever runs.
            // The cap is enforced per byte, so an unknown or lying
            // length can only cost the cap, never the machine.
            let cap = EngineTransport.maxRequestBytes
            let (bytes, response) = try await urlSession.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                guard http.statusCode == 200 else {
                    throw XrayError.bridgeFailed("subscription fetch returned HTTP \(http.statusCode)")
                }
                if http.expectedContentLength > Int64(cap) {
                    throw XrayError.invalidInput(
                        "subscription feed declares \(http.expectedContentLength) bytes, past the \(cap)-byte cap"
                    )
                }
            }
            var data = Data()
            if let expected = (response as? HTTPURLResponse)?.expectedContentLength,
               expected > 0, expected < Int64(cap) {
                data.reserveCapacity(Int(expected))
            }
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= cap else {
                    throw XrayError.invalidInput(
                        "subscription feed exceeds the \(cap)-byte cap"
                    )
                }
            }
            guard let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else {
                throw XrayError.invalidInput("subscription at \(url) is empty or not text")
            }
            text = decoded
        } catch let error as XrayError {
            throw error
        } catch {
            // Cancellation is cooperative, never a fetch failure: rethrow
            // it untouched so callers can distinguish cancel from error.
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            // A timeout is a timeout: report it as one so the caller
            // retries with a longer budget instead of debugging a
            // document that was never even fetched.
            if (error as NSError).code == NSURLErrorTimedOut {
                throw XrayError.timedOut("subscription fetch exceeded its \(timeoutSeconds)s budget")
            }
            throw XrayError.bridgeFailed("could not fetch subscription: \(error.localizedDescription)")
        }
        let unwrapped = try Xray.shared.decodeSubscription(text, ageSecret: ageSecret)
        var resolved = options ?? Xray.shared.options()
        if let assetDirectory {
            var env = resolved.environment ?? [:]
            // Either spelling counts: the engine reads the dotted name
            // first and the underscore one second, so a caller-set
            // `XRAY_LOCATION_ASSET` already answers the lookup and must
            // not be overridden.
            if env["xray.location.asset"] == nil && env["XRAY_LOCATION_ASSET"] == nil {
                env["xray.location.asset"] = assetDirectory.path
            }
            resolved.environment = env
            // Top up without assembling twice: scan the feed text plus
            // the typed options for geo references (no conversion, no
            // transform, no gate), fetch what is missing, then run the
            // single real build with the gate on.
            let needed = Self.referencedDatabases(sourceText: unwrapped, options: resolved)
            if !needed.isEmpty {
                _ = try await Xray.shared.ensureAssets(for: nil, databases: needed, in: assetDirectory)
            }
            // External files have no downloader behind them: fail here,
            // naming the file and where it must be placed, instead of
            // launching into the gate's refusal a moment later.
            let external = Self.referencedExternalFiles(sourceText: unwrapped, options: resolved)
            if !external.isEmpty {
                let docEnv: XrayJSONObject? = resolved.environment.map { env in
                    Dictionary(uniqueKeysWithValues: env.map { ($0.key, XrayJSONValue.string($0.value)) })
                }
                try XrayGeoAssets.check(externalFiles: external, env: docEnv)
            }
        }
        try await start(.shareLinks(unwrapped), options: resolved, deadline: deadline)
    }

    // MARK: - Private

    /// Geo databases a launch will need, read from the feed text plus
    /// the typed options — without converting, transforming, or gating,
    /// so the remote start assembles exactly once. A JSON feed is
    /// scanned for `geosite:`/`geoip:` references in its routing and
    /// dns sections; a raw link feed converts to outbounds, which carry
    /// no references, so only the options matter there. References a
    /// `transform` would inject are not visible here: they are still
    /// caught by the launch-time gate, which refuses to run without
    /// them — keep transforms out of the asset path, or pre-fetch
    /// those databases yourself.
    private static func referencedDatabases(sourceText: String, options: XraySessionOptions) -> [XrayGeoDatabase] {
        var names: Set<String> = []
        if let data = sourceText.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(XrayJSONValue.self, from: data),
           case .object(let dict) = decoded {
            for database in XrayGeoAssets.referenced(in: dict) {
                names.insert(database.rawValue)
            }
        }
        if let routing = options.routing {
            for rule in routing.rules {
                for text in rule.domains + rule.ips {
                    if let name = databaseName(in: text) { names.insert(name) }
                }
            }
        }
        if let dns = options.dns {
            for key in dns.hosts.keys {
                if let name = databaseName(in: key) { names.insert(name) }
            }
            for server in dns.servers {
                if case .detailed(_, let domains) = server {
                    for domain in domains {
                        if let name = databaseName(in: domain) { names.insert(name) }
                    }
                }
            }
        }
        return names.compactMap(XrayGeoDatabase.init)
    }

    /// The database name in a string like `"geosite:category-ads"`.
    private static func databaseName(in text: String) -> String? {
        for database in ["geosite", "geoip"] where text.hasPrefix("\(database):") {
            return database
        }
        return nil
    }

    /// External data files a remote launch will need: the same scan as
    /// `referencedDatabases`, but for `ext:` filenames, which no
    /// downloader can fetch — the top-up checks them for existence
    /// instead of downloading them.
    private static func referencedExternalFiles(sourceText: String, options: XraySessionOptions) -> [String] {
        var files: Set<String> = []
        if let data = sourceText.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(XrayJSONValue.self, from: data),
           case .object(let dict) = decoded {
            files.formUnion(XrayGeoAssets.referencedExternalFiles(in: dict))
        }
        var candidates: [String] = []
        if let routing = options.routing {
            for rule in routing.rules {
                candidates += rule.domains
                candidates += rule.ips
            }
        }
        if let dns = options.dns {
            candidates += dns.hosts.keys
            for server in dns.servers {
                if case .detailed(_, let domains) = server {
                    candidates += domains
                }
            }
        }
        for text in candidates where text.hasPrefix("ext:") {
            if let file = XrayGeoAssets.externalFile(named: text) {
                files.insert(file)
            }
        }
        return files.sorted()
    }

    /// Fail-fast geo database check over the final, post-transform
    /// document: what the routing and dns sections reference must exist
    /// wherever the engine will look for it. The document's `env` counts
    /// first, so an asset path shipped in it overrides the defaults.
    private static func checkGeoAssets(in config: XrayJSONObject) throws {
        let env = config["env"]?.objectValue
        try XrayGeoAssets.check(
            referenced: XrayGeoAssets.referenced(in: config),
            env: env
        )
        try XrayGeoAssets.check(
            externalFiles: XrayGeoAssets.referencedExternalFiles(in: config),
            env: env
        )
    }

    /// Guards every SOCKS inbound with the username + password. Other
    /// inbound types (HTTP, dokodemo-door, TUN) pass through untouched.
    /// A configuration with no SOCKS inbound is rejected as
    /// misconfiguration.
    private static func applyCredentials(
        _ credentials: XrayCredentials?,
        to config: inout XrayJSONObject
    ) throws {
        guard let credentials else { return }
        guard case .array(var inbounds) = config["inbounds"] else {
            throw XrayError.invalidInput("credentials need a SOCKS inbound to protect, and this configuration has no inbounds")
        }
        var guarded = false
        for index in inbounds.indices {
            if case .object(var inbound) = inbounds[index], inbound["protocol"] == .string("socks") {
                Self.guardSocksInbound(&inbound, using: credentials)
                inbounds[index] = .object(inbound)
                guarded = true
            }
        }
        if !guarded {
            throw XrayError.invalidInput("credentials need a SOCKS inbound to protect, and this configuration has none")
        }
        config["inbounds"] = .array(inbounds)
    }

    /// Guards one SOCKS inbound object with a username + password.
    private static func guardSocksInbound(_ inbound: inout XrayJSONObject, using credentials: XrayCredentials) {
        var settings = inbound["settings"]?.objectValue ?? [:]
        settings["auth"] = .string("password")
        settings["users"] = .array([.object([
            "user": .string(credentials.username),
            "pass": .string(credentials.password),
        ])])
        inbound["settings"] = .object(settings)
    }

    /// Returns the first outbound's tag, assigning `"proxy"` when it has
    /// none. Returns nil when the document has no outbounds at all.
    /// Resolves the `.proxy` destination to an outbound tag: the first
    /// outbound that actually proxies. Conversion output usually leads
    /// with `direct`, and routing the proxy there would bypass the
    /// tunnel — so `freedom`, `blackhole`, and `dns` outbounds are
    /// skipped. Falls back to the first outbound when nothing else
    /// qualifies. An untagged winner is tagged `"proxy"` in place so
    /// later stages agree on the name.
    private static func ensureProxyTag(in config: inout XrayJSONObject) -> String? {
        guard case .array(var outbounds) = config["outbounds"], !outbounds.isEmpty else { return nil }
        let passthrough: Set<String> = ["freedom", "blackhole", "dns"]
        let index = outbounds.firstIndex { outbound in
            guard case .object(let entry) = outbound else { return false }
            guard case .string(let proto) = entry["protocol"] else { return true }
            return !passthrough.contains(proto)
        } ?? outbounds.startIndex
        guard case .object(var winner) = outbounds[index] else { return nil }
        if case .string(let tag) = winner["tag"] { return tag }
        winner["tag"] = .string("proxy")
        outbounds[index] = .object(winner)
        config["outbounds"] = .array(outbounds)
        return "proxy"
    }

    /// The first outbound's tag, if any.
    private static func firstOutboundTag(in config: XrayJSONObject) -> String? {
        guard case .array(let outbounds) = config["outbounds"],
              case .object(let first) = outbounds.first,
              case .string(let tag) = first["tag"] else { return nil }
        return tag
    }

    /// Appends the standard `direct` (freedom), `block` (blackhole), and
    /// `dns-out` (dns) outbounds when the routing rules reference
    /// them but the document does not define them. A `final`
    /// destination arrives as a trailing match-all rule, so it is
    /// covered by the same scan — no special case.
    private static func ensureStandardOutbounds(in config: inout XrayJSONObject) {
        guard case .object(let routing) = config["routing"],
              case .array(let rules) = routing["rules"] else { return }
        var referenced: Set<String> = []
        for rule in rules {
            if case .object(let entry) = rule,
               case .string(let tag) = entry["outboundTag"] {
                referenced.insert(tag)
            }
        }
        let standards = [("direct", "freedom"), ("block", "blackhole"), ("dns-out", "dns")]
        var outbounds = config["outbounds"]?.arrayValue ?? []
        let before = outbounds.count
        for (tag, proto) in standards where referenced.contains(tag) {
            let exists = outbounds.contains {
                if case .object(let entry) = $0, entry["tag"] == .string(tag) { return true }
                return false
            }
            if !exists {
                outbounds.append(.object(["protocol": .string(proto), "tag": .string(tag)]))
            }
        }
        if outbounds.count != before {
            config["outbounds"] = .array(outbounds)
        }
    }

    /// Routes a `dokodemo-door` XrayDNS relay inbound at the engine's own
    /// `dns` section: without an `inboundTag` → `dns-out` rule the
    /// relay's queries fall through to `final` (or the proxy) instead
    /// of the local resolver. Appends the rule when no rule already
    /// claims the relay tag, and creates the routing section when the
    /// document has none. Runs after the transform so transform-added
    /// relays are covered; runs before the standard-outbound backfill
    /// so a referenced `dns-out` always exists. An explicit route for
    /// the tag always wins over this default.
    private static func ensureDNSRelayRoute(in config: inout XrayJSONObject) {
        guard config["dns"] != nil,
              case .array(let inbounds) = config["inbounds"] else { return }
        let relayTags = inbounds.compactMap { inbound -> String? in
            guard case .object(let entry) = inbound,
                  entry["protocol"]?.stringValue == "dokodemo-door",
                  case .string(let tag) = entry["tag"] else { return nil }
            return tag
        }
        guard !relayTags.isEmpty else { return }
        var routing = config["routing"]?.objectValue ?? [:]
        var rules = routing["rules"]?.arrayValue ?? []
        let covered = rules.contains { rule in
            guard case .object(let entry) = rule else { return false }
            let claimed: [String]
            if case .array(let tags) = entry["inboundTag"] {
                claimed = tags.compactMap(\.stringValue)
            } else if case .string(let tag) = entry["inboundTag"] {
                claimed = [tag]
            } else {
                return false
            }
            return claimed.contains { relayTags.contains($0) }
        }
        if !covered {
            rules.append(.object([
                "type": .string("field"),
                "inboundTag": .array(relayTags.map(XrayJSONValue.string)),
                "outboundTag": .string("dns-out"),
            ]))
            routing["rules"] = .array(rules)
            config["routing"] = .object(routing)
        }
    }

    private func log(_ message: String) {
        let sink: ((String) -> Void)? = stateLock.withLock {
            _entries.append("\(Self.stamp.string(from: Date())) \(message)")
            if _entries.count > 200 {
                _entries.removeFirst(_entries.count - 200)
            }
            return _logger
        }
        sink?(message)
    }

    /// The last lifecycle notes this session recorded, oldest first,
    /// capped at 200 entries: launches, byte counts, failures. A flight
    /// recorder for the package side — what it did, not what the engine
    /// saw. For engine output, see `recentEngineLogs`.
    public func recentLogs(limit: Int = 200) -> [String] {
        stateLock.withLock { Array(_entries.suffix(max(0, limit))) }
    }

    /// Tails the engine's own log file named by the last launched
    /// document: the `access` / `error` paths in its log section. Paths
    /// are adopted only on a successful launch, so this tails the
    /// current run — a failed launch keeps the previous run's tail. The
    /// engine only writes when the document points it at files, so a
    /// `stdout`, `stderr`, `none`, or missing path throws `.invalidInput`
    /// naming the fix. Reads at most the trailing 256 KiB, so a verbose
    /// access log can't blow up the caller. The bridge exposes no log
    /// stream, so this is file tailing — the only engine output there is.
    public func recentEngineLogs(_ kind: XrayEngineLogKind = .error, lines: Int = 100) throws -> [String] {
        let path: String? = stateLock.withLock {
            switch kind {
            case .access: return _accessLogPath
            case .error: return _errorLogPath
            }
        }
        guard let path else {
            throw XrayError.invalidInput(
                "no \(kind) log file recorded: point the document's log section at a file path to capture engine output"
            )
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let window: UInt64 = 262_144
            try handle.seek(toOffset: size > window ? size - window : 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }
            var text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            if size > window, let first = text.firstIndex(of: "\n") {
                text.removeSubrange(...first)
            }
            var tail = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if tail.last?.isEmpty == true {
                tail.removeLast()
            }
            return Array(tail.suffix(max(0, lines)))
        } catch {
            throw XrayError.bridgeFailed("could not read engine log at \(path): \(error.localizedDescription)")
        }
    }

    private func recordLogPaths(from dict: XrayJSONObject) {
        let section = dict["log"]?.objectValue
        stateLock.withLock {
            _accessLogPath = Self.filePath(section?["access"]?.stringValue)
            _errorLogPath = Self.filePath(section?["error"]?.stringValue)
        }
    }

    private static func filePath(_ value: String?) -> String? {
        // `none`, `stdout`, and `stderr` are streams, not files: nothing
        // to tail, so they record as missing and `recentEngineLogs`
        // throws the "point at a file" guidance instead of a read error.
        guard let value, !value.isEmpty, value != "none", value != "stdout", value != "stderr" else { return nil }
        return value
    }

    private func markLaunched() {
        stateLock.withLock { _connectedSince = Date() }
    }

    // Clears launch side effects on stop. The log file paths survive:
    // the files are still on disk, so `recentEngineLogs` keeps
    // tailing the last run until the next start overwrites them.
    private func markStopped() {
        stateLock.withLock {
            _connectedSince = nil
        }
    }
}

/// Username + password guarding the local entry points. Applied to every
/// SOCKS inbound in the assembled configuration (`auth: "password"`
/// with the pair in `users`); other inbound types are untouched.
public struct XrayCredentials: Sendable {
    public var username: String
    public var password: String

    internal init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Traffic-sniffing settings injected into a configuration's inbounds
/// before launch. Applied per inbound: inbounds that already carry their
/// own `sniffing` object keep it, every other inbound receives this one.
public struct XraySniffing: Codable, Sendable {
    /// XrayDestination protocols to sniff (e.g. "http", "tls", "quic", "fakedns").
    public var destOverride: [String]

    /// Whether sniffing is on.
    public var enabled: Bool

    /// Whether to route only sniffed traffic.
    public var routeOnly: Bool

    /// Domains to leave alone.
    public var domainsExcluded: [String]

    /// Whether to extract metadata without touching payloads.
    public var metadataOnly: Bool

    internal init(
        destOverride: [String] = ["http", "tls", "quic", "fakedns"],
        enabled: Bool = true,
        routeOnly: Bool = false,
        domainsExcluded: [String] = [],
        metadataOnly: Bool = false
    ) {
        self.destOverride = destOverride
        self.enabled = enabled
        self.routeOnly = routeOnly
        self.domainsExcluded = domainsExcluded
        self.metadataOnly = metadataOnly
    }

    /// The object as the engine expects it inside an inbound.
    var wireObject: [String: XrayJSONValue] {
        [
            "destOverride": .array(destOverride.map(XrayJSONValue.string)),
            "enabled": .bool(enabled),
            "routeOnly": .bool(routeOnly),
            "metadataOnly": .bool(metadataOnly),
            "domainsExcluded": .array(domainsExcluded.map(XrayJSONValue.string)),
        ]
    }

    /// Merges these settings into every inbound of a parsed configuration
    /// dictionary that does not already define `sniffing`.
    func inject(into config: inout XrayJSONObject) {
        guard case .array(var inbounds) = config["inbounds"] else { return }
        for index in inbounds.indices {
            if case .object(var inbound) = inbounds[index], inbound["sniffing"] == nil {
                inbound["sniffing"] = .object(wireObject)
                inbounds[index] = .object(inbound)
            }
        }
        config["inbounds"] = .array(inbounds)
    }
}

// Value factories for session credentials, sniffing, and the full options
// bag. `start`/`build` still take `XraySessionOptions`; this only changes how one is
// made.
extension Xray {
    public func credentials(username: String, password: String) -> XrayCredentials {
        XrayCredentials(username: username, password: password)
    }

    public func sniffing(
        destOverride: [String] = ["http", "tls", "quic", "fakedns"],
        enabled: Bool = true,
        routeOnly: Bool = false,
        domainsExcluded: [String] = [],
        metadataOnly: Bool = false
    ) -> XraySniffing {
        XraySniffing(
            destOverride: destOverride, enabled: enabled, routeOnly: routeOnly,
            domainsExcluded: domainsExcluded, metadataOnly: metadataOnly
        )
    }

    public func options(
        sniffing: XraySniffing? = nil,
        transform: ((inout XrayJSONObject) -> Void)? = nil,
        routing: XrayRouting? = nil,
        credentials: XrayCredentials? = nil,
        tun: XrayTunEntry? = nil,
        environment: [String: String]? = nil,
        observatory: XrayObservatory? = nil,
        geoCheck: Bool = true,
        dns: XrayDNS? = nil,
        fakeDNS: [XrayFakeDNS]? = nil,
        log: XrayLog? = nil,
        metricsPort: Int? = nil
    ) -> XraySessionOptions {
        XraySessionOptions(
            sniffing: sniffing, transform: transform, routing: routing,
            credentials: credentials, tun: tun, environment: environment,
            observatory: observatory, geoCheck: geoCheck, dns: dns,
            fakeDNS: fakeDNS, log: log, metricsPort: metricsPort
        )
    }
}
