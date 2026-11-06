# 04 — Checking core status: running, version, health, forensics

Four questions, four calls, each with a different price. Use the cheapest
one that answers what you asked.

## `isRunning()` — is anything up?

```swift
// Asks the engine itself, not a cached flag. Cheap; poll freely.
if try session.isRunning() { /* show Disconnect */ }
```

## `version()` — which engine build is this?

```swift
// Answers e.g. "26.10.31": the Xray-core compiled into the framework.
// Compare against your minimum before enabling features a newer core added.
let v = try engine.version()
```

## `health()` — is it up AND answering?

```swift
// false when idle; true when an instance is up and the bridge round-trips;
// throws .timedOut when the bridge itself is wedged. Each call is bounded
// at ~5 seconds, so a stuck engine cannot hang the poll loop.
Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { _ in
    do {
        connected = try engine.health()
    } catch {
        connected = false   // wedged bridge: rebuild, don't retry (see 09)
    }
}
```

`isRunning` asks state; `health` proves liveness. The status dot wants
`health`; the button label is fine with `isRunning`.

## `connectedSince` — how long has THIS instance been up?

```swift
// Stamped on every successful launch path, cleared on stop().
// Pair with traffic totals: counters reset on launch, so a total without
// this stamp is meaningless after a reconnect.
if let since = session.connectedSince {
    uptimeLabel = Date().timeIntervalSince(since).formatted()
}
```

## Forensics without a launch

```swift
// Last 200 lifecycle notes, lock-guarded. Works regardless of state.
session.recentLogs()

// The engine's own log files, tailed. `error` (default) or `access`,
// last N lines. Throws .invalidInput naming the file when the document
// never named one — the assembler must set log paths for this to read.
try session.recentEngineLogs(.error, lines: 100)
```

After an unexpected drop: `connectedSince == nil` + the error tail is the
whole "why did it disconnect" screen. Full logging setup in
`05-logging.md`.

## Preflight — will this config survive the provider?

```swift
// Values, not throws-one-at-a-time: every provider problem listed —
// non-loopback inbound, missing tun, missing descriptor — as strings
// for UI, or the throwing form for a gate.
let issues = try session.preflightIssues(.json(config.json), options: opts)
guard issues.isEmpty else { showProblems(issues); return }
try session.preflightForProvider(.json(config.json), options: opts)
```

Run before every provider launch (07). The two provider killers —
a missing descriptor and a non-loopback listen — become checklist items
instead of crashes.
