# 04. Checking core status: running, version, health, forensics

Four questions, four calls. Each call costs a different amount. Use the
cheapest one that answers what you asked.

## `isRunning()`. Is anything up?

```swift
// Asks the engine itself, not a cached flag. Cheap; poll freely.
if try session.isRunning() { /* show Disconnect */ }
```

## `version()`. Which engine build is this?

```swift
// Answers e.g. "26.10.31": the Xray-core compiled into the framework.
// Compare against your minimum before enabling features a newer core added.
let v = try engine.version()
```

## `health()`. Is it up and answering?

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

`isRunning` reports state. `health` proves liveness. Drive the status dot
from `health`. The button label can use `isRunning`.

## `connectedSince`. How long has this instance been up?

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
// never named one. The assembler must set log paths for this to read.
try session.recentEngineLogs(.error, lines: 100)
```

After an unexpected drop, `connectedSince == nil` plus the error tail make
up the "why did it disconnect" screen. Full logging setup is in
`05-logging.md`.

## Preflight. Will this config survive the provider?

```swift
// Values, not throws-one-at-a-time: every provider problem listed:
// non-loopback inbound, missing tun, missing descriptor, as strings
// for UI, or the throwing form for a gate.
let issues = try session.preflightIssues(.json(config.json), options: opts)
guard issues.isEmpty else { showProblems(issues); return }
try session.preflightForProvider(.json(config.json), options: opts)
```

Run before every provider launch (07). The two provider killers are
a missing descriptor and a non-loopback listen. They come back as checklist
items instead of crashes.
