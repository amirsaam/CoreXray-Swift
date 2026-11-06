# CoreXray-Swift

libXray as a Swift Package: `Package.swift` points directly at the
`libxray-apple-cgo.zip` asset of every [XTLS/libXray release](https://github.com/XTLS/libXray/releases),
and the raw C bridge hiding in its `LibXray.xcframework` is covered by a small
typed Swift API.

libXray is a wrapper XTLS builds for embedding Xray-core into iOS, macOS, and
tvOS clients. That is exactly what this package gives you, in two layers:

- A binary target whose URL and SHA-256 checksum name one XTLS release,
  moved forward by maintainer-merged core-update PRs. SwiftPM downloads the zip per version, verifies
  the hash, unpacks `LibXray.xcframework`, and caches it, so this repository
  itself stores no binaries.
- `CoreXray`, a Swift module over the engine's single JSON entry point.
  `XrayAssembly` turns intent into a launchable document, `XraySession`
  owns launch lifecycles, `XrayConfig` is the configuration value, and
  `Xray` answers one-shot questions.

- [Requirements](#requirements)
- [Installation](#installation)
- [Importing](#importing)
- [The engine in ninety seconds](#the-engine-in-ninety-seconds)
- [Concepts](#concepts)
- [API reference](#api-reference)
  - [`XrayAssembly`: one value in, one document out](#xrayassembly-one-value-in-one-document-out)
  - [`XrayConfig`: the document as a value](#xrayconfig-the-document-as-a-value)
  - [`XraySession`: build, tweak, then launch](#xraysession-build-tweak-then-launch)
  - [`XrayRouting`: where traffic goes](#xrayrouting-where-traffic-goes)
  - [`XrayDNS`, `XrayFakeDNS`, `XrayLog`: verbatim sections](#xraydns-xrayfakedns-xraylog-verbatim-sections)
  - [Proxy mode vs TUN mode](#proxy-mode-vs-tun-mode)
  - [One-shot questions on `Xray`](#one-shot-questions-on-xray)
  - [Value factories on `Xray.shared`](#value-factories-on-xrayshared)
  - [`Xray.shared.ping`: latency through the real path](#xraysharedping-latency-through-the-real-path)
  - [`XrayTrafficMonitor`: live speed and totals](#xraytrafficmonitor-live-speed-and-totals)
  - [Geo databases](#geo-databases)
  - [Subscriptions: fetch, unwrap, parse](#subscriptions-fetch-unwrap-parse)
  - [`XrayError`: five cases](#xrayerror-five-cases)
  - [The typed tree: `XrayJSONValue`](#the-typed-tree-xrayjsonvalue)
  - [Raw bridge](#raw-bridge)
- [Versioning and core updates](#versioning-and-core-updates)
- [Choosing a server: ping, then connect](#choosing-a-server-ping-then-connect)
- [iOS tunnel provider: the whole start path](#ios-tunnel-provider-the-whole-start-path)
- [Testing your app: mock the session](#testing-your-app-mock-the-session)
- [Troubleshooting](#troubleshooting)
- [Staying connected: the rebuild recipe](#staying-connected-the-rebuild-recipe)
- [How the layout works](#how-the-layout-works)
- [Credits](#credits)
- [Examples: step-by-step guides](#examples-step-by-step-guides)

## Requirements

macOS 13+, iOS 15+, tvOS 17+, Swift 5.9 / Xcode 15+. The framework carries no
watchOS or visionOS slices because XTLS does not build those, so the package
declares no support for them either. Since the framework is static, linking
needs `Security.framework` and `libresolv`; the package wires both through its
own target settings, so nothing is required of your app target. On the first
resolve of a version SwiftPM fetches the ~100 MB zip from XTLS, checks the
checksum, and unpacks it; later builds on the same machine reuse the cached
framework without another download.

## Installation

Xcode: File > Add Package Dependencies, and enter

```
https://github.com/amirsaam/CoreXray-Swift.git
```

In `Package.swift`:

```swift
.package(
    url: "https://github.com/amirsaam/CoreXray-Swift.git",
    .upToNextMinor(from: "261031.1.0")
)
```

Pick Up To Next Minor Version in Xcode's requirement dropdown (or write
`.upToNextMinor` yourself as above). Versions here are `Epoch.Major.Minor`:

- **Epoch** is the XTLS/libXray release the framework came from, dots
  removed: upstream `v26.10.31` is epoch `261031` (each group padded to two
  digits, so `26.9.5` would be `260905` and epochs stay chronologically
  sortable).
- **Major** is our own package major: a breaking Swift API reshape.
- **Minor** is our own package minor: everything else — additions and fixes.

So `261031.1.0` means core 26.10.31 with Swift code 1.0. The trailing pair
is a fingerprint of the Swift code only: if the core moves but the Swift
layer is untouched, the numbers carry over — `26115.1.0` following
`261031.1.0` tells you the Swift code is unchanged. A Swift change on the
same core bumps the tail instead: `261031.1.0` → `261031.1.1`.

`.upToNextMinor(from: "261031.1.0")` allows `>=261031.1.0, <261031.2.0`, so
Swift fixes on your core arrive on the next resolve, while a Swift major
(`261031.2.0`) or a new core epoch (a new, much larger major number) never
sneaks in — both stay a deliberate decision you make by changing the string.
`.exact` is the stricter alternative if you want nothing to move without an
edit.

Each version is one ~100 MB download on first use: SwiftPM fetches the zip
from XTLS, checks the checksum, and unpacks it; later builds reuse the
cached framework. Resolving at, say, `261031.1.0` embeds exactly the engine
that tag's `Package.swift` names. Nothing binary is committed here.

Tags under the previous date-based scheme (`26.10.31`, `v26.10.31`) were
removed and no longer resolve — move to a current `Epoch.Major.Minor`
version.

## Importing

```swift
import CoreXray
```

The import exposes everything: the `Xray` namespace, `XraySession`,
`XrayConfig`, the support types, and the underlying C functions `CGoInvoke` /
`CGoFree` for when a change has not reached this wrapper yet.

## The engine in ninety seconds

Xray-core runs in-process. You give it a complete JSON configuration, it
launches listeners and outbounds inside your app, and it keeps running until
you stop it or replace it. Everything else is helper work on top: turning
subscription texts or share links into that JSON, validating configs, probing
servers, and picking free ports. The engine keeps no session history you can
read back; your app owns the lifecycle.

```swift
import CoreXray

// 1. Hold a session for as long as its engine should live
let session = Xray.shared.newSession { print("[xray]", $0) }

// 2. Describe what you want; get a working document back
let config = try Xray.shared.proxyConfiguration(
    .shareLinks(pastedText),
    routing: Xray.shared.routing(
        rules: [Xray.shared.routingRule(domains: ["malware.example.com"],
                                        destination: .block)],
        final: .proxy
    ),
    log: Xray.shared.log(level: .warning)
)

// 3. Launch it, and stop it later
try session.start(config)
try session.stop()
```

## Concepts

Six facts explain nearly every behavior below. Read once; everything else
is commentary.

1. **The engine is process-global and singular.** Xray-core runs in-process
   and there is exactly one of it per process: one running configuration at
   a time, no handles, no second instance to compare against. `launch`
   replaces, `stop` clears, `isRunning` reports the engine's own state.
   Your app holds the lifecycle exclusively through one `XraySession`.
2. **The bridge is one serial lane.** Every call crosses a single serialized
   transport into the Go runtime. Calls never interleave, which is why
   concurrent `start`/`stop` from two threads is a logic race this package
   does not referee: keep each session on one serial context. The lane is
   also why a wedged engine call cannot be cancelled from Swift — bounds
   (`deadline:`, `health()`'s ~5s cap) abandon the wait, never the call.
3. **Configuration is a JSON document; the package is a typed funnel into
   it.** The engine accepts exactly one thing: a complete JSON config. Every
   factory, assembly, and option exists to build that document without
   spelling JSON by hand — and `transform`/`patch` exist for the keys the
   funnel does not know. When in doubt, `build()` and read `config.json`:
   the document is always inspectable.
4. **Environment travels in the document.** The engine applies the
   document's `env` map into its own process environment at launch. That is
   the documented carrier for `xray.location.asset` (geo directory),
   `xray.tun.fd` (TUN descriptor), and similar engine settings — and it is
   why launching a descriptor-less TUN document clears stale `xray.tun.fd`
   from the process: the engine never unsets what a previous launch set.
5. **Geo data is lazy and external.** The engine resolves `geosite:` /
   `geoip:` at traffic time from `.dat` files it finds via `env`, and
   complains about nothing until then. The package's gate exists because the
   engine's silence would otherwise surface as dead routing: references are
   checked at build, databases are fetched by `ensureAssets`, and plain
   domains/IPs never need any of it.
6. **16 MiB is the engine's own ceiling.** Requests over 16 MiB are rejected
   before crossing the bridge — feeds, raw requests, everything. A
   well-formed giant request fails exactly as it would remotely, without
   paying for the round trip.

## API reference

Everything below is reachable after `import CoreXray`. Values are built through
factories on `Xray.shared` — value inits are internal, so user code passes
values to functions and never spells a type name to construct one. Blocking
calls expect a
background task from UI code (or use the async variants). Failures surface as
`XrayError` with five cases (`.engineFailed`, `.bridgeFailed`,
`.invalidInput`, `.geoAssets`, `.timedOut`), catchable like any Swift error.

### `XrayAssembly`: one value in, one document out

`XrayAssembly` is the easy path and the one most apps should use. You
describe intent — where the proxy comes from, which entries to open, where
traffic goes — and `assemble()` returns a launchable `XrayConfig`. No tag
bookkeeping, no merge closures. Every field is optional except `source`:

```swift
// One call, no structs: conversion plus entries and sections.
try Xray.shared.proxyConfiguration(
    .shareLinks(text),   // or .outboundJson(singleOutbound); full docs go to configuration(.json)
    remarks: "main",     // label stored in the document; nil omits it
    socksPort: 10808,    // socks entry on 127.0.0.1; nil drops it
    httpPort: nil,       // set to add an HTTP entry on 127.0.0.1
    routing: nil,        // the routing section; nil leaves conversion output alone
    dns: nil,            // verbatim dns section; nil leaves it out
    log: nil             // verbatim log section; nil leaves it out
)

// Full control: tune the assembly, then assemble it.
var assembly = Xray.shared.assembler(.shareLinks(text))
assembly.socks = try Xray.shared.socksEntry(port: 10880)
assembly.routing = Xray.shared.routing(rules: [...])
assembly.metricsPort = 24242          // adds XrayMetrics listener + stats + policy
assembly.observatory = try Xray.shared.observatory(subjectSelector: ["proxy"])
assembly.tun = try Xray.shared.tun(name: "utun7", fileDescriptor: fd)
assembly.patch = { $0["log"] = ["loglevel": "warning"] }  // runs last
let config = try assembly.assemble()
```

How it works, in order: `source` converts (share links become outbounds;
a single outbound object is wrapped as the outbounds; the first outbound
is the `.proxy` destination everywhere else), verbatim
sections (`dns`, `fakeDNS`, `log`, `routing`, `observatory` when set, metrics
when `metricsPort` is set) are written, the
tun inbound is appended when `tun` is set (with `xray.tun.fd` merged into
`env` when it carries a descriptor), entries are appended, standards
(`.direct` / `.block` /
`.dns`) are appended when routing references them but the document lacks them,
and `patch` runs last. Then the geo asset check runs (see
[Geo databases](#geo-databases)): routing or dns references like
`geosite:category-ads` fail assembly with `.geoAssets` when the database is
missing or unreadable.

Three promises hold for every assembly:

- The source is always a server description, never a finished document.
  `.shareLinks` converts links into outbounds; `.outboundJson` wraps one
  outbound object as the outbounds. A full document has no case here at
  all — it goes through `Xray.shared.configuration(.json(...))` or
  straight to a session instead of being assembled around.
- The assembled document keeps the converted proxy tag (typically the link's
  `#fragment`), appends anything it derived, and never deletes what
  conversion produced — a whole `outbounds` key in `patch` would be the one
  way to lose the real server, so don't put one there.
- Destinations are logical, not tags: `.proxy` resolves to the converted
  outbound's real tag (assigned `"proxy"` if it had none), `.direct` /
  `.block` / `.dnsOut` resolve to standard outbounds added automatically when
  referenced but missing, and `.custom("tag")` passes a tag through verbatim
  for outbounds you provide yourself. Sending traffic to `.proxy` when the
  document has no outbounds is an `.invalidInput` error.

Entries are the mode. `socks` (default `127.0.0.1:10808`, tagged `socks-in`),
`http` (default nil: `127.0.0.1:10809`, tagged `http-in`), and `dnsRelay`
(default: a `dokodemo-door` on `127.0.0.1:10810` relaying to `1.1.1.1:53`
over UDP, feeding the `dns-out` outbound) open the local entry points; set
any to nil to drop it. Proxy mode is entries on the loopback interface; TUN
mode is setting `tun` to an `XrayTunEntry`, which appends a real `tun`
inbound (tagged `"tunIn"` by default) that captures device-wide — both can
coexist. Each entry carries its own `auth` (`XrayCredentials`, nil means
open); the low-level `XraySessionOptions.credentials` still exists for hand-built
sessions, guarding every SOCKS inbound at once and leaving the tun inbound
alone (tun takes no auth: packets, not connections).

Entry details:

- `socksEntry(tag:listen:port:udp:auth:sniffing)` — defaults
  `"socks-in"`, `"127.0.0.1"`, `10808`, `true`, nil, and nil sniffing (the
  entry inherits the assembly's through the pipeline; pass an explicit
  value to keep your own). Open entries write `auth: "noauth"`; guarded
  ones write `auth: "password"` with the pair in `users`.
- `httpEntry(tag:listen:port:auth:sniffing)` — defaults `"http-in"`,
  `"127.0.0.1"`, `10809`, nil, and nil sniffing (same inheritance as the
  SOCKS entry). Open entries carry
  no `settings` key at all; guarded ones write the pair in `accounts` (the
  HTTP inbound has no `auth` field in the engine schema).
- `dnsRelay(tag:listen:port:address:remotePort:network:)` — defaults
  `"dns-in"`, `"127.0.0.1"`, `10810`, `"1.1.1.1"`, `53`, `"udp"`. It has no
  sniffing of its own; the assembly's `sniffing` covers it like any inbound
  without settings.

### `XrayConfig`: the document as a value

```swift
public struct XrayConfig {   // inits are internal; build one via Xray.shared.configuration
    public var json: String
    public func shareLinks() throws -> String
    public func validate() throws
    public func validateOffline() throws
}
public enum XrayConfigSource { case json(String); case shareLinks(String) }
public enum XrayAssemblySource { case shareLinks(String); case outboundJson(String) }
```

`XrayConfigSource` is what a session starts from: full JSON text or share
links. `XrayAssemblySource` is what an assembly builds from: share links or
one outbound object — never a full document, which goes through
`configuration(.json(...))` instead. (`decodeSubscription` and
`generateAgeKeyPair` live on the shared instance: `Xray.shared`.)

- `configuration(.json(_))` stores text untouched. No validation happens here; that is
  `validate()`'s job.
- `configuration(.shareLinks(_):ageSecret:)` accepts `vless://`,
  `trojan://`, `ss://`, and `socks://` links — one link,
  newline-separated mixed feeds, or a base64 blob of those. Verified
  against the bundled engine: `vmess://`, `hysteria2://`, `wireguard://`,
  and `{"outbounds":[...]}` JSON blobs are dropped by its converter, so a
  feed of only those throws `XrayError` ("no valid outbound found").
  Entries the engine cannot build are dropped instead of failing the call;
  if nothing survives, it throws. When the feed exports Age-encrypted
  content, pass the `AGE-SECRET-KEY-...` string as `ageSecret`.
- `shareLinks()` goes back: one routable outbound, one share link,
  newline-separated. A document with no routable outbounds yields an empty
  string rather than an error.
- `validate()` checks a configuration without starting anything; the thrown
  error carries the engine's parser complaint, which is the cheapest way to
  reject bad user input. It needs the engine stopped — while running, use
  `validateOffline()`, which checks section names, outbound references, and
  tag/protocol presence without touching the engine.
- `decodeSubscription` (on `Xray.shared`) unwraps a provider's Age-encrypted
  subscription export: text starting with the Age armor header is decrypted
  with `ageSecret`, and *any other text comes back unchanged*. It does not
  parse links and does not base64-decode — a link list or a base64 blob goes
  to `configuration(.shareLinks:ageSecret:)`, which handles both. (JSON
  blobs are not accepted there either; the bundled converter drops them.)

`json` is plain text you can persist, log, or edit between calls. Note the
engine's answer for share-link input keeps only projected, buildable
outbounds, so what you get back is already pruned to what this build can run.

### `XraySession`: build, tweak, then launch

`XraySession` is the layer a VPN app holds onto. It owns the launch
lifecycle with an optional log sink, and its `build` is the low-level path
underneath assemblies: same pipeline, knob by knob, with `transform` running
last for full control. Reach for it when an assembly hides something you need
to do by hand. One session per engine — starting again replaces the running
instance.

Concurrency: `XraySession` is `@unchecked Sendable` — safe to hold across `Task`
boundaries, with internal state behind a lock and bridge calls serialized on
the transport lane. Keep each session on one serial context anyway:
`logger` runs on the caller's thread, and interleaving two sessions'
start/stop sequences is a logic race no lock referees. `XrayAssembly` is
deliberately not `Sendable`: its `patch` closure runs exactly once on the
assembling thread, so conforming would only force `@Sendable` on user code
for zero gain.

Values are built the same way, through factories on the shared instance:

```swift
let session = Xray.shared.newSession { print("[xray]", $0) }
let config = try Xray.shared.configuration(.shareLinks(pastedText))
try Xray.shared.validate(.shareLinks(pastedText))
let assembly = Xray.shared.assembler(.shareLinks(pastedText))

// One call, no structs: converted document with a socks inbound on 10808.
let proxy = try Xray.shared.proxyConfiguration(
    .shareLinks(pastedText),
    socksPort: 10880,
    routing: Xray.shared.routing(rules: [Xray.shared.routingRule(domains: ["geosite:category-ads-all"], destination: .block)])
)
try session.start(proxy)
```

```swift
let session = Xray.shared.newSession { print("[xray]", $0) }

// Inspect before committing: builds JSON, applies the pipeline, starts nothing.
let config = try session.build(
    .shareLinks(pastedText),
    options: Xray.shared.options(
        sniffing: Xray.shared.sniffing(),
        transform: { $0["log"] = ["loglevel": "warning"] }
    )
)

// Launch from a source, an assembled config, raw JSON you control end to
// end, or a config file on disk.
try session.start(.json(savedJSON))
try session.start(config)
try session.start(rawJSON: savedJSON)
try session.start(contentsOf: configFileURL)

// Async variants free the caller while the engine blocks.
try await session.start(.shareLinks(pastedText))
try await session.validate(.json(savedJSON))

// Deadline variant for providers: the system kills a start that overstays
// its time budget, so give up first — a timed-out start stops what it began
// (stop-if-current: a newer launch is never killed) before throwing
// `.timedOut`, which the provider can catch and retry. If the engine never
// answers at all the throw still arrives on time, and the orphan self-stops
// when (if) it ever finishes. Providers must use this (or the plain async
// variant): the sync starts cannot be bounded.
try await session.start(.shareLinks(pastedText), deadline: .seconds(20))

// One call for the whole provider start: fetch, unwrap, top up geo assets,
// launch under a deadline. The feed is fetched fresh every call — nothing
// cached, nothing auto-refreshed. Feeds are capped at the engine's own
// 16 MiB request limit (`timeoutSeconds`, 30 by default, bounds the wait);
// anything past the cap throws before decoding. assetDirectory becomes
// xray.location.asset unless the options already set it.
try await session.start(
    remoteSubscription: feedURL,
    assetDirectory: dataDir,
    options: Xray.shared.options(tun: tun, metricsPort: verifiedPort)
)

// Provider sanity before launch: loopback-only inbounds with an explicit
// listen address, plus a tun inbound that carries its file descriptor.
try session.preflightForProvider(.shareLinks(pastedText), options: opts)

// Same check as values, for UI: [] means provider-ready, anything else
// renders next to its fix instead of parsing an error string.
let issues = try session.preflightIssues(.shareLinks(pastedText), options: opts)

try session.stop()
try session.isRunning() -> Bool
```

`XrayConfigSource` is `.json(String)` or `.shareLinks(String)`; share links
are converted through the engine first, then everything flows through the
same pipeline: environment, tun, observatory, sniffing, dns, fakedns, log,
metrics, routing, a `dns-in → dns-out` route when a `dokodemo-door` relay
inbound meets a `dns` section, credentials, then `transform` last, then the
standard outbounds, then the geo asset check.

`XraySessionOptions` fields and defaults: `sniffing` (nil), `transform` (nil),
`routing` (nil — replaces any routing section already in the document),
`credentials` (nil — when set, guards every SOCKS inbound and rejects a
document with none as misconfiguration; the tun inbound is untouched),
`tun` (nil — set to an `XrayTunEntry` for device-wide capture),
`environment` (nil — entries merged into the document's `env`, the section
the engine turns into its own process environment at launch: use it for
`xray.location.asset` and friends; keys already in the document win),
`observatory` (nil — see `XrayObservatory` under traffic; setting it
without `metricsPort` throws `.invalidInput` at build, because the probe
answers are published on the metrics endpoint and would otherwise read
empty forever),
`geoCheck` (true — refuse to assemble a document whose routing or dns
references `geosite:` / `geoip:` categories the engine has no readable
database for), `dns` (nil — replaces any dns section), `fakeDNS` (nil —
replaces any fakedns section), `log` (nil — replaces any log section).

Notes on the pieces:

- `XraySniffing` merges a `sniffing` object into every inbound that does not
  already define one. Fields: `destOverride` (default
  `["http", "tls", "quic", "fakedns"]`), `enabled` (default true),
  `routeOnly` (default false), `domainsExcluded` (default empty),
  `metadataOnly` (default false). Inbounds with their own settings keep them.
- `transform` mutates the parsed configuration in place and runs last, so it
  overrules everything, including sniffing and routing. It works on a typed
  tree (`XrayJSONObject`, values are `XrayJSONValue`), so there is nothing
  to cast: literals build documents, subscripts and dynamic members read them.
  ```swift
  var doc: XrayJSONValue = ["log": ["loglevel": "warning"]]
  doc["log"]?["loglevel"] = "error"
  doc.log?.loglevel?.stringValue // "error"
  ```
- `logger` gets lifecycle notes (what is launching, byte counts of the final
  JSON). Set it at init or any time after. Every note also lands in the
  `recentLogs()` ring buffer (last 200, oldest first) — the flight recorder
  for the package side.
- `connectedSince` stamps when the running instance came up (nil before the
  first start, nil after every stop). Pair it with traffic totals, which
  reset on every launch, for uptime math.
- `recentEngineLogs(_ kind: XrayEngineLogKind, lines:)` tails the engine's own
  log file (`.access` / `.error`) named by the last launched document's log
  section. Paths are adopted only on a successful launch, so the tail
  follows the run that actually launched — and the engine must be pointed
  at files first
  (`log(access: path, error: path)`); anything else throws `.invalidInput`
  naming the fix. At most the trailing 256 KiB are read.
- `XraySessionProviding` is the session's protocol surface for apps
  that inject a mock in their own tests; `newSession()` returns the real
  thing.

`Xray.shared.launch(_:)` / `Xray.shared.stop()` are the underlying primitives the session
delegates to; prefer the session unless you are sure you want the bare calls.

### `XrayRouting`: where traffic goes

`routing` is the routing section itself. XrayRoutingRule order and strategy are exactly
what you declare. Any routing section already in the document is replaced;
use `transform` to merge with existing rules.

```swift
Xray.shared.routing(
    domainStrategy: .ipIfNonMatch,  // or .asIs / .ipOnDemand; nil omits it (XrayRoutingDomainStrategy)
    rules: [
        Xray.shared.routingRule(domains: ["geosite:ads", "full:tracker.example.com"],
                                destination: .proxy),
        Xray.shared.routingRule(ips: ["geoip:private", "192.168.0.0/16"],
                                destination: .direct),
        Xray.shared.routingRule(inboundTags: ["dns-in"], destination: .dns),
    ],
    final: .proxy  // catches whatever no rule matched; nil omits it.
    // The engine has no `final` field, so it is written as a trailing
    // `network: "tcp,udp"` rule — every connection the engine routes is
    // TCP or UDP. (A truly condition-less rule is rejected by the engine
    // as having no effective fields, hence the network condition.)
)
```

`XrayRoutingRule` fields (all default to empty/nil; only what you set is written):
`domains` (plain `example.com`, `full:`, `domain:`, `regexp:`, `geosite:`),
`ips` (CIDR, `geoip:`), `port` (`"443"`, `"80,443"`), `network` (`"tcp"`,
`"udp"`), `protocols` (sniffed: `http`, `tls`, `bittorrent`),
`inboundTags`, and `destination`. Fields within a rule combine with AND,
rules combine with OR. Every rule should carry a destination; rules without
one write no `outboundTag` and match nothing useful. A rule with neither
conditions nor a destination is rejected at build (`.invalidInput`) —
the engine refuses empty rules, so the assembly fails fast instead.

`geosite:` / `geoip:` categories need the corresponding `.dat` files where
the engine will look for its assets — and the assembly enforces that before
anything launches (see [Geo databases](#geo-databases)). Turning a plain
domain or IP list into a database lookup is the only thing that requires
them; everything else routes without any database.

### `XrayDNS`, `XrayFakeDNS`, `XrayLog`: verbatim sections

`dns`, `fakeDNS`, and `log` are verbatim like `routing`: what you declare is
what lands, replacing anything already in the document. Empty collections and
nil fields are omitted from the wire rather than written empty.

```swift
Xray.shared.dns(
    hosts: ["geosite:malware": "127.0.0.1"],  // default empty
    queryStrategy: .useIPv4,                  // or .useIP / .useIPv6; nil omits it (XrayDNSQueryStrategy)
    servers: [                                // default empty
        .detailed(address: "fakedns", domains: ["geosite:category-ir"]),
        .plain("https://dns.google/dns-query"),
    ]
)
Xray.shared.fakeDNS(ipPool: "198.18.0.0/16", poolSize: 512)  // one array entry; both required
Xray.shared.log(
    level: .warning,     // or .debug / .info / .error / .none; nil omits it
    access: "/path/access.log",  // nil omits it
    error: "/path/error.log",    // nil omits it
    dnsLog: true                 // nil omits it
)
```

Servers take both engine forms — a bare address (`.plain`) or an address
scoped to domains (`.detailed`). A complete document therefore assembles like
this: `outbounds` arrive from conversion or your skeleton; `log`, `dns`,
`fakedns`, and `routing` are typed options; entries and standards are derived;
and anything schema-exotic rides in the typed tree via `transform`/`patch`.

### Proxy mode vs TUN mode

Proxy mode moves one app's traffic: the engine opens ports on your own device
and traffic you deliberately send there goes through. On macOS a system proxy
setting covers the whole machine; on iOS it covers your app's own requests —
other apps are untouched, with zero system involvement and no entitlements.

TUN mode is device-wide capture through the engine's own `tun` inbound —
the documented shape the published Xray clients run, verified against the
stock engine (a `protocol: tun` document passes `validate()` and launches
with a handed-off descriptor; a live test in the suite proves both). The
engine reads packets off a TUN interface, and who owns that interface
decides the setup:

- **macOS**: the engine creates the interface itself from the entry's `name`
  (e.g. `"utun10"`) — no descriptor needed, just route traffic at it via
  `autoSystemRoutingTable` (e.g. `["0.0.0.0/0", "::/0"]`) so packets arrive.
  Creating a utun unprivileged fails with "operation not permitted", so the
  engine-running process needs the usual VPN privileges for this path.
- **iOS**: the interface belongs to your NetworkExtension, so the provider
  reads its file descriptor and hands it over through
  `XrayTunEntry(fileDescriptor:)` — the kit merges it into the document's `env`
  as `xray.tun.fd`, the variable Xray-core reads from its own environment
  at launch. Nil descriptor, like nil entry, writes no `env` key: proxy-mode
  documents never carry tunnel state. The read itself is one call:
  `providerFileDescriptor(from: packetFlow)` takes the provider's flow (as a
  plain `NSObject`, no import needed) and returns the descriptor, throwing
  `.invalidInput` when the key path is absent or the value unusable. There
  is no public API for this value, so the helper uses private key-value
  access — the only route available. Re-verify it every iOS release and keep
  it isolated to this call.

`XrayTunEntry` fields, all defaulted: `tag` (`"tunIn"`), `listen`
(`"127.0.0.1"`), `name` (nil — the engine's default), `mtu` (1500),
`gateway` (nil — e.g. `["198.18.0.1/15", "fc00::1/64"]`; IPv4 only on
macOS), `dns` (nil — XrayDNS servers the engine puts on the interface; the
one TUN engine field that matters on Apple platforms, the Windows-only
helpers are deliberately not exposed), `userLevel` (nil — level 0),
`autoSystemRoutingTable` (nil — e.g. `["0.0.0.0/0", "::/0"]`),
`autoOutboundsInterface` (nil — but the wire says `"auto"` when a routing
table is set without an explicit interface, mirroring the engine's own
default from `TunConfig.Build`: the engine implies `"auto"` there, so the
document shows what the engine will do. With no table the key stays absent
— forcing `"auto"` there breaks descriptor hand-off, so the kit does not),
`fileDescriptor` (nil), and `sniffing` (nil — inherits the session's through
the pipeline like any entry default). The entry carries no
port and no auth — traffic arrives as packets, not connections — so keep
any SOCKS listener on localhost *and* guarded when both modes coexist.

One environment subtlety the kit handles: the engine applies the document's
`env` entries into its own process at launch and never unsets them, so a
descriptor from an earlier tunnel session would hijack the next fd-less
launch. Assembling with a descriptor-less `XrayTunEntry` therefore clears
`xray.tun.fd` (both spellings) from the process environment automatically.

The provider half, all outside this package: set the tunnel network settings
with default routes and XrayDNS pointing at the utun interface; read the
interface's file descriptor; assemble with the descriptor and launch from
inside the provider process — the engine must run where the interface lives
(the extension on iOS, the app on macOS):

```swift
let tun = try Xray.shared.tun(
    gateway: ["198.18.0.1/15"],
    autoSystemRoutingTable: ["0.0.0.0/0"],
    autoOutboundsInterface: "auto",
    fileDescriptor: fd   // from the provider's utun interface; omit on macOS
)
try Xray.shared.newSession().start(
    .shareLinks(serverFeed),
    options: Xray.shared.options(tun: tun)
)
```

`validate` checks the tun document like any other, and `build` lets you
inspect the exact document the provider will run before you ship it there.
Installing the tunnel needs a VPN configuration the user approves once
(Settings → General → VPN); proxy mode needs none of that, at the cost of
dying with your app process.

### One-shot questions on `Xray`

```swift
Xray.shared.version() throws -> String
Xray.shared.isRunning() throws -> Bool
Xray.shared.health() throws -> Bool
Xray.shared.findAvailablePorts(count: Int = 1, excluding: [Int] = []) throws -> [Int]
Xray.shared.verifyAvailablePorts(count: Int = 1, excluding: [Int] = []) throws -> [Int]
Xray.shared.ping(_ targets: [XrayPingTarget], options: XrayPingOptions? = nil) throws -> [XrayPingResult]
Xray.shared.decodeSubscription(_ text: String, ageSecret: String? = nil) throws -> String
Xray.shared.generateAgeKeyPair(kind: .x25519) throws -> XrayAgeKeyPair
Xray.shared.writeGeoInventory(database: String, kind: XrayGeoDatabase, in: URL) throws -> URL
Xray.shared.proxyConfiguration(_ source: XrayAssemblySource, remarks: String? = nil, socksPort: Int? = 10808, httpPort: Int? = nil, routing: XrayRouting? = nil, dns: XrayDNS? = nil, log: XrayLog? = nil) throws -> XrayConfig
```

- `version()` answers, for example, "26.10.29", the Xray-core build compiled
  into the framework. `health()` is the watchdog probe: false when nothing is
  running, true when an instance is up *and* answering, and a throw when the
  bridge itself is wedged — each call is bounded at ~5 seconds (a wedged call
  throws `.timedOut`), so a stuck engine cannot hang the poll loop. Poll it
  on a timer; a throw means rebuild, not retry.
- `findAvailablePorts` asks the engine for TCP ports nothing else on this
  machine is currently listening on. Nothing is killed or reserved — it is a
  check, and a port can be taken between the answer and your launch. Useful
  for client configurations whose inbounds listen locally, since picking
  hardcoded port ranges means collisions more often than not. `excluding`
  skips port numbers you already have.
- `verifyAvailablePorts` goes one step further: every returned port also
  passes a real TCP bind against 127.0.0.1 first. The engine's answer is a
  snapshot, and something else can grab a port between the answer and your
  launch — this closes that hole. Throws `.bridgeFailed` when not enough
  bindable ports turn up, `.invalidInput` for a count below 1. Prefer it for
  any port the engine will actually listen on (entries, metrics); the check
  is best-effort at call time, not a reservation.
- `decodeSubscription` unwraps a provider's Age-encrypted subscription
  export: text starting with the Age armor header is decrypted with
  `ageSecret`, and *any other text comes back unchanged*. It does not parse
  links and does not base64-decode — that is `XrayConfig(shareLinks:)`'s job,
  which takes a single link, many newline-separated links, a base64 blob,
  or this function's output. Pass the
  `AGE-SECRET-KEY-...` string as `ageSecret` for encrypted exports.
- `generateAgeKeyPair` makes keys for encrypted feeds: `XrayAgeKeyPairKind.x25519`
  gives the classic pair, `.hybrid` folds ML-KEM-768 over it for post-quantum
  resistance. The secret stays on the device (`AGE-SECRET-KEY-...`, keep it
  out of logs); the public half (`age1...`) is publishable.
- `writeGeoInventory` reads a GeoIP/GeoSite `.dat` file and writes every
  code/region with rule and category counts next to it as `<database>.json`;
  `.geosite` maps to hostname databases, `.geoip` to IP ranges. The
  `database` name is the filename without extension (`"geosite"` for
  `geosite.dat`); `directory` is the folder holding the `.dat`. Returns the
  inventory file's URL.

### Value factories on `Xray.shared`

Every value above has a factory twin, so user code passes values to functions
and never spells a type name. Same defaults as the inits; factories with a
rule throw `.invalidInput` instead of failing inside the engine:

```swift
Xray.shared.routingRule(domains:ips:port:network:protocols:inboundTags:destination:) -> XrayRoutingRule
Xray.shared.routing(domainStrategy:rules:final:) -> XrayRouting
Xray.shared.dns(hosts:queryStrategy:servers:) -> XrayDNS
Xray.shared.fakeDNS(ipPool:poolSize:) -> XrayFakeDNS
Xray.shared.log(level:access:error:dnsLog:) -> XrayLog
Xray.shared.tun(tag:listen:name:mtu:gateway:dns:userLevel:...:fileDescriptor:sniffing:) throws -> XrayTunEntry
Xray.shared.providerFileDescriptor(from: NSObject) throws -> Int32  // pass the provider's packetFlow
Xray.shared.socksEntry(tag:listen:port:udp:auth:sniffing:) throws -> XrayAssemblySocksEntry
Xray.shared.httpEntry(tag:listen:port:auth:sniffing:) throws -> XrayAssemblyHttpEntry
Xray.shared.dnsRelay(tag:listen:port:address:remotePort:network:) throws -> XrayAssemblyDNSRelay
Xray.shared.credentials(username:password:) -> XrayCredentials
Xray.shared.sniffing(destOverride:enabled:routeOnly:domainsExcluded:metadataOnly:) -> XraySniffing
Xray.shared.options(sniffing:transform:routing:credentials:tun:environment:observatory:geoCheck:dns:fakeDNS:log:metricsPort:) -> XraySessionOptions
Xray.shared.metrics(tag:port:) throws -> XrayMetrics
Xray.shared.observatory(subjectSelector:probeURL:probeInterval:enableConcurrency:) throws -> XrayObservatory
Xray.shared.trafficMonitor(port:host:timeoutSeconds:) throws -> XrayTrafficMonitor
Xray.shared.trafficWatchdog(port:host:interval:stalledAfter:onStall:) throws -> XrayTrafficWatchdog
Xray.shared.pingTarget(config:outboundTag:) -> XrayPingTarget
Xray.shared.pingOptions(timeoutSeconds:testURL:) throws -> XrayPingOptions
Xray.shared.geoDownloader(geoIPURL:geoSiteURL:) -> XrayGeoDownloader
Xray.shared.ensureAssets(for:databases:in:geoIPURL:geoSiteURL:) async throws -> URL
```

`throws` marks the ones with a rule: ports must be 1–65535, the TUN
descriptor non-negative, the ping timeout positive. `providerFileDescriptor`
takes the provider's packet flow as a plain `NSObject` (no NetworkExtension
import needed) and walks its `socket.fileDescriptor` key path with a
capability check at each hop, so an iOS release that renames the key throws
`.invalidInput` instead of tripping an Objective-C exception — re-verify it
per iOS release. `ensureAssets` only downloads databases that are missing or
unreadable, never refetches what is there. Enum cases
(`.block`, `.plain(...)`, `.proxy`, …) and engine-made values
(`XrayAgeKeyPair`, snapshots, deltas) need no factories — cases already are
value-passing calls, and read-models come from the engine.

`Security` framework and libresolv are linked by the package, so the Go
runtime inside libXray resolves its TLS and XrayDNS symbols without you adding
anything to the target.

### `Xray.shared.ping`: latency through the real path

```swift
let targets = [Xray.shared.pingTarget(config: serverJson)]  // outboundTag nil = engine picks
let options = try Xray.shared.pingOptions(timeoutSeconds: 10, testURL: "https://yourapp.com/ping")
let results = try Xray.shared.ping(targets, options: options)
// XrayPingResult: succeeded, latencyMilliseconds, failureReason?
```

Each measurement completes a full HTTP request through the outbound, so
success covers routing and TLS handshakes, not just a bare TCP probe.
Targets pair a server's compact Xray JSON (only its `outbounds` are read)
with an optional outbound tag — nil lets the engine pick the outbound tagged
`"proxy"`, else the first one. Answers come back in input order, each
carrying `succeeded`, `latencyMilliseconds` (real measurement, in ms), and —
on failure — `failureReason`.

Four rules throw `.invalidInput` before touching the engine: no targets, more
than five targets per call (split larger pools into batches), a timeout of
zero or less (seconds, whole-batch deadline), and a test URL that is not an
absolute HTTP(S) URL. A fifth: the engine must be stopped, because it
measures in an isolated instance of its own — measuring while running throws
before the call instead of the engine's refusal. Blocking, so prefer a
background task or wrap it in `Task.detached` yourself.

The test URL is what the engine actually fetches through each outbound, so
point it at an endpoint that answers fast and empty — a `204 No Content` is
ideal, and your own endpoint measures your real path rather than the
internet's. If your endpoint goes down, every target reports failure with
your outage as the reason, so check the endpoint directly before blaming the
servers.

### `XrayTrafficMonitor`: live speed and totals

```swift
var assembly = Xray.shared.assembler(.shareLinks(text))
assembly.metricsPort = verifiedPort   // adds the XrayMetrics listener + stats + policy switches
let config = try assembly.assemble()
try session.start(config)

let monitor = try Xray.shared.trafficMonitor(port: verifiedPort)
var previous = try await monitor.snapshot()
while running {
    try await Task.sleep(for: .seconds(1))
    let now = try await monitor.snapshot()
    let speed = now.delta(since: previous)
    print(speed.upPerSecond, speed.downPerSecond)  // bytes/sec both ways
    totals.up += speed.totalUp                      // accumulate for the session
    totals.down += speed.totalDown
    previous = now
}
```

The engine already publishes per-tag byte counters on a localhost HTTP
endpoint (`/debug/vars`) — no new dependencies, no OS-version gating, stock
binary. Setting `metricsPort` writes the three config pieces that enable it:
the `metrics` listener on `127.0.0.1:port`, an empty `stats` section, and the
four `policy.system` stats switches (merged into your existing policy, never
replacing it). Out-of-range ports throw `.invalidInput` at assembly, before
anything launches — and so does a metrics port an inbound already listens on:
give metrics its own pocket (from `verifyAvailablePorts`), not a shared one.
Treat the port like a local proxy listener: it binds
loopback only, but any process on the device can reach loopback — and the
endpoint also serves the engine's `pprof` block — so keep it unadvertised
and verify it the way you'd guard SOCKS.

`snapshot()` returns a `XrayTrafficSnapshot`: per-tag `inbound`/`outbound`
dictionaries of `XrayTrafficCounter` (`up`, `down`, `total`), plus summed
`totalUp`/`totalDown`. The engine counts every byte twice — once on the
inbound it entered through, once on the outbound it left through — so the
totals are 2x the bytes on the wire. Dashboards want the outbound side:
`uplink`/`downlink` (and their `XrayTrafficDelta` twins, with
`uplinkPerSecond`/`downlinkPerSecond`) count that side only. `delta(since:)`
diffs two snapshots into a `XrayTrafficDelta` — per-tag bytes moved in the
interval, totals, and `upPerSecond`/`downPerSecond` derived from the
wall-clock gap, so polling once a second reads as live speed. If the engine
restarted between snapshots, the whole later reading counts as new traffic
rather than going negative. Unreachable endpoints and non-200 answers throw
`.bridgeFailed`; poll failures in your loop should keep the last good values
and retry, the same way you'd treat any sampled signal. (`/debug/vars` also
exposes the engine's own `pprof` block — same endpoint, not parsed here.)

#### `XrayObservatory`: which outbounds are actually alive

HTTP counters say how much moved; an observatory says whether each outbound
*could* move anything right now. The engine probes every selected outbound
through itself on an interval and publishes the answers on the same XrayMetrics
endpoint:

```swift
var assembly = Xray.shared.assembler(.shareLinks(text))
assembly.metricsPort = verifiedPort
assembly.observatory = try Xray.shared.observatory(
    subjectSelector: ["fast"],        // probe outbound tags with this prefix
    probeInterval: "1m"               // Go duration: "30s", "2m", "1h"
)
let config = try assembly.assemble()

// later, from the same snapshot() call:
let health = snapshot.observatory["fast-v1"]
if health?.alive == true, let ms = health?.delayMilliseconds {
    print("fast-v1: \(ms) ms")
} else {
    print("fast-v1 down:", health?.failureReason ?? "no probe yet")
}
```

`XrayOutboundProbe` fields: `alive`, `delayMilliseconds` (nil when no successful
probe is on record), `failureReason` (the engine's own text for the last
failure), `lastSeen`, `lastTry`. Probing costs a real network request per
selected outbound per interval — pick `subjectSelector` deliberately and
keep the interval honest. Without an `observatory` section the field reads
empty; without `metricsPort` there is no place to read the answers. The
factory validates up front: an empty selector, a non-http(s) probe URL, or
a malformed interval (Go durations look like `"30s"`, `"1m"`, `"1h"`)
throws `.invalidInput` before anything is written.

#### `XrayTrafficWatchdog`: fire once per stall, then reset

The monitor answers "how much"; the watchdog answers "has anything moved
lately" — the primitive behind every reconnect loop:

```swift
let watchdog = try Xray.shared.trafficWatchdog(
    port: metricsPort, interval: .seconds(10), stalledAfter: .seconds(60)
) { Task { await rebuild() } }   // hop off: the callback must return fast
watchdog.start()
// ... later, when the session ends:
watchdog.stop()
```

`interval` is the poll cadence, `stalledAfter` the silence that counts as a
stall. The fire is latched — one call per episode, reset by any movement —
and failed snapshots count as stalls, so a dead metrics endpoint fires too
instead of reading as eternal calm. An idle tunnel reads as stalled, so
start the watchdog after first traffic or set the window generously.
`stop()` disarms it; dropping it without stopping is safe (it stands down),
but explicit stops read better in provider teardown. See [Staying
connected](#staying-connected-the-rebuild-recipe) for the full loop this
plugs into.

### Geo databases

Two jobs live here: fail fast when a required database is absent, and fetch
the ones that are.

**The gate.** The engine resolves `geosite:` / `geoip:` entries lazily at
traffic time, so a missing file turns into silent dead routing — `validate()`
passes, real requests just fail. Every `session.build` / `validate` / `start`
therefore checks that the databases the routing *and* dns sections reference
exist and parse where the engine will look: the document's
`env["xray.location.asset"]` first (set it via `XraySessionOptions.environment`), then
the process environment, then the executable's directory. A missing, empty,
or garbage file throws `.geoAssets`, naming the database and every directory
searched. Plain domains and CIDRs never trigger the check, and
`XraySessionOptions.geoCheck: false` turns it off entirely for documents you verify
yourself. `ext:` references are checked the same way by filename: a bare
`ext:custom.dat:tag` is searched in the candidate directories, an absolute
path is checked where it points — a missing file throws `.geoAssets` too.

**The fetch.** The engine only inventories databases it already has.
Fetching them is a separate step, and this package covers it too:

```swift
let downloader = Xray.shared.geoDownloader()
try await downloader.download(into: dataDir) { progress in
    print("Geo files: \(Int(progress * 100))%")
}
```

Both files download concurrently into `directory` as `geoip.dat` and
`geosite.dat`, replacing same-named files. Defaults point at the lightweight
rule sets; pass `geoIPURL` / `geoSiteURL` (at init or per call) to use your
own mirror. The callback reports combined 0.0 to 1.0 progress on the main
actor and is optional. Configure URLs before the first download, then treat
the instance as read-only. `XrayGeoDownloader.defaultGeoIPURL` and
`.defaultGeoSiteURL` expose the bundled defaults;
`XrayGeoDatabase.geosite` / `.geoip` name which database a call is about.
Underneath, `XrayGeoAssets` is the gate itself: it finds the candidate
directories (document `env`, process environment, executable folder),
verifies each referenced `.dat` by its protobuf framing, and throws
`.geoAssets` naming the missing, corrupt, or unreadable file.

**The upkeep.** First launches download; every launch after only fills gaps.
`ensureAssets` scans the assembled config (or an explicit list) for
`geosite:` / `geoip:` references and downloads only the databases that are
missing or unreadable — files already present are never refetched, and a
document with plain-domain rules downloads nothing at all:

```swift
let directory = try await Xray.shared.ensureAssets(for: config, in: dataDir)
let options = Xray.shared.options(environment: ["xray.location.asset": directory.path])
try session.start(.json(config.json), options: options)
```

Omit `for:` to fetch the pair regardless of references, or pass
`databases:` to pin the list. The returned directory feeds straight into
`XraySessionOptions.environment`, closing the loop with the gate above.

### Subscriptions: fetch, unwrap, parse

A subscription is a URL that serves a server list as text — one
`vless://` / `trojan://` / `ss://` / `socks://` link per line, a single
link, a base64 blob of those, or (for panels that encrypt) an Age-armored
blob. Three stages, three calls, no magic:

```swift
// 1. Fetch: plain HTTP, your code or the one-call start below.
let cipher = try String(contentsOf: subscriptionURL, encoding: .utf8)

// 2. Unwrap: Age-decrypt when the panel encrypts; anything else passes
//    through unchanged, so calling it unconditionally is safe.
let plain = try Xray.shared.decodeSubscription(cipher, ageSecret: ageSecretOrNil)

// 3. Parse: links become outbounds through the engine's converter.
let config = try Xray.shared.configuration(.shareLinks(plain))
```

What the converter keeps is engine behavior, verified against the bundled
build: `vless://`, `trojan://`, `ss://`, `socks://`, newline-separated
feeds, and base64 blobs of those. `vmess://`, `hysteria2://`,
`wireguard://`, and raw `{"outbounds":[...]}` JSON blobs are dropped — a
feed of only dropped kinds throws "no valid outbound found". Age armor is
the only encryption the unwrap understands; anything else must be decoded
before it arrives here.

The one-call variant fetches fresh every time — nothing cached, nothing
auto-refreshed — then unwraps, tops up geo assets, and launches under a
deadline, capped at the engine's 16 MiB feed limit:

```swift
try await session.start(
    remoteSubscription: subscriptionURL,
    ageSecret: ageSecretOrNil,
    assetDirectory: dataDir,
    options: Xray.shared.options(metricsPort: verifiedPort),
    deadline: .seconds(30),
    timeoutSeconds: 30
)
```

The 16 MiB cap and the 30-second defaults are the whole policy: feeds are
small text, and anything bigger or slower is treated as wrong rather than
waited out. Poll the URL on your own schedule; the package never phones
home between launches.

### `XrayError`: five cases

```swift
XrayError.engineFailed(String)  // the engine refused; the string carries why
XrayError.bridgeFailed(String)  // our side couldn't talk to it or decode its answer
XrayError.invalidInput(String)  // rejected before the call: bad ports, >5 ping
                                 // targets, empty outbounds with .proxy routing,
                                 // oversized (>16 MiB) raw requests, ...
XrayError.geoAssets(String)     // a geosite:/geoip: reference has no readable
                                 // database — see Geo databases for the fix
XrayError.timedOut(String)      // the engine never answered inside the bound:
                                 // deadline starts, feed fetches, health checks
```

`.engineFailed` strings come from the engine ("no valid outbound found" and
friends) and can change wording between engine releases — match on them only
as a last resort. `.invalidInput` and `.geoAssets` are the package's own
voice: deterministic, documented above, and safe to switch on. Every case also
carries `recoveryHint`, a one-line pointer at where to look next.

### The typed tree: `XrayJSONValue`

Everything `transform` and `patch` touch is this enum — null, bool, int,
double, string, array, object — `Codable`, `Sendable`, `Hashable`, with
literal and dynamic-member support, so documents build and read without a
single cast:

```swift
var doc: XrayJSONValue = ["log": ["loglevel": "warning"]]  // dictionary literal
doc["log"]?["loglevel"] = "error"        // write through subscripts
doc.log?.loglevel?.stringValue           // "error", via dynamic members
doc["missing"]                           // nil — reading is nil-safe, never traps
doc.inbounds?[0]?["tag"]?.stringValue    // index, then field, then typed read
```

Subscripts return optionals (nil for missing or mistyped paths); typed
accessors (`isNull`, `boolValue`, `intValue`, `doubleValue`, `stringValue`,
`arrayValue`, `objectValue`) do the same. Assigning nil through a subscript
removes the key. `XrayJSONObject` is `[String: XrayJSONValue]`, the shape
every configuration document takes. Integers decode as ints (never silently
promoted to doubles), so ports and pool sizes survive the round trip exactly.
Serialization sorts keys, so two builds of the same intent produce identical
text and diff cleanly.

### Raw bridge

The engine's protocol is a single JSON call:
`{"apiVersion":3,"method":"...","payload":{...}}` in,
`{"success":Bool,"data":...,"error":"..."}` out. If this wrapper lags a new
upstream capability, bypass it:

```swift
let request = #"{"apiVersion":3,"method":"xrayVersion"}"#
let response = try Xray.shared.sendRawRequest(request)
print(response)
```

`sendRawRequest` throws `XrayError` on engine-reported failure and frees the
engine's malloc'd answer internally. Requests over 16 MiB are rejected as
`.invalidInput` before crossing the bridge — the engine's own ceiling, so a
well-formed giant request still fails exactly as it would remotely, without
paying for the round trip. Anything you pass with an `apiVersion`
the engine does not know earns "unsupported apiVersion", which is also your
signal that the embedded engine advanced and this wrapper's public methods
are the ones to prefer. The bare `CGoInvoke` / `CGoFree` C functions stay
reachable for emergencies; if you call `CGoInvoke` yourself, capture the
pointer and release it with `CGoFree`.

## Versioning and core updates

How a new core reaches you:

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
core (`26.10.31` → `261031`), the Swift major/minor unchanged unless the
Swift code changed since the last tag — then:

```bash
git tag 261031.1.0
git push origin 261031.1.0
gh release create 261031.1.0 --title v261031.1.0 --notes "Core: XTLS/libXray v26.10.31
Swift: 1.0 (unchanged)"
```

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

## Choosing a server: ping, then connect

One-shot `ping` needs the engine stopped — it measures through an isolated
instance of its own — so the app's natural order is: fetch servers, ping
them idle, connect the winner, and use the observatory from then on. Split
the feed into one link per row, convert each to its JSON, measure, sort:

```swift
let links = feed.components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

let targets = try links.map {
    Xray.shared.pingTarget(config: try Xray.shared.configuration(.shareLinks($0)).json)
}
let results = try Xray.shared.ping(targets,
    options: try Xray.shared.pingOptions(timeoutSeconds: 10))
// results[i].succeeded, .latencyMilliseconds, .failureReason? — input order
```

Rules that throw before the engine is touched: no targets, more than five
per call (batch larger pools), non-positive timeout, non-HTTP(S) test URL,
engine running. Failed measurements normalize to 0 ms with a
`failureReason` — the engine's `10000`/`11000` sentinels never leak. Once
connected, stop pinging and read `snapshot().observatory` instead: it
covers only outbounds in the running config, which is exactly the set a
connected app cares about.

## iOS tunnel provider: the whole start path

The provider owns the interface, the engine runs where the interface
lives, and everything else is the assembly you already know. Order
matters: network settings first (the system needs routes before traffic),
descriptor second, launch third, counters after.

```swift
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var session = Xray.shared.newSession()
    private var monitor: XrayTrafficMonitor?

    override func startTunnel(options: [String: NSObject]?) async throws {
        // 1. Routes and XrayDNS at the utun interface, before anything moves.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = {
            let v4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.0.0"])
            v4.includedRoutes = [NEIPv4Route.default()]
            return v4
        }()
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.1"])
        try await setTunnelNetworkSettings(settings)

        // 2. The descriptor handoff: one guarded read, verified per iOS release.
        let fd = try Xray.shared.providerFileDescriptor(from: packetFlow)

        // 3. Assemble around it. No local entries in TUN mode; metrics on
        //    loopback for counters and observatory answers.
        var a = Xray.shared.assembler(.shareLinks(serverFeed))
        a.socks = nil
        a.dnsRelay = nil
        a.tun = try Xray.shared.tun(
            gateway: ["198.18.0.1/15"],
            autoSystemRoutingTable: ["0.0.0.0/0"],
            fileDescriptor: fd
        )
        a.routing = Xray.shared.routing(final: .proxy)
        a.metricsPort = 24242
        let config = try a.assemble()

        // 4. Provider gate, then launch under a deadline — never sync here.
        let opts = Xray.shared.options(
            tun: a.tun, metricsPort: 24242,
            environment: ["xray.location.asset": geoDir.path]
        )
        let issues = try session.preflightIssues(.json(config.json), options: opts)
        guard issues.isEmpty else { throw ProviderError.misconfigured(issues) }
        try await session.start(config, options: opts, deadline: .seconds(20))

        // 5. Counters after launch; never a read-packets loop — the engine
        //    owns the fd and reads it itself.
        monitor = try Xray.shared.trafficMonitor(port: 24242)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        monitor = nil
        try? session.stop()   // safe when idle; forensics kept for the report
    }
}
```

`preflightIssues` before every launch catches the two provider killers —
a missing descriptor and a non-loopback listen — as values, not crashes.
`deadline:` bounds the start inside the provider's time budget; the sync
starts have no bound and do not belong here. Install the VPN configuration
once (Settings → VPN); the icon and the lifecycle come with it.

## Testing your app: mock the session

`XraySessionProviding` is the session's protocol surface — type your app's
dependency as the protocol, inject `newSession()` in production and a stub
in tests. No engine, no ports, no packets:

```swift
final class FakeSession: XraySessionProviding {
    var logger: ((String) -> Void)?
    var connectedSince: Date?
    private(set) var started: [String] = []

    // A canned document costs no launch: configuration(.json) stores text
    // untouched, and there is nothing to build against the engine.
    func build(_ source: XrayConfigSource, options: XraySessionOptions?) throws -> XrayConfig {
        try Xray.shared.configuration(.json(#"{"inbounds":[],"outbounds":[]}"#))
    }
    func start(_ config: XrayConfig) throws {
        started.append(config.json)
        connectedSince = Date()
    }
    func stop() throws { connectedSince = nil }
    func isRunning() throws -> Bool { connectedSince != nil }
    // ... the remaining starts, validates, preflights, and log tails
    // record-and-answer the same way; the extension's defaulted overloads
    // forward to these full forms, so a mock implements each shape once.
}
```

Your app types its dependency as `XraySessionProviding`, constructs with
`Xray.shared.newSession()` in production and `FakeSession()` in tests, and
asserts on `started` — which documents were launched, in which order —
without ever touching the engine. When the test is about the document
itself rather than the lifecycle, skip the fake: `build`,
`validateOffline`, and `preflightIssues` all run launch-free against the
real session, so asserting on `config.json` text is a unit test with no
mock at all.

## Troubleshooting

- **"unsupported apiVersion"** — XTLS/libXray bumped its bridge protocol. The
  constant to update is `protocolVersion` inside
  `Sources/CoreXray/Calls/EngineTransport.swift`,
  taken from the `LibXrayAPIVersion` in upstream `invoke_model.go` (and please
  open an issue so the next core-update PR also carries the fix).
- **"no valid outbound found"** — the engine declined every entry you passed.
  The bundled converter keeps `vless://`, `trojan://`, `ss://`, and
  `socks://` (plus base64 of those) and drops `vmess://`, `hysteria2://`,
  `wireguard://`, and `{"outbounds":[...]}` JSON — a feed of only dropped
  kinds throws this. A bare `vless://uuid@host:443` without scheme defaults
  will not build either. Validate with `validate()` for detail on a JSON
  config.
- **linker failures mentioning `Sec*` or `res_9_*` symbols** — your app built
  against the binary target directly instead of going through `CoreXray`.
  Depend on the `CoreXray` product, which owns the framework and library
  linkage.
- **Package resolution hangs or fails on "unsupported platform"** — the
  framework has no watchOS/visionOS slices, so those destinations cannot use
  this package, now or later.

## Staying connected: the rebuild recipe

The engine is process-global and silent when it dies: network changes,
sleep/wake, or a crash leave the tunnel up with nothing moving. The package
gives you the three primitives; the app owns the loop:

1. **Liveness** — poll `session` counters, not just `health()`. `health()`
   proves the bridge answers; advancing `uplink/downlink` proves traffic
   moves. `XrayTrafficWatchdog` does the polling and calls `onStall` after
   `stalledAfter` with no movement (latched — one fire per episode, reset by
   any traffic). An idle tunnel reads as stalled, so start it after first
   traffic or set the window generously:

   ```swift
   let watchdog = try engine.trafficWatchdog(port: metricsPort, stalledAfter: .seconds(60)) {
       Task { await rebuild() }   // hop off the watchdog's task
   }
   watchdog.start()
   ```

2. **Path changes** — watch `NWPathMonitor` in the app (it stays app policy,
   the package never owns it). On an unsatisfied path, debounce ~2s (tunnels
   flap during handover), then rebuild.
3. **Rebuild** — `stop()` is safe when idle, so rebuild unconditionally:
   `try? session.stop()`, then `start(remoteSubscription:deadline:)` (or the
   assemble path) with backoff 1s → 2s → 4s capped, then surface the failure
   to the user instead of retrying forever. Prefer the async deadline start
   everywhere in providers: a thrown error is recoverable, a watchdog kill
   of an overstaying sync start is not.
4. **Forensics** — when a rebuild fires, attach `session.recentLogs()` and
   `session.recentEngineLogs()` to the report. The first says what the
   package did; the second says what the engine saw.

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

## Credits

All engine work belongs to the [XTLS team](https://github.com/XTLS/libXray)
and [Xray-core](https://github.com/XTLS/Xray-core). This repo only carries
their Apple builds in SwiftPM-friendly form. The license is upstream's; see
`LICENSE`.

## Examples: step-by-step guides

The full walkthroughs live in [`Examples/`](Examples/), one file per
task, each with commented code:

1. [`01-full-json.md`](Examples/01-full-json.md) — running the core from
   a full JSON document: load, validate, launch, stop.
2. [`02-assembler-proxy-and-tun.md`](Examples/02-assembler-proxy-and-tun.md) —
   assembling documents in proxy mode (local entries, routing, DNS,
   logging) and TUN mode (fd hand-off, preflight, no dead listeners).
3. [`03-traffic-stats.md`](Examples/03-traffic-stats.md) — reading stats:
   `uplink`/`downlink` vs doubled totals, per-second speeds from deltas,
   observatory probes, the stall watchdog.
4. [`04-health-and-status.md`](Examples/04-health-and-status.md) —
   checking core status: `isRunning`, `version`, `health`,
   `connectedSince`, forensics, provider preflight.
5. [`05-logging.md`](Examples/05-logging.md) — writing the log (live sink
   + engine log files) and reading it back (ring buffer, tails, the
   disconnect report).
6. [`06-ping.md`](Examples/06-ping.md) — pinging one config or all
   configs: conversion first, batching, timeout/test-URL rules, and why
   the observatory replaces ping while connected.
7. [`07-network-extension.md`](Examples/07-network-extension.md) —
   setting up the Network Extension: target, entitlements, app group,
   the full provider start path, the app-side manager.
8. [`08-subscriptions.md`](Examples/08-subscriptions.md) — from
   subscription URL to running engine: fetch, Age-unwrap, parse, launch.
9. [`09-stay-connected.md`](Examples/09-stay-connected.md) — watchdog →
   health → rebuild → preflight: the reconnect loop.
