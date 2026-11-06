# 02 — Assembling documents: proxy mode and TUN mode

The assembler turns a server description into a launchable document:
local entries, routing, DNS, logging, standards — no tag bookkeeping.
It accepts exactly two inputs (never a full document; that is `01`):

- `.shareLinks(_)` — `vless://` / `trojan://` / `ss://` / `socks://`,
  one link, many newline-separated, or a base64 blob of those.
- `.outboundJson(_)` — one outbound object
  (`{"protocol": ..., "tag": ..., ...}`), wrapped as the outbounds.

The first outbound is the `.proxy` destination everywhere.

## Part A — Proxy mode (local SOCKS/HTTP entries)

```swift
import CoreXray

let engine = Xray.shared
let session = engine.newSession { print("[xray]", $0) }

// Describe intent. Every field is optional except the source.
var a = engine.assembler(.shareLinks(pastedText))

// Local entries: this machine's apps point here. socksPort defaults to
// 10808; nil drops the entry. Ports are range-checked in the factory.
a.socks = try engine.socksEntry(port: 10880)   // 127.0.0.1:10880
a.http = try engine.httpEntry(port: 10881)     // add when you need HTTP

// Where traffic goes. .proxy is the converted server; the ads and
// private-IP rules keep local traffic local; `final` is the trailing
// catch-all rule for everything unmatched (the engine ignores any other
// "default" key, so this is the default).
a.routing = engine.routing(
    rules: [
        engine.routingRule(domains: ["geosite:ads"], destination: .block),
        engine.routingRule(ips: ["geoip:private"], destination: .direct),
    ],
    final: .proxy
)

// Verbatim sections, written as given. Log to a file: the error path is
// what the forensics reader tails later (see 05-logging.md).
a.dns = engine.dns(servers: [.plain("https://dns.google/dns-query")])
a.log = engine.log(level: .warning, error: logFile.path)

// Metrics + stats + policy, on loopback only. Counters (03) and the
// observatory read here; nothing else needs this port.
a.metricsPort = 24242

// Sniffing is inherited: entries left at nil pick this up; an entry
// with its own sniffing keeps it. DNSRelay has no sniffing of its own
// and always inherits through injection.
a.sniffing = engine.sniffing()

// Assemble, then launch. `patch` (if set) ran last inside assemble().
let config = try a.assemble()
try session.start(config)
```

One call when you need no tuning — same pipeline, defaults for entries:

```swift
let config = try engine.proxyConfiguration(
    .shareLinks(pastedText),
    remarks: "main",
    socksPort: 10808,     // nil drops the SOCKS entry
    httpPort: nil,        // set to add an HTTP entry
    routing: myRouting,
    dns: myDNS,
    log: myLog
)
try session.start(config)
```

## Part B — TUN mode (all-device traffic via a handed-off fd)

```swift
// The descriptor comes from the packet flow (07-network-extension.md).
// In TUN mode there are no local entries: packets arrive on the fd,
// so SOCKS/HTTP/DNS-relay entries would only be dead listeners.
var a = engine.assembler(.shareLinks(winnerLink))
a.socks = nil
a.dnsRelay = nil
a.tun = try engine.tun(
    // name: "utun7",              // default nil: engine picks
    gateway: ["198.18.0.1/15"],    // must match the provider's tunnel subnet
    autoSystemRoutingTable: ["0.0.0.0/0"],  // default route through the tunnel
    fileDescriptor: fd             // handed off; engine reads the fd itself
)
a.routing = engine.routing(final: .proxy)
a.metricsPort = 24242
let config = try a.assemble()

// Provider gate as values, not crashes: descriptor present, inbounds on
// loopback only. Fix the reported issues instead of catching a throw.
let opts = engine.options(
    tun: a.tun, metricsPort: 24242,
    environment: ["xray.location.asset": geoDir.path]
)
let issues = try session.preflightIssues(.json(config.json), options: opts)
guard issues.isEmpty else { throw ProviderError.misconfigured(issues) }
try await session.start(config, options: opts, deadline: .seconds(20))
```

Notes that bite in production:

- `autoOutboundsInterface: "auto"` is emitted only when a routing table
  is set without an explicit interface — pass `autoSystemRoutingTable`
  and you get the self-routing-loop protection for free.
- Assembling a descriptor-less document clears stale `xray.tun.fd` from
  the process, because the engine applies `env` but never unsets it.
- `patch` runs after everything, including the TUN env merge — inspect
  `config.json` when a key you set seems to vanish.
