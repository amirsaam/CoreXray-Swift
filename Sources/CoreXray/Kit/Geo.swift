import Foundation

// GeoIP/GeoSite database files: inventorying the ones you have, and fetching
// the ones you don't.

/// Which database a file holds. Mirrors the filenames apps deal with:
/// `geosite.dat` catalogues hostnames, `geoip.dat` IP ranges.
public enum XrayGeoDatabase: String, Sendable {
    case geosite
    case geoip

    /// How the engine spells it on the wire and in output filenames.
    var engineName: String {
        switch self {
        case .geosite: return "domain"
        case .geoip: return "ip"
        }
    }
}

/// Configure the URLs before the first download, then treat the instance
/// as read-only: concurrent downloads are safe, concurrent
/// reconfiguration is not.
///
/// URLs may be `https` (production) or `file` (tests and offline packs) —
/// anything `URLSession` downloads. Redirects are followed by the
/// transport (the default Loyalsoldier "latest/download" links are
/// redirects); authentication is not: a source behind auth needs a URL
/// whose response is already authorized (signed link), because no
/// headers or delegates are attached. Downloads trust the transport's
/// TLS — a compromised source ships a compromised database, and the
/// gate only checks shape, not signature, so pin sources you trust.
public final class XrayGeoDownloader: @unchecked Sendable {
    /// Default source for the IP database.
    public static let defaultGeoIPURL: URL = {
        guard let url = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat") else {
            preconditionFailure("bundled default GeoIP URL is malformed")
        }
        return url
    }()

    /// Default source for the site database.
    public static let defaultGeoSiteURL: URL = {
        guard let url = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat") else {
            preconditionFailure("bundled default GeoSite URL is malformed")
        }
        return url
    }()

    /// Default source for the IP database. Lock-guarded: swapping
    /// sources mid-download races the in-flight request, so treat both
    /// URLs as set-once configuration.
    public var geoIPURL: URL {
        get { stateLock.withLock { _geoIPURL } }
        set { stateLock.withLock { _geoIPURL = newValue } }
    }
    private var _geoIPURL: URL

    /// Default source for the site database.
    public var geoSiteURL: URL {
        get { stateLock.withLock { _geoSiteURL } }
        set { stateLock.withLock { _geoSiteURL = newValue } }
    }
    private var _geoSiteURL: URL

    /// Transport for downloads. `URLSession.shared` in production;
    /// tests swap in a stubbed configuration. Set once before the first
    /// download — access is lock-guarded, but swapping it mid-download
    /// races the in-flight request, so treat it as set-once
    /// configuration.
    internal var urlSession: URLSession {
        get { stateLock.withLock { _urlSession } }
        set { stateLock.withLock { _urlSession = newValue } }
    }
    private var _urlSession: URLSession = .shared
    private let stateLock = NSLock()
    /// Serializes the stage-then-replace window across concurrent
    /// fetches of the same file, so two upgrades can never interleave
    /// a remove between the other's stage and move.
    private static let replaceLock = NSLock()

    internal init(
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil
    ) {
        self._geoIPURL = geoIPURL ?? Self.defaultGeoIPURL
        self._geoSiteURL = geoSiteURL ?? Self.defaultGeoSiteURL
    }

    /// Downloads both databases into `directory`, creating it as needed
    /// and replacing same-named files — atomically: each file downloads
    /// to a uniquely-named staging sibling and moves into place only
    /// after the bytes land, so a kill between downloads never destroys
    /// the file that was already good. Progress runs 0.0 to 1.0 across
    /// both files; `onProgress` is called on the main actor and is
    /// optional.
    public func download(
        into directory: URL,
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw XrayError.bridgeFailed("could not create the geo directory \(directory.path): \(error.localizedDescription)")
        }
        let ipSource = geoIPURL ?? self.geoIPURL
        let siteSource = geoSiteURL ?? self.geoSiteURL
        let tracker = ProgressTracker(report: onProgress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.fetch(from: ipSource, to: directory.appendingPathComponent("geoip.dat")) { fraction in
                    tracker.setIP(fraction)
                }
            }
            group.addTask {
                try await self.fetch(from: siteSource, to: directory.appendingPathComponent("geosite.dat")) { fraction in
                    tracker.setSite(fraction)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Downloads only the databases in `databases` that are missing or
    /// unreadable in `directory`, creating it as needed. Unlike
    /// `download(into:)`, files already present are left alone.
    /// Progress across the fetched files runs 0.0 to 1.0 when
    /// `onProgress` is set — this is the upkeep path `ensureAssets`
    /// uses, not the first-fetch path.
    func fetchMissing(
        _ databases: [XrayGeoDatabase],
        into directory: URL,
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw XrayError.bridgeFailed("could not create the geo directory \(directory.path): \(error.localizedDescription)")
        }
        var wanted: Set<XrayGeoDatabase> = []
        for database in databases {
            let path = directory.appendingPathComponent("\(database.rawValue).dat").path
            if !XrayGeoAssets.verify(at: path) {
                wanted.insert(database)
            }
        }
        guard !wanted.isEmpty else { return }
        let ipSource = geoIPURL ?? self.geoIPURL
        let siteSource = geoSiteURL ?? self.geoSiteURL
        let tracker = ProgressTracker(report: onProgress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            if wanted.contains(.geoip) {
                group.addTask {
                    try await self.fetch(from: ipSource, to: directory.appendingPathComponent("geoip.dat")) { fraction in
                        tracker.setIP(fraction)
                    }
                }
            }
            if wanted.contains(.geosite) {
                group.addTask {
                    try await self.fetch(from: siteSource, to: directory.appendingPathComponent("geosite.dat")) { fraction in
                        tracker.setSite(fraction)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Private

    private func fetch(
        from url: URL,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Atomic by construction: the previous good file stays in place
        // until the new bytes fully land in a staging sibling. A kill
        // mid-download leaves the old database (or nothing at all),
        // never a truncated one the gate would then refuse.
        //
        // The staging name is unique per call: two concurrent fetches of
        // the same destination (two sessions bootstrapping one directory)
        // stage side by side and serialize only at the replace step, so
        // neither fails on the other's staging file. Last writer wins;
        // both wrote bytes that passed the same gate, so either outcome
        // is a good database. Stale staging siblings from a kill are
        // swept below, best effort.
        Self.sweepStagingSiblings(of: destination)
        let staging = destination.appendingPathExtension("part-\(UUID().uuidString.prefix(8))")
        let current = DownloadTaskBox()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    var observation: NSKeyValueObservation?
                    let task = urlSession.downloadTask(with: URLRequest(url: url)) { tempURL, response, error in
                        observation?.invalidate()
                        if let error {
                            continuation.resume(throwing: Self.downloadError(error, url: url))
                            return
                        }
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                            continuation.resume(throwing: XrayError.bridgeFailed(
                                "download of \(url.absoluteString) failed with HTTP \(code)"))
                            return
                        }
                        guard let tempURL else {
                            continuation.resume(throwing: XrayError.bridgeFailed(
                                "download of \(url.absoluteString) finished without a file"))
                            return
                        }
                        do {
                            try FileManager.default.moveItem(at: tempURL, to: staging)
                            // The old file is removed only after the new one is
                            // staged — and under the lock, so a concurrent
                            // fetch of the same file never interleaves a
                            // remove between another's stage and move.
                            try Self.replaceLock.withLock {
                                try? FileManager.default.removeItem(at: destination)
                                try FileManager.default.moveItem(at: staging, to: destination)
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: Self.downloadError(error, url: url))
                        }
                    }
                    observation = task.progress.observe(\.fractionCompleted) { value, _ in
                        Task { @MainActor in progress(value.fractionCompleted) }
                    }
                    current.task = task
                    // Already cancelled while setting up: stop before leaving
                    // a download running that nobody awaits.
                    if Task.isCancelled { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                current.task?.cancel()
            }
        } catch {
            // Our own staging sibling never survives a failure: without
            // cleanup every failed night would leave another orphan.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Removes staging siblings `<name>.dat.part-*` left by a killed
    /// download. Best effort: a directory we cannot list is not worth
    /// failing the download over.
    private static func sweepStagingSiblings(of destination: URL) {
        let directory = destination.deletingLastPathComponent()
        let prefix = destination.lastPathComponent + ".part-"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items where item.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    /// Translates transport and filesystem failures into the package's
    /// error type: timeouts surface as `.timedOut`, everything else as
    /// `.bridgeFailed` naming the URL. `XrayError` and cooperative
    /// cancellation pass through untouched — a caller cancel is never a
    /// download failure.
    private static func downloadError(_ error: Error, url: URL) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return XrayError.timedOut("download of \(url.absoluteString) timed out")
            default:
                return XrayError.bridgeFailed(
                    "download of \(url.absoluteString) failed: \(urlError.localizedDescription)")
            }
        }
        if error is XrayError { return error }
        return XrayError.bridgeFailed(
            "download of \(url.absoluteString) failed: \(error.localizedDescription)")
    }
}

/// Fail-fast check for the geo databases a configuration depends on.
/// The engine resolves `geosite:` / `geoip:` entries lazily at traffic
/// time, so a missing file turns into broken routing at runtime —
/// `validate()` passes and the user's requests silently dead-end. The
/// gate runs during `XraySession.build` / `validate` / `start` (turn it off
/// with `XraySessionOptions.geoCheck`) and refuses to launch when a rule references
/// a database the engine will not find.
///
/// Plain domains and IPs never require a database; the check exists only
/// for references like `geosite:category-ads` or `geoip:private`.
public enum XrayGeoAssets: Sendable {
    /// Directory lookup, mirroring the engine's own search
    /// (`GetAssetLocation` in Xray-core's `common/platform`, verified
    /// at v26.10.31): the document's `env` and the process environment
    /// fold through the same lookup, dotted spelling
    /// (`xray.location.asset`) before the underscore one
    /// (`XRAY_LOCATION_ASSET`), then the engine's fixed fallbacks
    /// (`/usr/local/share/xray`, `/usr/share/xray`, `/opt/share/xray`).
    /// The executable's directory is the engine's default only when no
    /// location is set anywhere, so it is appended only when nothing
    /// else named a directory. `/usr/local/etc/xray` is deliberately
    /// absent: the engine never looks there. Returns nothing when none
    /// of the sources apply — lookup locations are reported in the
    /// thrown error instead.
    static func candidateDirectories(env: XrayJSONObject?) -> [String] {
        var directories: [String] = []
        // Pair each spelling's sources with the dotted one first: the
        // engine's `EnvFlag` lookup tries the dotted name (from the
        // document or the process, whichever set it) before the
        // underscore one, so the gate checks in that order.
        for key in ["xray.location.asset", "XRAY_LOCATION_ASSET"] {
            if let asset = env?[key]?.stringValue, !asset.isEmpty, !directories.contains(asset) {
                directories.append(asset)
            }
            if let value = getenv(key).map({ String(cString: $0) }), !value.isEmpty, !directories.contains(value) {
                directories.append(value)
            }
        }
        for fixed in ["/usr/local/share/xray", "/usr/share/xray", "/opt/share/xray"] where !directories.contains(fixed) {
            directories.append(fixed)
        }
        // Last resort, and only when nothing else named a directory:
        // with a location set the engine never searches the
        // executable's directory.
        if directories.isEmpty,
           let executable = Bundle.main.executableURL?.deletingLastPathComponent().path,
           !executable.isEmpty {
            directories.append(executable)
        }
        return directories
    }

    /// Walks a subtree collecting geo references. XrayDNS `hosts` objects
    /// carry references as keys (`"geosite:malware": "127.0.0.1"`), so
    /// both keys and values are considered. For `ext:` references see
    /// `referencedExternalFiles`.
    static func referenced(in config: XrayJSONObject) -> [XrayGeoDatabase] {
        collected(in: config).names.compactMap(XrayGeoDatabase.init)
    }

    /// External data files named by `ext:` references
    /// (`"ext:custom.dat:tag"` → `"custom.dat"`), sorted. These are not
    /// `XrayGeoDatabase` cases — the engine loads them by filename — so
    /// they travel separately into `check(externalFiles:env:)`.
    static func referencedExternalFiles(in config: XrayJSONObject) -> [String] {
        collected(in: config).files.sorted()
    }

    /// Single walk over the routing and dns sections, gathering both
    /// `geosite:`/`geoip:` names and `ext:` filenames.
    private static func collected(in config: XrayJSONObject) -> (names: Set<String>, files: Set<String>) {
        var names: Set<String> = []
        var files: Set<String> = []
        for section in ["routing", "dns"] {
            collect(from: config[section], into: &names, files: &files)
        }
        return (names, files)
    }

    /// The database name in a string like `"geosite:category-ads"`.
    private static func database(named text: String) -> String? {
        for database in ["geosite", "geoip"] where text.hasPrefix("\(database):") {
            return database
        }
        return nil
    }

    /// The data file in an `ext:` reference (`"ext:custom.dat:tag"` →
    /// `"custom.dat"`): the filename sits between the prefix and the
    /// final colon. A value with no second colon is a bare filename. An
    /// empty filename (`"ext::tag"`) is kept as `""` rather than dropped,
    /// so the gate rejects it with a naming-the-typo error instead of
    /// passing a document the engine will fail on. Filenames with
    /// several colons split at the last one — the engine's prefix/file
    /// split assumes the same shape, so avoid colons in `ext:` filenames.
    static func externalFile(named text: String) -> String? {
        guard text.hasPrefix("ext:") else { return nil }
        let rest = String(text.dropFirst(4))
        if let last = rest.lastIndex(of: ":") {
            return String(rest[..<last])
        }
        return rest.isEmpty ? "" : rest
    }

    private static func collect(from value: XrayJSONValue?, into names: inout Set<String>, files: inout Set<String>) {
        switch value {
        case .string(let text):
            if let named = database(named: text) {
                names.insert(named)
            } else if let file = externalFile(named: text) {
                files.insert(file)
            }
        case .array(let items):
            for item in items {
                collect(from: item, into: &names, files: &files)
            }
        case .object(let entries):
            for (key, entry) in entries {
                if let named = database(named: key) {
                    names.insert(named)
                } else if let file = externalFile(named: key) {
                    files.insert(file)
                }
                collect(from: entry, into: &names, files: &files)
            }
        default:
            break
        }
    }

    /// Verifies every referenced database exists and parses near the
    /// engine. Both databases start with the same protobuf framing byte
    /// (field 1, wiretype 2), which catches the realistic corruptions:
    /// zero-byte leftovers and HTML error pages saved as `.dat`. It
    /// cannot catch a swapped pair — both files share the framing byte,
    /// so keep filenames straight. Throws `XrayError.geoAssets` naming
    /// the database and every directory that was searched.
    static func check(referenced databases: [XrayGeoDatabase], env: XrayJSONObject?) throws {
        guard !databases.isEmpty else { return }
        let directories = candidateDirectories(env: env)
        for database in databases {
            var searched: [String] = []
            var found = false
            for directory in directories {
                let path = (directory as NSString).appendingPathComponent("\(database.rawValue).dat")
                searched.append(path)
                if verify(at: path) {
                    found = true
                    break
                }
            }
            guard found else {
                throw XrayError.geoAssets("""
                the configuration references '\(database.rawValue)' but no readable \(database.rawValue).dat was found at: \
                \(searched.joined(separator: ", ")). Download the database with XrayGeoDownloader into one of those \
                directories, or pass xray.location.asset through XraySessionOptions.environment.
                """)
            }
        }
    }

    /// Verifies every `ext:`-referenced data file exists and reads like
    /// a database. Bare filenames are searched in the candidate
    /// directories; absolute paths are checked where they point.
    /// Throws `XrayError.geoAssets` naming the file, like `check`.
    static func check(externalFiles files: [String], env: XrayJSONObject?) throws {
        guard !files.isEmpty else { return }
        let directories = candidateDirectories(env: env)
        for file in files {
            guard !file.isEmpty else {
                throw XrayError.geoAssets(
                    "the configuration references an 'ext:' entry with no filename (e.g. 'ext::tag'): put the data filename between the colons"
                )
            }
            if file.hasPrefix("/") {
                guard verify(at: file) else {
                    throw XrayError.geoAssets("the configuration references external data file '\(file)' but it is not a readable file there")
                }
                continue
            }
            var searched: [String] = []
            var found = false
            for directory in directories {
                let path = (directory as NSString).appendingPathComponent(file)
                searched.append(path)
                if verify(at: path) {
                    found = true
                    break
                }
            }
            guard found else {
                throw XrayError.geoAssets("""
                the configuration references external data file '\(file)' but no readable copy was found at: \
                \(searched.joined(separator: ", ")). Place a copy of it in one of those directories \
                (external files are not downloadable), or pass its folder through xray.location.asset.
                """)
            }
        }
    }

    /// A database counts as readable when it exists and opens with a
    /// well-formed protobuf first field: tag `0x0A` (field 1,
    /// wiretype 2), then a varint length the file actually holds.
    /// Catching the length matters: a newline-prefixed text file
    /// (`0x0A` plus ASCII) passes a first-byte check and then fails at
    /// traffic time, and a truncated download passes it too. Both files
    /// share the framing, so this still cannot catch a swapped pair —
    /// keep filenames straight.
    static func verify(at path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let header = file.readData(ofLength: 12)
        guard header.count >= 2, header[header.startIndex] == 0x0A else { return false }
        // Parse the varint length after the tag: up to 10 bytes, stop at
        // the first byte without the continuation bit.
        var length = 0
        var shift = 0
        var index = header.startIndex + 1
        var lengthBytes = 0
        while index < header.endIndex, lengthBytes < 10 {
            let byte = header[index]
            length |= Int(byte & 0x7F) << shift
            shift += 7
            lengthBytes += 1
            index += 1
            if byte & 0x80 == 0 {
                guard length > 0 else { return false }
                let rest = header.count - (index - header.startIndex)
                if rest >= length { return true }
                // Header too short to hold the first field: fall back to
                // the file size — a real database dwarfs its first field.
                guard let size = try? file.seekToEnd(), size >= UInt64(1 + lengthBytes + length) else { return false }
                return true
            }
        }
        return false
    }
}

extension Xray {

    /// Writes a human-readable inventory of a GeoIP or GeoSite database file.
    /// The summary lands next to the database at `<directory>/<database>.json`
    /// (the engine's own doing — it appends `.json`, not `.txt`), listing
    /// every code/region with its rule and category counts. Returns that
    /// file's URL.
    ///
    /// - Parameters:
    ///   - database: the database name without extension, e.g. "geosite".
    ///   - kind: what the database describes.
    ///   - directory: the folder holding the `.dat` file.
    public func writeGeoInventory(
        database: String,
        kind: XrayGeoDatabase,
        in directory: URL
    ) throws -> URL {
        try GeoCalls.writeInventory(database: database, kind: kind, directory: directory)
    }
}

/// Fetches `geoip.dat` / `geosite.dat` into a directory, concurrently, with
/// combined progress. Defaults point at the lightweight rule sets VPN apps
/// usually ship; pass your own URLs to override either file.
///
/// ```swift
/// let downloader = Xray.shared.geoDownloader()
/// try await downloader.download(into: dataDir) { print($0) }
/// ```

/// Holds the in-flight download task so cooperative cancellation can
/// reach it: `URLSession.downloadTask` only learns about a cancel
/// through the task object. Lock-disciplined; the box outlives the
/// assignment race between setup and `onCancel`.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionTask?

    var task: URLSessionTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
}

/// Averages per-file fractions into one number. Thread-safe for the two
/// concurrent download tasks reporting in.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var ip: Double = 0
    private var site: Double = 0
    private let report: ((Double) -> Void)?

    init(report: ((Double) -> Void)?) {
        self.report = report
    }

    func setIP(_ fraction: Double) {
        update(ip: fraction, site: nil)
    }

    func setSite(_ fraction: Double) {
        update(ip: nil, site: fraction)
    }

    private func update(ip: Double?, site: Double?) {
        lock.lock()
        if let ip { self.ip = ip }
        if let site { self.site = site }
        let total = (self.ip + self.site) / 2
        // KVO fraction updates fire per packet — reporting every one
        // would hop to the main actor hundreds of times per second for
        // a number the UI rounds to a percent. Report on 1% movement
        // and always on completion.
        let shouldReport = total >= 1.0 || abs(total - lastReported) >= 0.01
        if shouldReport { lastReported = total }
        lock.unlock()
        if shouldReport { report?(total) }
    }
    private var lastReported: Double = 0
}

// MARK: - Geo asset gate

// Value factory for the geo downloader.
extension Xray {
    public func geoDownloader(geoIPURL: URL? = nil, geoSiteURL: URL? = nil) -> XrayGeoDownloader {
        XrayGeoDownloader(geoIPURL: geoIPURL, geoSiteURL: geoSiteURL)
    }
}

// Asset bootstrapping: fetch only what the launch needs.
extension Xray {
    /// Makes sure every geo database the launch needs is present and
    /// readable in `directory`, downloading only what is missing or
    /// corrupt, then returns the directory for `options(environment:)`.
    /// Pass the values you assemble with: references are scanned from the
    /// assembled `XrayConfig` when given, and the engine's fixed search order
    /// (document env, process env, fixed fallbacks, executable directory
    /// as a last resort) means a document
    /// that needs no `geosite:`/`geoip:` rule needs no download at all.
    /// Unlike `XrayGeoDownloader.download(into:)`, files already present are
    /// never refetched. A configuration that is given but does not parse
    /// throws instead of downloading: garbage in must not become
    /// two downloads.
    public func ensureAssets(
        for config: XrayConfig? = nil,
        databases: [XrayGeoDatabase]? = nil,
        in directory: URL,
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil
    ) async throws -> URL {
        let needed: [XrayGeoDatabase]
        if let databases {
            needed = databases
        } else if let config {
            guard let document = try? JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8)),
                  let object = document.objectValue else {
                throw XrayError.invalidInput(
                    "ensureAssets could not parse the configuration as JSON: pass databases explicitly or fix the document"
                )
            }
            needed = XrayGeoAssets.referenced(in: object)
        } else {
            needed = [.geosite, .geoip]
        }
        try await geoDownloader().fetchMissing(needed, into: directory, geoIPURL: geoIPURL, geoSiteURL: geoSiteURL)
        return directory
    }

    /// Test seam for `ensureAssets`: same scan, but the fetch runs through
    /// your downloader — point its `urlSession` at a stubbed configuration
    /// and no packet leaves the machine.
    internal func ensureAssets(
        for config: XrayConfig? = nil,
        databases: [XrayGeoDatabase]? = nil,
        in directory: URL,
        downloader: XrayGeoDownloader
    ) async throws -> URL {
        let needed: [XrayGeoDatabase]
        if let databases {
            needed = databases
        } else if let config {
            guard let document = try? JSONDecoder().decode(XrayJSONValue.self, from: Data(config.json.utf8)),
                  let object = document.objectValue else {
                throw XrayError.invalidInput(
                    "ensureAssets could not parse the configuration as JSON: pass databases explicitly or fix the document"
                )
            }
            needed = XrayGeoAssets.referenced(in: object)
        } else {
            needed = [.geosite, .geoip]
        }
        try await downloader.fetchMissing(needed, into: directory)
        return directory
    }
}
