# 01 — Running the core from full JSON

When you already own a complete Xray configuration document — exported
from another client, generated server-side, or hand-written — skip the
assembler entirely. The session starts any full document as-is.

## Step 1 — Hold a session

```swift
import CoreXray

let engine = Xray.shared

// One session owns the one engine. Keep it for the app's lifetime;
// starting again replaces the running instance.
let session = engine.newSession { print("[xray]", $0) }
```

## Step 2 — Load the document

```swift
// From text you already hold (paste box, keychain, app-group file):
let config = try engine.configuration(.json(savedText))

// From disk — the file is read and capped at the engine's 16 MiB limit:
let fromDisk = try engine.configuration(.json(try String(contentsOf: url)))

// Rename servers without touching anything else: remarks are cosmetic.
var renamed = config
renamed.remarks = "Tehran-03"
```

`configuration(.json(_))` stores text untouched. It parses nothing and
launches nothing — that is what the next step is for.

## Step 3 — Validate before launching

```swift
// Full engine check. Needs the engine STOPPED; throws the engine's own
// parser complaint, which is the cheapest way to reject bad user input.
try config.validate()

// Structural check with no engine involved: section names, outbound
// references, tag/protocol presence. Use while connected.
try config.validateOffline()
```

## Step 4 — Launch

```swift
// The document, exactly as given:
try session.start(config)

// Equivalent shortcuts — same pipeline, less ceremony:
try session.start(.json(savedText))          // source form
try session.start(rawJSON: savedText)        // text form
try session.start(contentsOf: url)           // file form (16 MiB cap)

// With launch knobs: env travels into the engine's process (geo dir here),
// metricsPort opens the local stats endpoint counters read later.
try session.start(
    config,
    options: engine.options(
        environment: ["xray.location.asset": geoDir.path],
        metricsPort: 24242
    )
)
```

Async and bounded variants exist for UI and provider code — see
`04-health-and-status.md` and `Examples/07-network-extension.md`. Never
call the sync forms on the main thread; the bridge call blocks until the
engine answers.

## Step 5 — Stop

```swift
try session.stop()              // safe when idle; clears the instance
session.connectedSince          // nil again — your "disconnected" label
```

`stop()` keeps the last run's engine log tail on disk for the "why did it
drop" screen — see `05-logging.md`. Starting again replaces; there is no
second instance to clean up.

## Rules that throw

- Not JSON / engine rejects the schema → the parser's message, verbatim.
- Over 16 MiB → `.invalidInput` naming the cap, before crossing the bridge.
- `geosite:`/`geoip:` references with missing or corrupt `.dat` files →
  `.geoAssets` naming the file. Plain domains and IPs never trigger this.
