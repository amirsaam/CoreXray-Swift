# Contributing to CoreXray-Swift

This file is for maintainers and contributors. If you just use the package,
you never need anything in here — see `README.md` and `Examples/`.

## Ground rules

- CI must be green: `swift build` with zero warnings plus the full `swift test`
  suite, on every push and PR, plus the iOS Simulator availability build.
- Clean-break versioning: no `@available` shims, no deprecated aliases. A
  rename removes the old name; consumers pin with `.upToNextMinor` so Swift
  patches flow without surprises.
- The typed API covers daily VPN-app needs; everything else goes through raw
  JSON (`configuration(.json(...))`, `transform`, `patch`), which never needs
  updating when upstream adds fields.

## Versioning and core updates

How a new core reaches consumers:

1. A nightly check compares the core pinned in `Package.swift` with
   XTLS/libXray's latest release. When upstream moved, it opens a PR from a
   `core/v<version>` branch that changes exactly two manifest lines (url +
   checksum) and pastes upstream's release notes into the PR body — libXray
   itself ships no notes, so they come from the matching Xray-core release,
   stripped of sponsor/donation boilerplate, auto-translated to English with
   the original collapsed below (translation is best-effort; if it fails the
   original goes in with a notice). Those notes are what tells you whether
   the Swift layer needs changes.
2. CI builds and tests the PR like any other, including the tripwire
   asserting the engine still answers our `apiVersion: 3` envelope.
3. If the Swift layer needs changes, commit them onto the branch; if not,
   merge as-is.
4. Merging changes nothing for consumers. No tag, no release, no automation
   past the merge — a PR is a pin update, never a release.

Cutting a release (maintainer): pick the numbers — the epoch from the pinned
core (`26.11.9` → `261109`), the Swift major/minor unchanged unless the
Swift code changed since the last tag — then push the tag:

```bash
git tag 261109.1.1
git push origin 261109.1.1
```

The push drafts the release for you (`Draft release notes` workflow): a
**draft** named `v261109.1.1` in the house format — bold title, Core/Swift
lines, `NEW` / `CHANGES` / `FIXES` pre-filled with the "contains no …"
lines, and a Full Changelog compare link. Fill the three sections, then
publish the draft by hand. The workflow never publishes anything itself;
if the release already exists it does nothing, so re-pushing a tag is
safe.

Tag pushes run the CI suite on the tag, so a red commit is still caught —
delete the tag and release if that happens and re-cut. The release name
keeps the `v` prefix (`v261031.1.0`); the tag itself is bare.

A Swift-only release (same core) skips the PR flow entirely: push the Swift
changes, then tag `<same-epoch>.<major>.<minor+1>` — or `<major+1>.0` for a
breaking reshape. Yes, it really is that simple: the PR moves the pin, the
tag freezes it, the release names it. Three separate human-visible steps,
nothing hidden.

You can also trigger the check from the Actions tab with workflow_dispatch
if you want the newest engine before the next midnight.

## How the layout works

```
Package.swift                the only per-release change: binary target URL and checksum
Sources/CoreXray/             typed API over the C bridge
  Xray.swift                 entry only: the shared instance
  Kit/                       human-facing API, extensions of Xray, one type per file
    Lifecycle.swift          version, isRunning, health, launch, stop, sendRawRequest
    Ports.swift              findAvailablePorts, verifyAvailablePorts
    Ping.swift               ping, XrayPingTarget/XrayPingResult/XrayPingOptions
    Config.swift             XrayConfig, XrayConfigSource, conversion, validation
    Session.swift            XraySession lifecycle, XraySessionOptions, deadline start,
                             remote subscription start, provider preflight,
                             XrayCredentials, XraySniffing, flight recorder,
                             connectedSince, engine log tailing
    SessionProviding.swift   XraySessionProviding protocol for mocks
    Tun.swift                XrayTunEntry: real tun inbound, fd hand-off,
                             providerFileDescriptor
    Assembly.swift           XrayAssemblySource, XrayAssembly: intent in, document out
    Routing.swift            XrayRouting section, rules, destinations
    DNS.swift                XrayDNS section, servers, XrayFakeDNS pools
    Log.swift                XrayLog section, levels
    JSON.swift               XrayJSONValue tree, literals, subscripts
    Traffic.swift            XrayMetrics and XrayObservatory sections, snapshots, deltas,
                             monitor, stall watchdog, probe decoding
    Keys.swift               XrayAgeKeyPair generation
    Geo.swift                geo asset gate, inventories, XrayGeoDownloader,
                             ensureAssets upkeep
    Errors.swift             XrayError
    Factories.swift          newSession, configuration, validate, assembler,
                             proxyConfiguration, shared port validation
  Calls/                     internal engine plumbing, one class per file
    EngineTransport.swift    serial lane, request guard, envelopes — the only
                             file that touches the C bridge
    LifecycleCalls.swift     version/state/launch/stop/raw wire calls
    PortCalls.swift          spare-port query plus the TCP bind check
    PingCalls.swift          ping measurement encoding
    ConfigCalls.swift        link conversion, validation, subscription unwrap
    KeyCalls.swift           age key generation
    GeoCalls.swift           geo inventory encoding
Tests/CoreXrayTests/          engine, session, and downloader tests (HTTPStub
                             keeps downloads and feeds hermetic: no packets)
scripts/update_package.py    manifest rewriter used by the core-check workflow
scripts/pr_notes.py         PR-body builder: strips upstream boilerplate, English translation
.github/workflows/core-update.yml    nightly upstream check; opens core-update PRs, never releases
```
