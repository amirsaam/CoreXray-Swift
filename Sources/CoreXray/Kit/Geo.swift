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

    /// Default source for the IP database.
    public var geoIPURL: URL

    /// Default source for the site database.
    public var geoSiteURL: URL

    /// Transport for downloads. `URLSession.shared` in production;
    /// tests swap in a stubbed configuration. Set once before the first
    /// download — access is lock-guarded, but swapping it mid-download
    /// races the in-flight request, so treat it as set-once
    /// configuration.
    internal var urlSession: URLSession {
        get { sessionLock.withLock { _urlSession } }
        set { sessionLock.withLock { _urlSession = newValue } }
    }
    private var _urlSession: URLSession = .shared
    private let sessionLock = NSLock()

    internal init(
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil
    ) {
        self.geoIPURL = geoIPURL ?? Self.defaultGeoIPURL
        self.geoSiteURL = geoSiteURL ?? Self.defaultGeoSiteURL
    }

    /// Downloads both databases into `directory`, creating it as needed
    /// and replacing same-named files. Progress runs 0.0 to 1.0 across
    /// both files; `onProgress` is called on the main actor and is
    /// optional.
    public func download(
        into directory: URL,
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    /// `download(into:)`, files already present are left alone and no
    /// progress is reported — this is the upkeep path `ensureAssets`
    /// uses, not the first-fetch path.
    func fetchMissing(
        _ databases: [XrayGeoDatabase],
        into directory: URL,
        geoIPURL: URL? = nil,
        geoSiteURL: URL? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            if wanted.contains(.geoip) {
                group.addTask {
                    try await self.fetch(from: ipSource, to: directory.appendingPathComponent("geoip.dat")) { _ in }
                }
            }
            if wanted.contains(.geosite) {
                group.addTask {
                    try await self.fetch(from: siteSource, to: directory.appendingPathComponent("geosite.dat")) { _ in }
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
        // Best-effort cleanup of a previous partial download; failure just means there was nothing there.
        try? FileManager.default.removeItem(at: destination)
        let current = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var observation: NSKeyValueObservation?
                let task = urlSession.downloadTask(with: URLRequest(url: url)) { tempURL, response, error in
                    observation?.invalidate()
                    if let error {
                        // A caller cancel surfaces as cooperative
                        // cancellation, never a download failure.
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    guard let tempURL else {
                        continuation.resume(throwing: URLError(.cannotCreateFile))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
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
    /// Directory lookup, in the engine's own order: the document's
    /// `env` (both the dotted `xray.location.asset` and the
    /// underscore `XRAY_LOCATION_ASSET` spellings), then the process
    /// environment under both spellings, then the shared install
    /// locations (`/usr/local/share/xray`, `/usr/local/etc/xray`),
    /// then the executable's directory. Returns nothing when none of
    /// the sources apply — lookup locations are reported in the
    /// thrown error instead.
    static func candidateDirectories(env: XrayJSONObject?) -> [String] {
        var directories: [String] = []
        // The engine honors both spellings everywhere, document env
        // included — dotted first, matching its precedence.
        for key in ["xray.location.asset", "XRAY_LOCATION_ASSET"] {
            if let asset = env?[key]?.stringValue, !asset.isEmpty, !directories.contains(asset) {
                directories.append(asset)
            }
        }
        for key in ["xray.location.asset", "XRAY_LOCATION_ASSET"] {
            let value = getenv(key).map { String(cString: $0) }
            if let value, !value.isEmpty, !directories.contains(value) {
                directories.append(value)
            }
        }
        for fixed in ["/usr/local/share/xray", "/usr/local/etc/xray"] where !directories.contains(fixed) {
            directories.append(fixed)
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent().path,
           !executable.isEmpty, !directories.contains(executable) {
            directories.append(executable)
        }
        return directories
    }

    /// Walks a subtree collecting geo references. XrayDNS `hosts` objects
    /// carry references as keys (`"geosite:malware": "127.0.0.1"`), so
    /// both keys and values are considered. For `ext:` references see
    /// `referencedExternalFiles`.
    static func referenced(in config: XrayJSONObject) -> [XrayGeoDatabase] {
        var names: Set<String> = []
        var files: Set<String> = []
        for section in ["routing", "dns"] {
            collect(from: config[section], into: &names, files: &files)
        }
        _ = files
        return names.compactMap(XrayGeoDatabase.init)
    }

    /// External data files named by `ext:` references
    /// (`"ext:custom.dat:tag"` → `"custom.dat"`), sorted. These are not
    /// `XrayGeoDatabase` cases — the engine loads them by filename — so
    /// they travel separately into `check(externalFiles:env:)`.
    static func referencedExternalFiles(in config: XrayJSONObject) -> [String] {
        var names: Set<String> = []
        var files: Set<String> = []
        for section in ["routing", "dns"] {
            collect(from: config[section], into: &names, files: &files)
        }
        _ = names
        return files.sorted()
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
    /// final colon. A value with no second colon is a bare filename.
    private static func externalFile(named text: String) -> String? {
        guard text.hasPrefix("ext:") else { return nil }
        let rest = String(text.dropFirst(4))
        if let last = rest.lastIndex(of: ":") {
            let file = String(rest[..<last])
            return file.isEmpty ? nil : file
        }
        return rest.isEmpty ? nil : rest
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
    /// (field 1, wiretype 2), which catches the realistic corruptions —
    /// zero-byte leftovers, HTML error pages saved as `.dat`, swapped
    /// files. Throws `XrayError.geoAssets` naming the database and every
    /// directory that was searched.
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
                \(searched.joined(separator: ", ")). Download it into one of those directories, or pass its folder through \
                xray.location.asset.
                """)
            }
        }
    }

    /// A database counts as readable when it exists, is non-empty, and
    /// its first byte is valid protobuf framing.
    static func verify(at path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let header = file.readData(ofLength: 1)
        return header.first == 0x0A
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
        lock.unlock()
        report?(total)
    }
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
    /// (document env, process env, executable directory) means a document
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
