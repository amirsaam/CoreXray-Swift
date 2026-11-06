# 03 — Reading traffic stats: uplink, downlink, speed, probes

Counters require a metrics endpoint: either `metricsPort` on the assembly
or `metricsPort` in `options`. The endpoint binds loopback only and also
serves the engine's own pprof block — treat it as a local listener, keep
the port unadvertised.

## Step 1 — Poll snapshots

```swift
// One monitor per metrics port. Port is range-checked; host stays
// 127.0.0.1 unless you know why it shouldn't.
let monitor = try engine.trafficMonitor(port: 24242)

let first = try await monitor.snapshot()
try await Task.sleep(nanoseconds: 1_000_000_000)
let second = try await monitor.snapshot()
```

A snapshot is every tagged inbound and outbound plus summed totals:

```swift
second.taken                    // Date — the reading's timestamp
second.inbound["socks-in"]      // XrayTrafficCounter(up:down:) per tag
second.outbound["proxy"]        // per-outbound counters
second.totalUp / second.totalDown
second.uplink / second.downlink // outbound side only (see below)
second.observatory["proxy"]     // XrayOutboundProbe, when configured
```

## Step 2 — Read the side that matches the wire

The engine counts every byte twice — once on the inbound it entered
through, once on the outbound it left through. So:

- `totalUp` / `totalDown` = inbound + outbound = **2x the bytes on wire**.
- `uplink` / `downlink` = outbound side only = **the bytes the device
  actually exchanged**. Dashboards want these.

```swift
session.usage.advance(second)   // one call per poll — that is the feature
let upBytes = session.usage.usedUp      // uploaded this session, wire-accurate
let downBytes = session.usage.usedDown  // downloaded this session
let total = session.usage.usedTotal     // their sum, for the data label
```

`session.usage` (`XrayDataUsage`) accumulates outbound-side deltas, so
it always answers the real number: the first snapshot only sets the
baseline, an engine restart between polls reads as fresh traffic
instead of going negative, and `stop()` keeps the counters for the
disconnect report — the next successful `start` resets them, so each
session owns its numbers. Reading `snapshot.uplink` directly gives the
same value inside one uninterrupted run, but `usage` is the API that
stays correct across restarts and stops.

## Step 3 — Speeds from deltas

```swift
let delta = second.delta(since: first)  // wall-clock gap derived from taken
delta.seconds                 // actual elapsed, not assumed
delta.uplinkPerSecond         // upload speed — poll every 1s and this IS B/s
delta.downlinkPerSecond       // download speed
delta.totalUp / delta.totalDown   // doubled; avoid for UI
```

Polling once a second reads as live speed. Counters reset on every
launch, so stamp `session.connectedSince` next to them — a speed without
an uptime anchor lies after a reconnect.

## Step 4 — Which outbounds are alive (observatory)

Part of the running config, not a separate call:

```swift
var a = engine.assembler(.shareLinks(feed))
a.observatory = try engine.observatory(
    subjectSelector: ["proxy"],               // which outbounds to probe
    probeURL: "https://www.google.com/generate_204",
    probeInterval: "30s"
)
a.metricsPort = 24242
```

Results arrive in the snapshot — no extra polling:

```swift
if let probe = second.observatory["proxy"] {
    probe.alive                        // Bool
    probe.delayMilliseconds            // Int64? — nil until a probe succeeds
    probe.failureReason                // engine's text for the last failure
    probe.lastSeen / probe.lastTry     // Dates
}
```

Covers only outbounds in the running config. Probing costs one real
request per selected outbound per interval — keep the selector tight.
For servers NOT in the running config, use one-shot `ping` while
stopped (see `06-ping.md`).

## Step 5 — Fire on stalls (watchdog)

Polling answers "how much"; the watchdog answers "has anything moved":

```swift
let watchdog = try engine.trafficWatchdog(
    port: 24242,
    interval: 10,       // poll cadence
    stalledAfter: 60    // silence that counts as a stall
) { Task { await rebuild() } }    // hop off — the callback must return fast
watchdog.start()
// ... session ends:
watchdog.stop()
```

One fire per episode, reset by any movement; failed snapshots count as
stalls, so a dead metrics endpoint fires instead of reading as calm. An
idle tunnel reads as stalled — start after first traffic or set the
window generously. Full loop in `09-stay-connected.md`.
