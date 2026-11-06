import Foundation

/// The `XraySession` surface, for apps that inject a mock in their own tests.
/// `Xray.shared.newSession()` returns the real thing; declare
/// dependencies as this protocol and substitute a fake. Defaulted
/// arguments live on the extension below, so mocks only implement the
/// full forms.
public protocol XraySessionProviding {
    var logger: ((String) -> Void)? { get set }
    var connectedSince: Date? { get }

    func build(_ source: XrayConfigSource, options: XraySessionOptions?) throws -> XrayConfig
    func start(_ source: XrayConfigSource, options: XraySessionOptions?) throws
    func start(_ config: XrayConfig) throws
    func start(rawJSON json: String) throws
    func start(contentsOf url: URL) throws
    func start(_ source: XrayConfigSource, options: XraySessionOptions?) async throws
    func start(_ source: XrayConfigSource, options: XraySessionOptions?, deadline: Duration) async throws
    func start(
        remoteSubscription url: URL,
        ageSecret: String?,
        assetDirectory: URL?,
        options: XraySessionOptions?,
        deadline: Duration,
        timeoutSeconds: TimeInterval
    ) async throws
    func validate(_ source: XrayConfigSource, options: XraySessionOptions?) throws
    func validate(_ source: XrayConfigSource, options: XraySessionOptions?) async throws
    func stop() throws
    func isRunning() throws -> Bool

    func recentLogs(limit: Int) -> [String]
    func recentEngineLogs(_ kind: XrayEngineLogKind, lines: Int) throws -> [String]
    func preflightForProvider(_ source: XrayConfigSource, options: XraySessionOptions?) throws
    func preflightIssues(_ source: XrayConfigSource, options: XraySessionOptions?) throws -> [String]
}

extension XraySession: XraySessionProviding {}

extension XraySessionProviding {
    public func build(_ source: XrayConfigSource) throws -> XrayConfig {
        try build(source, options: nil)
    }

    public func start(_ source: XrayConfigSource) throws {
        try start(source, options: nil)
    }

    public func start(_ source: XrayConfigSource) async throws {
        try await start(source, options: nil)
    }

    public func validate(_ source: XrayConfigSource) throws {
        try validate(source, options: nil)
    }

    public func validate(_ source: XrayConfigSource) async throws {
        try await validate(source, options: nil)
    }

    public func recentLogs() -> [String] {
        recentLogs(limit: 200)
    }

    public func preflightForProvider(_ source: XrayConfigSource) throws {
        try preflightForProvider(source, options: nil)
    }

    public func preflightIssues(_ source: XrayConfigSource) throws -> [String] {
        try preflightIssues(source, options: nil)
    }
}
