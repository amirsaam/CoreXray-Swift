# 06. Ping: one config, or all of them, through the real path

One-shot latency comes from the engine's own measurement. It sends a real
request through the real outbound, not ICMP. Two hard rules apply. The
engine must be STOPPED. Measurement runs an isolated instance, and the
bridge refuses otherwise. Each call takes at most 5 targets.

## Pinging one config

```swift
// The target is a CONFIG, not a link: convert first. outboundTag picks
// which outbound to measure inside a multi-outbound document; omit for
// single-server configs (the converter's output).
let json = try engine.configuration(.shareLinks(oneLink)).json
let target = engine.pingTarget(config: json)

// Timeout is validated in the factory. A bad value fails before the
// engine is even stopped. testURL must be absolute HTTP(S).
let options = try engine.pingOptions(
    timeoutSeconds: 10,
    testURL: "https://www.google.com/generate_204"   // default; 204, no body
)

// Throws .invalidInput("ping needs the engine stopped...") when running.
let results = try engine.ping([target], options: options)
let ms = results[0]
ms.succeeded             // Bool
ms.latencyMilliseconds   // Int64. 0 on failure, never a sentinel
ms.failureReason         // String?. The engine's text, nil on success
```

Failed measurements normalize to `0` with a reason. The engine's internal
sentinels (`10000` / `11000`) never leak into your UI. If you see one,
it is a package bug. Report it.

## Pinging all configs (the server-list flow)

```swift
// Split the feed into one link per row…
let links = feed.components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

// …convert each to its JSON, measure in batches of 5, sort.
// Do this while idle: before connecting, or after disconnecting.
let options = try engine.pingOptions(timeoutSeconds: 10)
let ranked: [(link: String, ms: Int64)] = try stride(
    from: 0, to: links.count, by: 5
).flatMap { batch in
    let slice = links[batch..<min(batch + 5, links.count)]
    let targets = try slice.map {
        engine.pingTarget(config: try engine.configuration(.shareLinks($0)).json)
    }
    return try zip(slice, engine.ping(targets, options: options)).map { link, r in
        (link, r.succeeded ? r.latencyMilliseconds : .max)
    }
}.sorted { $0.ms < $1.ms }
```

Cache the ranking per link and connect the winner (02). Re-ping on
network change, not on a timer. Every run costs real requests through
every measured server.

## While connected: don't ping, read the observatory

`ping` refuses while running, by bridge design. The running-state
equivalent is the `observatory` section (03, Step 4). It probes the
outbounds in the running config on an interval, and its answers ride
along in every traffic snapshot. The pattern: ping the candidates while
idle, connect the winner, and watch the observatory while connected.

## Rules that throw (all before the engine is touched)

- Engine running → `.invalidInput`, "stop the session first".
- Zero targets, or more than 5 → `.invalidInput` with the limit.
- Non-positive timeout → `.invalidInput` from the factory itself.
- `testURL` not absolute HTTP(S) → `.invalidInput` naming the requirement.
