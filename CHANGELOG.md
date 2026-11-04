# Changelog

The package follows clean-break versioning: no deprecation shims, no
`@available` aliases. Removed or renamed APIs disappear and consumers
recompile against the new shape. Pin releases with `.upToNextMinor` (see README).

Newest first. This log starts with the current batch; earlier history is the
git log and the `<date>` release tags (bare version; the release itself is named `v<date>`).

## Unreleased

### Added
- `Session.recentLogs(limit:)` — the last 200 lifecycle notes, lock-guarded.
- `Session.connectedSince` — stamped on every successful launch path,
  cleared on `stop()`. The uptime anchor; pair with traffic totals.
- `Session.recentEngineLogs(_:lines:)` + `Session.EngineLogKind`
  (`.access` / `.error`) — tails the engine's own log files named by the
  last built document. Throws `.invalidInput` naming the missing file.
- `Session.preflightForProvider(_:options:)` — throws one `.invalidInput`
  listing every provider problem (non-loopback inbound, missing tun).
- `Session.preflightIssues(_:options:)` — same check as values, for UI.
- `Session.start(remoteSubscription:ageSecret:assetDirectory:options:deadline:timeoutSeconds:)` —
  fetch, unwrap, top-up geo assets, deadline launch in one call. Feeds are
  capped at the engine's 16 MiB request limit.
- `Xray.XraySessionProviding` — the mockable session protocol; `Session`
  conforms, `newSession()` still returns the concrete type.
- `TrafficWatchdog` + `engine.trafficWatchdog(port:interval:stalledAfter:onStall:)` —
  fires once per stall episode, resets on any movement. Failed snapshots
  count as stalls, so a dead metrics endpoint fires too.
- `Xray.providerFileDescriptor(from:)` — reads the utun fd off a packet
  flow without spelling the KVC path by hand.
- `Session.start(_:options:deadline:)` — async deadline variant.
- `Xray.health()` — `isRunning` plus a bridge round-trip.

### Changed
- Versioning is now `Epoch.Major.Minor`: the epoch is the pinned
  XTLS/libXray release with dots removed (`v26.10.31` → `261031`), the
  trailing pair fingerprints the Swift code only and carries over unchanged
  across core bumps. Pin consumers with `.upToNextMinor`. Old date-based
  tags were removed; those pins no longer resolve.
- Core updates arrive as PRs, not releases: the nightly check opens a
  `core/v<version>` PR carrying upstream's release notes, CI tests it,
  merging only moves the pin. Releases are cut by hand as
  `<epoch>.<swift-major>.<swift-minor>` tags (see README "Versioning and
  core updates").
- `Session` is `@unchecked Sendable`: safe to hold across `Task`
  boundaries, internal state behind a lock, bridge calls on the serial
  lane. Keep each session on one serial context anyway — `logger` runs on
  the caller's thread.
- `Assembly` is no longer `Sendable`: its `patch` closure runs exactly
  once on the assembling thread, so conforming only taxed user code.
- Feed `timeoutSeconds` defaults to 30s and is configurable.
- `Sources/LibXraySwift` is now `Sources/CoreXray` (module `CoreXray`
  throughout). Update target references, not imports.

### Fixed
- Raw and file launches record the document's log paths, so
  `recentEngineLogs` works for every launch path, not just built ones.
- Doc examples that constructed value types directly now use factories.
