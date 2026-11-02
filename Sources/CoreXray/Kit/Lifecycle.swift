import Foundation

// One-shot engine questions and lifecycle primitives on the shared instance.
// No validation needed here — these are direct readings and the launch/stop
// pair `Xray.Session` funnels into.

extension Xray {
    /// Xray-core version compiled into the framework, e.g. "26.10.29".
    public func version() throws -> String {
        try LifecycleCalls.version()
    }

    /// Whether an engine instance started earlier in this process is running.
    public func isRunning() throws -> Bool {
        try LifecycleCalls.isRunning()
    }

    /// Starts this process's engine instance with the given Xray JSON
    /// configuration. Blocks until the engine is up. This is the raw
    /// primitive: launching over a running instance throws the engine's
    /// already-running refusal instead of replacing — stop first, or start
    /// through `Session`, which replaces by stopping first.
    public func launch(_ configuration: String) throws {
        try LifecycleCalls.launch(configuration)
    }

    /// Stops this process's running engine instance.
    public func stop() throws {
        try LifecycleCalls.stop()
    }

    /// Sends a raw request document to the engine and returns the raw
    /// response document. Throws `Xray.Error` on engine-reported failure.
    /// Strings returned by the engine are malloc'd; the transport releases
    /// them internally, so no cleanup is left for callers.
    public func sendRawRequest(_ request: String) throws -> String {
        try LifecycleCalls.rawRequest(request)
    }
}

// Liveness probe: the engine answers and an instance is up.
extension Xray {
    /// True when an engine instance is up and answering on the bridge: the
    /// state call proves the instance exists, the version round-trip proves
    /// the bridge is alive. False (not a throw) when nothing is running.
    /// Poll this from a watchdog; a throw means the bridge itself is wedged.
    ///
    /// Each bridge call runs on its own thread with a short leash: a wedged
    /// bridge call never returns, so an unbounded wait would hang the
    /// caller the same way. Past the timeout this throws `.timedOut`
    /// instead of hanging — treat that as wedged, not idle. The stuck
    /// thread is abandoned (it exits if the bridge ever answers); a wedged
    /// bridge plus a polling watchdog therefore accumulates one sleeper
    /// per poll, which is why wedged means restart the process.
    public func health() throws -> Bool {
        guard try awaitDetached(seconds: 5, LifecycleCalls.isRunning) else { return false }
        _ = try awaitDetached(seconds: 5, LifecycleCalls.version)
        return true
    }

    /// Runs a blocking bridge call on a spare thread with a timeout, so a
    /// wedged CGo call cannot hang the caller forever. Throws `.timedOut`
    /// past the deadline; bridge failures pass through untouched.
    private func awaitDetached<T>(seconds: Int, _ work: @escaping () throws -> T) throws -> T {
        let lock = NSLock()
        var result: Result<T, Swift.Error>?
        let done = DispatchSemaphore(value: 0)
        Thread {
            let outcome: Result<T, Swift.Error>
            do { outcome = .success(try work()) } catch { outcome = .failure(error) }
            lock.withLock { result = outcome }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success else {
            throw Error.timedOut("the bridge did not answer within \(seconds)s; it may be wedged")
        }
        switch lock.withLock({ result }) {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw Error.timedOut("the bridge answered with no result")
        }
    }
}
