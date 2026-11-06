# 09 — Staying connected: watchdog, rebuild, preflight

Connections die — servers go down, networks change, the OS reclaims the
provider. The package detects (watchdog), and your app rebuilds
(preflight + start). This file is the loop; 07 wires it into the
provider.

## Step 1 — Detect: the watchdog

```swift
// After every launch, when the metrics port is up:
watchdog = try engine.trafficWatchdog(
    port: 24242,
    interval: 10,       // poll cadence
    stalledAfter: 60    // silence that counts as a stall
) { [weak self] in
    // Hop off: the callback must return fast. Route back to your context.
    Task { await self?.rebuild() }
}
watchdog?.start()
```

Latched: one fire per stall episode, reset by any movement. Failed
snapshots count as stalls, so a dead metrics endpoint fires too. An idle
tunnel reads as stalled — start after first traffic or be generous with
the window. `watchdog?.stop()` in teardown; a dropped instance stands
down on its own, but explicit reads better.

## Step 2 — Confirm: health, not hope

```swift
func rebuild() async {
    // A stall is a suspicion, not a diagnosis. The bridge may be wedged
    // (health throws .timedOut) or the engine may already be gone.
    let alive: Bool
    do { alive = try engine.health() } catch { alive = false }
    guard !alive else { return }   // traffic moved again — stand down
    ...
}
```

## Step 3 — Rebuild: same document, fresh instance

```swift
    // Keep the last working document in memory — rebuilding from the
    // stored string skips conversion entirely and is the fastest path.
    do {
        try await session.start(lastConfig, options: lastOptions,
                                deadline: 20)
        return   // replaced the dead instance; counters reset, stamp moves
    } catch {
        // Rebuild failed: fall through to the next server (06 ranking).
        switchToNextServer()
    }
```

`start` replaces — no explicit stop of the corpse needed. `connectedSince`
re-stamps, counters reset: pair them in the UI so "12 MB in 4 min" never
mixes two lifetimes.

## Step 4 — Harden the path: preflight every launch

```swift
let issues = try session.preflightIssues(.json(config.json), options: opts)
guard issues.isEmpty else {
    // Non-loopback inbound, missing tun, missing descriptor — fix, don't
    // launch. In the provider this is the difference between a clean
    // error and a dead tunnel with no logs.
    report(issues); return
}
```

Preflight is cheap and launch-free; there is no reason to skip it where
a failed launch costs the user their connection.

## The loop, in one place

```
launch → watchdog.start → stall fires → health? → alive: ignore
                                              → dead: start(lastConfig)
                                                    → ok: done
                                                    → fail: next server (06)
stop → watchdog.stop → session.stop → forensics kept (05)
```

What this does NOT do: switch networks for you (re-resolve on path
change and rebuild), pick servers (06 ranking feeds `lastConfig`), or
persist anything (your container holds the plan, 07). Detection and
replacement are the package's; policy is yours.
