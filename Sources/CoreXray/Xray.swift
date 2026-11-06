import Foundation

// Re-exports the bundled binary target, so advanced users can call the raw
// `CGoInvoke` / `CGoFree` C entry points with a single `import CoreXray`. The
// typed API funnels all engine traffic through `Calls/EngineTransport`.

@_exported import LibXray

/// Entry point for everything the bundled libXray engine can do.
///
/// Grab it via `Xray.shared` and call instance methods (`shared.ping(...)`).
/// The human-readable API lives in `Kit/` as extensions of this class —
/// one-shot questions, ports, latency, configs, sessions, geo — while
/// `Calls/` holds the internal engine plumbing those methods delegate to.
/// When a new upstream capability has no typed wrapper yet,
/// `sendRawRequest(_:)` is the escape hatch.
///
/// Sessions multiply but the engine does not: you may hold an app-side
/// session and a provider-side session (or several in tests), yet only
/// one instance ever runs per process. Starting a second one replaces
/// the first — every start calls `replaceRunningInstance()` first — so
/// coordinate ownership in your app instead of assuming isolation. The
/// same sharing applies to staleness guards: a timed-out start's
/// background cleanup only stops what it launched, verified by a
/// process-wide epoch, and concurrent use from several sessions is safe
/// because the guards are per-launch, not per-session.
///
/// Layout: `Xray.swift` is only this declaration. Types live in `Kit/`,
/// engine calls in `Calls/`, one type per file.
public final class Xray: Sendable {
    /// The one engine owner in the process. The engine itself is
    /// process-global, so every call funnels through here. All engine
    /// traffic is serialized through the transport lane, which is what makes
    /// the shared instance safe to use from any thread or actor.
    public static let shared = Xray()

    /// Only `shared` exists: one engine per process, one owner.
    private init() {}
}
