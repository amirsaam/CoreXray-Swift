# 07. Setting up the Network Extension (iOS TUN)

Proxy mode needs no system integration. TUN mode covers all-device
traffic and shows the VPN icon. It needs a Packet Tunnel Provider target,
and the engine must run INSIDE it. The utun fd the system creates belongs
to the provider process, and the fd cannot cross processes.

## Step 1. The target

1. Xcode → File → New → Target → **Network Extension** → provider type
   **Packet Tunnel**. Name it e.g. `Tunnel`.
2. The template gives `PacketTunnelProvider.swift` (subclass of
   `NEPacketTunnelProvider`), an `.entitlements` file, and an Info.plist
   entry (`NSExtension` → `NSExtensionPointIdentifier` =
   `com.apple.networkextension.packet-tunnel`). Keep all three.
3. The provider is a separate process with its own sandbox: put shared
   state (selected server, stats) in an **App Group** container, and add
   the group to both the app and the provider targets.
4. Add this package to the provider target too. The engine runs there,
   so `import CoreXray` must resolve in both targets.

Memory budget: providers are jetsam-limited to 50 MiB for a packet
tunnel on current iOS. The Go runtime plus referenced `.dat` files fits,
but keep `geo` OUT of the provider unless routing needs it. Plain rules
need no geodata under gate semantics, and every megabyte in the provider
is one you cannot spend elsewhere. Ship `.dat` files in the app. Copy
only referenced ones into the group container when `ensureAssets` says
the config needs them.

## Step 2. The provider start path

Order matters here. Do settings first, since the system needs routes
before traffic. Descriptor comes second, launch third, counters after.
Never write a read-packets loop. The engine owns the fd and reads it
itself.

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

        // 2. The descriptor handoff. One guarded read off the packet flow.
        //    private key-value access is the only route (no public API
        //    exposes it); re-verify every iOS release. Throws .invalidInput
        //    instead of an Obj-C exception when a key renames.
        let fd = try Xray.shared.providerFileDescriptor(from: packetFlow)

        // 3. Assemble around the fd. No local entries in TUN mode. Packets
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

        // 5. Launch under a deadline. The provider has a time budget and
        //    the sync starts have no bound. They do not belong here.
        try await session.start(config, options: opts, deadline: 20)

        // 6. Counters and stall detection, after launch. Publish to the app
        //    via the group container + Darwin notify (poll from the app).
        monitor = try Xray.shared.trafficMonitor(port: 24242)
        watchdog = try Xray.shared.trafficWatchdog(
            port: 24242, interval: 10, stalledAfter: 60
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
on current iOS. The Xray team states it as known-certain in
[XTLS/Xray-core#4422](https://github.com/XTLS/Xray-core/issues/4422),
with app proxy and DNS proxy at 15, filter control/data at 50, app push
at 24. History: 5-6 MB originally, raised to 15 MB in iOS 10 beta 2
(Psiphon's [rdar://27660401](http://www.openradar.appspot.com/27660401)),
then to 50 MB in iOS 15. The radar's own originator reported this and
closed it as resolved. There is still no API, Info.plist key, or
documented entitlement to raise it further. On stock iOS the ceiling is
system-imposed and not negotiable. A kill looks exactly like a random
disconnect, which is why providers "mysteriously drop" only in the
field. Limits are relaxed under the Xcode debugger, so you cannot
reproduce this attached. Diagnose it in `Settings → Privacy → Analytics
→ Analytics Data`: a `JetsamEvent` with reason `per-process-limit`
naming your provider is the fingerprint.

So what are the "70 MB clients"? No stock-iOS mechanism reaches past
50. A 70 MB *setting* is the client's own guard, not the system
ceiling, and the engine still dies at 50 regardless of what the UI
says. (Streisand, for one, exposes its own memory-limitation toggle in
settings. That is app-level policy, not an entitlement.) The only published
how-to for actually raising the ceiling (Nov 2022) is explicitly a
**jailbreak** method. It patches the jetsam property lists, where
per-process limits are just numbers in a plist. Anything else showing
high memory is measuring something else: the macOS provider (no such
ceiling), the containing **app** process instead of the provider, or a
debug build running relaxed. If someone offers you a stock-iOS
mechanism, ask for the entitlement string. Without one, it is one of
the above.

What remains is footprint. Geo dominates it:

Referenced categories decide the cost, not files. The engine now mmaps
a referenced `.dat` (upstream `XTLS/Xray-core#5480`, shipped in the core
we pin), so file size is no longer the bill. The unmarshalled rules are.
Scale from #4422: `geosite:ads` (749 rules) loads fine, while
`geosite:category-ads-all` (65,565 rules) and `geosite:cn` (94,767
rules) crash the tunnel. Upstream's own conclusion: on iOS only
slimmed-down geofiles survive. A full Loyalsolider `geosite.dat`
(~21 MB on disk) leaves no room for the runtime once big categories
unmarshal. `ensureAssets` fetches only referenced databases, but *you*
choose which categories the config references. Prefer `geosite:ads`
over `category-ads-all`, split regions out of `cn`, and never
reference a giant category "just in case".

Download outside the provider. Fetching inside the extension burns
transient memory (TLS buffers, decode) against the same ceiling. The
app process has gigabytes. Do all networking there, write finished
`.dat` files to the group container, and let the provider only map and
read them.

Cap the Go heap from your side. The Go runtime honors `GOMEMLIMIT`
from the process environment at startup, and the provider can `setenv`
it before the first engine call. The runtime initializes lazily on
first use. Account it: Go heap plus unmarshalled geo plus provider
overhead must stay under 50. Upstream suggests leaving ~20 MiB for the
running proxy on top of startup peak, so `GOMEMLIMIT=32MiB` is a sane
starting point. Then measure. It will not stop a leak, but it turns
unbounded growth into early, explicable failures instead of silent
jetsam kills. This is standard Go behavior, not package API. Set it in
`init()`.

Watch headroom instead of guessing. `os_proc_available_memory()` inside
the provider tells you what jetsam will allow right now. Sample it
next to traffic snapshots in beta builds. When a drop correlates with
near-zero headroom instead of a stall, you have a memory kill, not a
network failure. The fix is footprint, not reconnect logic.

Keep logging out of memory. Use a file sink with a serial queue (05).
Never accumulate lines in the provider. The 200-line ring buffer is the
only in-memory log, and it is bounded.

If memory pressure forces a choice, drop `geosite` first: inline the
handful of domains you actually route as plain strings (zero bytes) and
keep only `geoip` rules. Category blocking (`geosite:ads`) has no
zero-byte substitute. That is the file you budget for.

## Geo routing in the provider

Geo routing means rules referencing `geosite:`/`geoip:`, plus the `.dat`
files resolving them, plus `xray.location.asset` pointing at the files.
The stages split across processes on purpose:

```swift
// APP PROCESS, at subscription refresh. Gigabytes available, no rush.
// ensureAssets scans the assembled config for geosite:/geoip: references
// (routing rules AND dns hosts keys) and fetches ONLY the referenced
// databases into the group container. Unreferenced configs download
// nothing. That is the whole memory strategy.
let dir = try await Xray.shared.ensureAssets(
    for: config,                                   // scan this document
    in: groupContainer.appendingPathComponent("geo")
)
```

```swift
// PROVIDER, at launch. Point, don't fetch. The document's env map is
// applied into the engine's process at start, so this one key wires the
// whole lookup chain: engine → env → .dat files.
let opts = Xray.shared.options(
    tun: a.tun, metricsPort: 24242,
    environment: ["xray.location.asset": dir.path]
)
try await session.start(config, options: opts, deadline: 20)
```

Four rules that make it correct:

1. Sniffing is required in TUN mode. Packets arrive as raw IPs, while
   `geosite:` matches *domains*. Without SNI sniffing the engine never
   learns the domain and geosite rules silently match nothing. Always
   set `a.sniffing = Xray.shared.sniffing()` (or inherit it per-entry)
   when any domain/geosite rule exists. Proxy mode gets this from the
   inbound handshake. TUN mode does not.
2. `domainStrategy` decides how strictly domains match. `.asIs` matches
   only what sniffing/DNS recovered. `.ipIfNonMatch` falls back to IP
   (geoip) rules when no domain is known. It is the forgiving default
   for TUN. Set it on `routing()` deliberately.
3. Stage files instead of bundling them. Ship no `.dat` in the
   provider. Copy only referenced ones into the group container. A
   config update that drops the last `geosite:` rule should delete the
   file. Stale files keep consuming memory.
4. Missing files fail fast, by design. If the provider launches a
   geo-referencing config with no files at the env path, `build` throws
   `.geoAssets` naming the file. Catch it and tell the user to open the
   main app (which re-runs `ensureAssets`) instead of retrying a launch
   that cannot succeed.

## Step 3. The app side

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
// on wake. Never poll the metrics port from the app. It lives in the
// provider process on its loopback.
```

`setTunnelNetworkSettings` before launch, `deadline:` on every start,
`preflightIssues` before every launch, `watchdog` after every launch.
These four habits separate a provider that works from one that
mysteriously drops. Reconnect logic lives in `09-stay-connected.md`.
