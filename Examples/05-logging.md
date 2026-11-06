# 05 — Logging: writing the log and reading it back

Two independent streams: your sink (every line, live) and the engine's
log files (persisted, tailed later). Set up both; they answer different
questions.

## Step 1 — The live sink

```swift
// Passed once, called per line on the caller's thread: keep it cheap
// and thread-safe. Optional — without it, lines go to the ring buffer
// only (Step 3 still works for recent history).
let session = engine.newSession { line in
    print("[xray]", line)
}
```

For a file-backed sink, append under your own serial queue — never block
the caller:

```swift
let logQueue = DispatchQueue(label: "xray.log")
let session = engine.newSession { line in
    logQueue.async { logHandle.write((line + "\n").data(using: .utf8)!) }
}
```

## Step 2 — The engine's log files

The sink is live-only; persistence is the `log` section's job. Point it
at files in the assembly (or `options`) and the engine writes there:

```swift
var a = engine.assembler(.shareLinks(feed))
// .warning keeps the files small; .debug is for chasing one bug, then off.
a.log = engine.log(
    level: .warning,          // XrayLogLevel: .debug .info .warning .error .none
    access: accessFile.path, // connection log — large; omit unless debugging
    error: errorFile.path     // error log — the one forensics reads
)
```

Levels are engine verbosity, not routing: `.none` writes nothing,
`.error` only failures. Access logs grow fast — ship `.warning` +
error-file by default, escalate per session when a user reports a drop.

## Step 3 — Reading back

```swift
// The ring: last 200 lifecycle notes (launches, stops, gates), no files
// involved, works in any state. Your "events" tab.
session.recentLogs()

// The engine's own files, tailed from disk. Throws .invalidInput naming
// the file when the running document never set that path — the common
// cause is launching raw JSON with no "log" section.
let errors = try session.recentEngineLogs(.error, lines: 100)   // default kind
let access = try session.recentEngineLogs(.access, lines: 50)
```

Behavior that surprises once:

- `stop()` does NOT clear the recorded paths — the tail survives for the
  post-mortem screen. The next `start` overwrites them with its own
  document's paths.
- Every launch path records: assembly, raw JSON (parsed best-effort for
  the log section), remote subscription. No path is silently skipped.
- Tails are capped (256 KiB from the end) so a gigabyte access log
  cannot blow up the reader.

## Step 4 — The disconnect report

```swift
func disconnectReport() -> String {
    var lines = ["state: \(session.connectedSince == nil ? "down" : "up")"]
    lines += session.recentLogs().suffix(20)
    lines += (try? session.recentEngineLogs(.error, lines: 40)) ?? ["no engine log"]
    return lines.joined(separator: "\n")
}
```

Attach this to the feedback email / crash report. It is usually enough
to distinguish server-dead, network-dead, and app-killed without asking
the user anything.
