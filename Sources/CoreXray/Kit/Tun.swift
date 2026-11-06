import Foundation

// Device-wide capture through the engine's own TUN inbound — the documented
// shape the published Xray clients run, not a pump around a SOCKS port.
// The engine reads packets off a TUN interface: on macOS it creates the
// interface itself from `name`, while on iOS/Android the interface belongs
// to the app or its NetworkExtension, so the provider passes its file
// descriptor through `fileDescriptor` (written into the document's `env`
// as `xray.tun.fd`, the variable Xray-core reads). There is no port and no
// auth on a TUN entry: traffic arrives as packets, not connections.

public struct XrayTunEntry: Sendable {
    /// Inbound tag routing rules match on. Defaults to "tunIn".
    public var tag: String

    /// Kept for the inbound shape only: the engine ignores `listen`
    /// (and any port) for `protocol: "tun"` — packets arrive on the
    /// interface, not a socket. Defaults to 127.0.0.1.
    public var listen: String

    /// Interface name the engine creates (e.g. "utun10"). Nil leaves the
    /// engine's default. Only used when the engine creates the interface
    /// itself (macOS); ignored when a descriptor is passed in.
    public var name: String?

    /// Interface MTU. Defaults to 1500.
    public var mtu: Int

    /// Address prefixes assigned to the interface, e.g.
    /// ["198.18.0.1/15", "fc00::1/64"]. On macOS only IPv4 takes effect.
    /// Nil leaves interface addressing to the platform.
    public var gateway: [String]?

    /// Policy level for connections through this entry. Nil means 0.
    public var userLevel: Int?

    /// XrayDestination prefixes the engine adds to the system routing table
    /// itself, e.g. ["0.0.0.0/0", "::/0"]. Nil means you route manually.
    public var autoSystemRoutingTable: [String]?

    /// XrayDNS servers the engine puts on the interface. The one engine
    /// TUN field that matters on Apple platforms (the Windows-only
    /// leak/XrayDNS helpers and the cosmetic `desc` are deliberately not
    /// exposed). Nil leaves interface XrayDNS alone.
    public var dns: [String]?

    /// Physical interface Xray's own traffic binds to, so it never loops
    /// back into the tunnel. "auto" lets the engine choose. Nil means
    /// the engine decides — including its own rule that a system
    /// routing table without an explicit interface implies "auto",
    /// which the wire object makes explicit so the document shows what
    /// the engine will do.
    public var autoOutboundsInterface: String?

    /// The TUN file descriptor from the app or NetworkExtension that owns
    /// the interface (iOS/Android). Written into the document's `env` as
    /// `xray.tun.fd`. Nil means the engine creates the interface itself
    /// (the macOS path) — no descriptor needed.
    public var fileDescriptor: Int32?

    /// Carried verbatim; nil (the default) leaves the entry without
    /// its own sniffing, so it receives the session's through the
    /// normal pipeline.
    public var sniffing: XraySniffing?

    internal init(
        tag: String = "tunIn",
        listen: String = "127.0.0.1",
        name: String? = nil,
        mtu: Int = 1500,
        gateway: [String]? = nil,
        dns: [String]? = nil,
        userLevel: Int? = nil,
        autoSystemRoutingTable: [String]? = nil,
        autoOutboundsInterface: String? = nil,
        fileDescriptor: Int32? = nil,
        sniffing: XraySniffing? = nil
    ) {
        self.tag = tag
        self.listen = listen
        self.name = name
        self.mtu = mtu
        self.gateway = gateway
        self.dns = dns
        self.userLevel = userLevel
        self.autoSystemRoutingTable = autoSystemRoutingTable
        self.autoOutboundsInterface = autoOutboundsInterface
        self.fileDescriptor = fileDescriptor
        self.sniffing = sniffing
    }

    var wireObject: XrayJSONObject {
        var settings: XrayJSONObject = ["mtu": .int(mtu)]
        if let name {
            settings["name"] = .string(name)
        }
        if let gateway {
            settings["gateway"] = .array(gateway.map(XrayJSONValue.string))
        }
        if let dns {
            settings["dns"] = .array(dns.map(XrayJSONValue.string))
        }
        if let userLevel {
            settings["userLevel"] = .int(userLevel)
        }
        if let autoSystemRoutingTable {
            settings["autoSystemRoutingTable"] = .array(autoSystemRoutingTable.map(XrayJSONValue.string))
        }
        if let autoOutboundsInterface {
            settings["autoOutboundsInterface"] = .string(autoOutboundsInterface)
        } else if let autoSystemRoutingTable, !autoSystemRoutingTable.isEmpty {
            // Mirror of the engine's own default (`TunConfig.Build` in
            // Xray-core's infra/conf/tun.go): a routing table without an
            // explicit interface implies "auto", so the wire says what
            // the engine would do anyway. Without a table the engine
            // leaves the key unset — and forcing "auto" there breaks
            // descriptor hand-off, so this does not.
            settings["autoOutboundsInterface"] = .string("auto")
        }
        var entry: XrayJSONObject = [
            "tag": .string(tag),
            "protocol": .string("tun"),
            "listen": .string(listen),
            "settings": .object(settings),
        ]
        if let sniffing {
            entry["sniffing"] = .object(sniffing.wireObject)
        }
        return entry
    }

    /// Merges this entry's descriptor into the document's `env` as
    /// `xray.tun.fd`, preserving keys already there. Pure document
    /// work: without a descriptor nothing is written and nothing is
    /// cleared. Clearing a stale descriptor left in the process by an
    /// earlier TUN session happens at launch, not here — the engine
    /// applies document `env` into its process at start and never
    /// unsets, so a stale descriptor would hijack the next fd-less
    /// launch into reading a dead fd instead of creating its own
    /// interface. See `XraySession`'s launch paths.
    func applyEnvironment(to config: inout XrayJSONObject) {
        guard let fileDescriptor else { return }
        var env = config["env"]?.objectValue ?? [:]
        env["xray.tun.fd"] = .string("\(fileDescriptor)")
        config["env"] = .object(env)
    }

    /// Both spellings the engine's environment lookup accepts.
    static func clearStaleFileDescriptor() {
        unsetenv("xray.tun.fd")
        unsetenv("XRAY_TUN_FD")
    }
}

// Value factory for the TUN entry. A negative file descriptor, a
// non-positive MTU, or an explicitly empty interface name is rejected
// here instead of failing obscurely inside the engine. Stderr and fd 0
// are the caller's responsibility to avoid: fd 0 is standard input, and
// a TUN entry inheriting it would hand the packet reader a pipe that is
// not a tunnel.
extension Xray {
    public func tun(
        tag: String = "tunIn",
        listen: String = "127.0.0.1",
        name: String? = nil,
        mtu: Int = 1500,
        gateway: [String]? = nil,
        dns: [String]? = nil,
        userLevel: Int? = nil,
        autoSystemRoutingTable: [String]? = nil,
        autoOutboundsInterface: String? = nil,
        fileDescriptor: Int32? = nil,
        sniffing: XraySniffing? = nil
    ) throws -> XrayTunEntry {
        if let fileDescriptor, fileDescriptor < 0 {
            throw XrayError.invalidInput("tun fileDescriptor must be non-negative, got \(fileDescriptor)")
        }
        if mtu <= 0 {
            throw XrayError.invalidInput("tun mtu must be positive, got \(mtu)")
        }
        if let autoOutboundsInterface, autoOutboundsInterface.isEmpty {
            throw XrayError.invalidInput("tun autoOutboundsInterface must be non-empty when set: \"\" means nothing to the engine, so leave it nil")
        }
        return XrayTunEntry(
            tag: tag, listen: listen, name: name, mtu: mtu, gateway: gateway,
            dns: dns, userLevel: userLevel, autoSystemRoutingTable: autoSystemRoutingTable,
            autoOutboundsInterface: autoOutboundsInterface,
            fileDescriptor: fileDescriptor, sniffing: sniffing
        )
    }
}

// The provider's utun descriptor, read off the packet flow.
extension Xray {
    /// Reads the file descriptor of the utun interface backing a packet
    /// tunnel provider's flow, for handing to `tun(fileDescriptor:)`. The
    /// flow object hides it, so this walks the same key path the community
    /// has used for years — verified per iOS release, never assumed. Each
    /// hop is capability-checked first, so a renamed key throws
    /// `.invalidInput` instead of tripping an Objective-C exception.
    /// There is no public API for this value — NetworkExtension simply
    /// does not expose the descriptor — so private key-value access is
    /// the only route, and a future OS or review pass could object to
    /// it: keep the call isolated here and re-verify every release. The
    /// public-API alternative — scanning fds 0…1024 with
    /// `getsockopt(..., UTUN_OPT_IFNAME)` — was deliberately not chosen:
    /// it fires a thousand syscalls per launch and races with concurrent
    /// fd churn elsewhere in the process. One guarded read is steadier.
    public func providerFileDescriptor(from packetFlow: NSObject) throws -> Int32 {
        guard packetFlow.responds(to: NSSelectorFromString("socket")),
              let socket = packetFlow.value(forKey: "socket") as? NSObject,
              socket.responds(to: NSSelectorFromString("fileDescriptor")),
              let raw = socket.value(forKey: "fileDescriptor") else {
            throw XrayError.invalidInput(
                "could not read the provider utun file descriptor: the flow object has no socket.fileDescriptor"
            )
        }
        let fd: Int32
        if let number = raw as? NSNumber {
            fd = number.int32Value
        } else if let direct = raw as? Int32 {
            fd = direct
        } else {
            throw XrayError.invalidInput(
                "the provider utun file descriptor has an unexpected type and cannot be handed to the engine"
            )
        }
        guard fd >= 0 else {
            throw XrayError.invalidInput("the provider utun file descriptor is negative (\(fd))")
        }
        return fd
    }
}
