# 08 — Subscriptions: from URL to running engine

Panels serve server lists as text at a URL: one share link per line, a
single link, a base64 blob — or, for panels that encrypt, an Age-armored
blob. Three stages, three calls, nothing cached between launches.

## Step 1 — Fetch

```swift
// Plain HTTP. Your code owns policy: timeout, ETag/If-Modified-Since,
// polling schedule. The package never phones home between launches.
var request = URLRequest(url: subscriptionURL)
request.timeoutInterval = 30
let (data, _) = try await URLSession.shared.data(for: request)
let cipher = String(decoding: data, as: UTF8.self)
```

## Step 2 — Unwrap

```swift
// Age-decrypt when the panel encrypts; ANY other text passes through
// unchanged, so calling it unconditionally is safe. It does not parse
// links and does not base64-decode — that is the next step's job.
let plain = try engine.decodeSubscription(cipher, ageSecret: ageSecretOrNil)
```

The `AGE-SECRET-KEY-...` string comes from the panel alongside the URL.
No secret and no armor header → the text returns as-is.

## Step 3 — Parse and launch

```swift
// Links become outbounds through the engine's converter. Keeps vless,
// trojan, ss, socks (and base64 blobs of those); drops vmess,
// hysteria2, wireguard, and raw {"outbounds":[...]} JSON. A feed of
// only dropped kinds throws "no valid outbound found" — surface that
// as "no supported servers in this subscription", not a crash.
let config = try engine.configuration(.shareLinks(plain))

// Geo top-up when routing references it, then launch:
if routingNeedsGeo {
    let dir = try await engine.ensureAssets(for: config, in: geoDir)
    try await session.start(config, options: engine.options(
        environment: ["xray.location.asset": dir.path],
        metricsPort: 24242
    ))
} else {
    try await session.start(config)
}
```

## The one-call variant

Fetch, unwrap, top up geo assets, launch under a deadline — every time,
fresh, nothing stored. Feeds are capped at the engine's 16 MiB limit and
the fetch at 30 seconds; anything bigger or slower is treated as wrong:

```swift
try await session.start(
    remoteSubscription: subscriptionURL,
    ageSecret: ageSecretOrNil,
    assetDirectory: geoDir,
    options: engine.options(metricsPort: 24242),
    deadline: 30,
    timeoutSeconds: 30
)
```

Prefer the manual three stages when the UI needs the server list (names,
ping ranking — see `06-ping.md`); prefer the one-call form for "just
reconnect to the subscription" buttons. Asset-directory precedence inside
the one-call form: your `options.environment` first, then an
`xray.location.asset` the feed text itself carries, then `assetDirectory` —
so a feed that pins its own asset path wins over the directory you pass.

## Single-link input

A lone `vless://...` pasted by the user is a one-line feed — same path,
no special case:

```swift
try engine.validate(.shareLinks(pasted))   // cheapest bad-input rejection
let config = try engine.configuration(.shareLinks(pasted))
```

`remarks` from the link's `#fragment` survive conversion and land in the
document — that is the server name your list shows.
