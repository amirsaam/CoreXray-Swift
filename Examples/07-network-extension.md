# 07 — Setting up the Network Extension (iOS TUN)

Proxy mode needs no system integration. TUN mode — all-device traffic,
the VPN icon — needs a Packet Tunnel Provider target, and the engine
must run INSIDE it: the utun fd the system creates belongs to the
provider process, and the fd cannot cross processes.

## Step 1 — The target

1. Xcode → File → New → Target → **Network Extension** → provider type
   **Packet Tunnel**. Name it e.g. `Tunnel`.
2. The template gives `PacketTunnelProvider.swift` (subclass of
   `NEPacketTunnelProvider`), an `.entitlements` file, and an Info.plist
   entry (`NSExtension` → `NSExtensionPointIdentifier` =
   `com.apple.networkextension.packet-tunnel`). Keep all three.
3. The provider is a separate process with its own sandbox: put shared
   state (selected server, stats) in an **App Group** container, and add
   the group to both the app and the provider targets.
4. Add this package to the provider target too — the engine runs there,
   so `import CoreXray` must resolve there, not just in the app.

Memory budget: providers are jetsam-limited — 50 MiB for a packet
tunnel on current iOS. The Go runtime plus referenced `.dat` files fits,
but keep `geo` OUT of the provider unless routing needs it — plain rules
need no geodata (gate semantics), and every megabyte in the provider is
one you cannot spend elsewhere. Ship `.dat` files in the app, copy only
referenced ones into the group container when `ensureAssets` says the
config needs them.

## Step 2 — The provider start path

Order is load-bearing: settings first (the system needs routes before
traffic), descriptor second, launch third, counters after. Never a
read-packets loop — the engine owns the fd and reads it itself.

```swift
import NetworkExtension
import CoreXray

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var session = Xray.shared.newSession()
    private var monitor: XrayTrafficMonitor?
    private var watchdog: XrayTrafficWatchdog?

    override func startTunnel(options: [String: NSObject]?) async throws {
        // Read what the app stored in the group container: which server,
        // which routing, where geo lives.
        let plan = try TunnelPlan.load()   // your Codable in the group container

        // 1. Interface settings. The subnet here and the tun gateway in
        //    step 3 must agree, or packets route nowhere.
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(
            addresses: ["198.18.0.2"], subnetMasks: ["255.255.0.0"])
        v4.includedRoutes = [NEIPv4Route.default()]   // default route: all apps
        settings.ipv4Settings = v4
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.1"])
        try await setTunnelNetworkSettings(settings)

        // 2. The descriptor handoff. One guarded read off the packet flow —
        //    private key-value access is the only route (no public API
        //    exposes it); re-verify every iOS release. Throws .invalidInput
        //    instead of an Obj-C exception when a key renames.
        let fd = try Xray.shared.providerFileDescriptor(from: packetFlow)

        // 3. Assemble around the fd. No local entries in TUN mode — packets
        //    arrive on the fd, SOCKS/HTTP entries would be dead listeners.
        var a = Xray.shared.assembler(.shareLinks(plan.serverLink))
        a.socks = nil
        a.dnsRelay = nil
        a.tun = try Xray.shared.tun(
            gateway: ["198.18.0.1/15"],
            autoSystemRoutingTable: ["0.0.0.0/0"],  // also implies the
            fileDescriptor: fd                      // self-route protection
        )
        a.routing = Xray.shared.routing(final: .proxy)
        a.log = Xray.shared.log(level: .warning, error: plan.errorLog.path)
        a.metricsPort = 24242
        let config = try a.assemble()

        // 4. Preflight as values: missing descriptor and non-loopback
        //    listens become checklist items, not crashes.
        let opts = Xray.shared.options(
            tun: a.tun, metricsPort: 24242,
            environment: ["xray.location.asset": plan.geoDir.path]
        )
        let issues = try session.preflightIssues(.json(config.json), options: opts)
        guard issues.isEmpty else { throw TunnelError.misconfigured(issues) }

        // 5. Launch under a deadline — the provider has a time budget and
        //    the sync starts have no bound. They do not belong here.
        try await session.start(config, options: opts, deadline: .seconds(20))

        // 6. Counters and stall detection, after launch. Publish to the app
        //    via the group container + Darwin notify (poll from the app).
        monitor = try Xray.shared.trafficMonitor(port: 24242)
        watchdog = try Xray.shared.trafficWatchdog(
            port: 24242, interval: .seconds(10), stalledAfter: .seconds(60)
        ) { [weak self] in try? self?.reconnect(plan: plan) }
        watchdog?.start()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        watchdog?.stop(); watchdog = nil
        monitor = nil
        // Safe when idle. Log tail survives for the app's report screen.
        try? session.stop()
    }
}
```

## Memory budget: the 50 MiB ceiling, and living in it

iOS kills provider processes that exceed their jetsam ceiling with no
warning and no callback. For a packet tunnel that ceiling is **50 MiB**
on current iOS — the Xray team states it as known-certain in
[XTLS/Xray-core#4422](https://github.com/XTLS/Xray-core/issues/4422),
with app proxy and DNS proxy at 15, filter control/data at 50, app push
at 24. History: 5–6 MB originally, raised to 15 MB in iOS 10 beta 2
(Psiphon's [rdar://27660401](http://www.openradar.appspot.com/27660401)),
then to 50 MB in iOS 15 — reported by the radar's own originator, who
closed it as resolved. There is still no API, Info.plist key, or
documented entitlement to raise it further: on stock iOS the ceiling is
system-imposed and not negotiable. A kill looks exactly like a random
disconnect, which is why providers "mysteriously drop" only in the
field — limits are relaxed under the Xcode debugger, so you cannot
reproduce this attached. Diagnose it in `Settings → Privacy → Analytics
→ Analytics Data`: a `JetsamEvent` with reason `per-process-limit`
naming your provider is the fingerprint.

So what are the "70 MB clients"? No stock-iOS mechanism reaches past
50 — a 70 MB *setting* is the client's own guard, not the system
ceiling, and the engine still dies at 50 regardless of what the UI
says. (Streisand, for one, exposes its own memory-limitation toggle in
settings — app-level policy, not an entitlement.) The only published
how-to for actually raising the ceiling (Nov 2022) is explicitly a
**jailbreak** method — patching the jetsam property lists, where
per-process limits are just numbers in a plist. Anything else showing
high memory is measuring something else: the macOS provider (no such
ceiling), the containing **app** process instead of the provider, or a
debug build running relaxed. If someone offers you a stock-iOS
mechanism, ask for the entitlement string — without one, it is one of
the above.

The playbook, then, is footprint — and geo dominates it:

- **Categories cost, not files.** A referenced `.dat` is now mmapped by
  the engine (upstream `XTLS/Xray-core#5480`, shipped in the core we
  pin), so file size is no longer the bill — the *unmarshalled rules*
  are. Scale from #4422: `geosite:ads` (749 rules) loads fine;
  `geosite:category-ads-all` (65,565 rules) and `geosite:cn` (94,767
  rules) crash the tunnel. Upstream's own conclusion: on iOS only
  slimmed-down geofiles survive — a full Loyalsolider `geosite.dat`
  (~21 MB on disk) leaves no room for the runtime once big categories
  unmarshal. `ensureAssets` fetches only referenced databases, but *you*
  choose which categories the config references: prefer `geosite:ads`
  over `category-ads-all`, split regions out of `cn`, and never
  reference a giant category "just in case".
- **Download outside the provider.** Fetching inside the extension burns
  transient memory (TLS buffers, decode) against the same ceiling. The
  app process has gigabytes; do all networking there, write finished
  `.dat` files to the group container, and let the provider only map and
  read them.
- **Cap the Go heap from your side.** The Go runtime honors `GOMEMLIMIT`
  from the process environment at startup, and the provider can `setenv`
  it before the first engine call (the runtime initializes lazily on
  first use). Account it: Go heap + unmarshalled geo + provider overhead
  must stay under 50 — upstream suggests leaving ~20 MiB for the
  running proxy on top of startup peak, so `GOMEMLIMIT=32MiB` is a sane
  starting point, then measure. It won't stop a leak, but it turns
  unbounded growth into early, explicable failures instead of silent
  jetsam kills. Standard Go behavior, not package API — set it in
  `init()`.
- **Watch headroom, don't guess.** `os_proc_available_memory()` inside
  the provider tells you what jetsam will allow *right now*. Sample it
  next to traffic snapshots in beta builds; when a drop correlates with
  near-zero headroom instead of a stall, you have a memory kill, not a
  network failure — and the fix is footprint, not reconnect logic.
- **Keep logging out of memory.** File sink with a serial queue (05);
  never accumulate lines in the provider. The 200-line ring buffer is the
  only in-memory log, and it is bounded.

If memory pressure forces a choice, drop `geosite` first: inline the
handful of domains you actually route as plain strings (zero bytes) and
keep only `geoip` rules. Category blocking (`geosite:ads`) has no
zero-byte substitute — that is the file you budget for.

## Geo routing in the provider

Geo routing = rules referencing `geosite:`/`geoip:` + the `.dat` files
resolving them + `xray.location.asset` pointing at the files. Three
stages, split across processes on purpose:

```swift
// APP PROCESS, at subscription refresh — gigabytes available, no rush.
// ensureAssets scans the assembled config for geosite:/geoip: references
// (routing rules AND dns hosts keys) and fetches ONLY the referenced
// databases into the group container. Unreferenced configs download
// nothing — that is the whole memory strategy.
let dir = try await Xray.shared.ensureAssets(
    for: config,                                   // scan this document
    in: groupContainer.appendingPathComponent("geo")
)
```

```swift
// PROVIDER, at launch — point, don't fetch. The document's env map is
// applied into the engine's process at start, so this one key wires the
// whole lookup chain: engine → env → .dat files.
let opts = Xray.shared.options(
    tun: a.tun, metricsPort: 24242,
    environment: ["xray.location.asset": dir.path]
)
try await session.start(config, options: opts, deadline: .seconds(20))
```

Four rules that make it correct:

1. **Sniffing is load-bearing in TUN mode.** Packets arrive as raw IPs;
   `geosite:` matches *domains*. Without SNI sniffing the engine never
   learns the domain and geosite rules silently match nothing. Always
   set `a.sniffing = Xray.shared.sniffing()` (or inherit it per-entry)
   when any domain/geosite rule exists — proxy mode gets this from the
   inbound handshake, TUN mode does not.
2. **`domainStrategy` decides how strictly domains match.**
   `.asIs` matches only what sniffing/DNS recovered; `.ipIfNonMatch`
   falls back to IP (geoip) rules when no domain is known — the forgiving
   default for TUN. Set it on `routing()` deliberately, not by default.
3. **Stage, don't bundle.** Ship no `.dat` in the provider; copy only
   referenced ones into the group container. A config update that drops
   the last `geosite:` rule should delete the file — stale files are
   silent memory tenants.
4. **Missing files fail fast, by design.** If the provider launches a
   geo-referencing config with no files at the env path, `build` throws
   `.geoAssets` naming the file. Catch it and tell the user to open the
   main app (which re-runs `ensureAssets`) instead of retrying a launch
   that cannot succeed.

## Step 3 — The app side

```swift
// Install once (Settings → VPN prompts the user), then start/stop:
let manager = NETunnelProviderManager()
try await manager.loadFromPreferences()
manager.providerProtocol = {
    let p = NETunnelProviderProtocol()
    p.providerBundleIdentifier = "com.yourapp.Tunnel"
    p.serverAddress = "BomBom"   // cosmetic
    return p
}()
manager.isEnabled = true
try await manager.saveToPreferences()
try manager.connection.startVPNTunnel()

// Stats path: provider writes TunnelStats (up/down/speeds/uptime, see 03)
// to the group container and posts a Darwin notification; the app reads
// on wake. Never poll the metrics port from the app — it lives in the
// provider process on its loopback.
```

`setTunnelNetworkSettings` before launch, `deadline:` on every start,
`preflightIssues` before every launch, `watchdog` after every launch —
the four habits that separate a provider that works from one that
mysteriously drops. Reconnect logic in `09-stay-connected.md`.
