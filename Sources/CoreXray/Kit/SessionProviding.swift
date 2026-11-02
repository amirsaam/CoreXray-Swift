import Foundation

extension Xray {
    /// The `Session` surface, for apps that inject a mock in their own tests.
    /// `Xray.shared.newSession()` returns the real thing; declare
    /// dependencies as this protocol and substitute a fake. Defaulted
    /// arguments live on the extension below, so mocks only implement the
    /// full forms.
    public protocol XraySessionProviding {
        var logger: ((String) -> Void)? { get set }
        var connectedSince: Date? { get }

        func build(_ source: Xray.Config.Source, options: Xray.Session.Options?) throws -> Xray.Config
        func start(_ source: Xray.Config.Source, options: Xray.Session.Options?) throws
        func start(_ config: Xray.Config) throws
        func start(rawJSON json: String) throws
        func start(contentsOf url: URL) throws
        func start(_ source: Xray.Config.Source, options: Xray.Session.Options?) async throws
        func start(_ source: Xray.Config.Source, options: Xray.Session.Options?, deadline: Duration) async throws
        func start(
            remoteSubscription url: URL,
            ageSecret: String?,
            assetDirectory: URL?,
            options: Xray.Session.Options?,
            deadline: Duration,
            timeoutSeconds: TimeInterval
        ) async throws
        func validate(_ source: Xray.Config.Source, options: Xray.Session.Options?) throws
        func validate(_ source: Xray.Config.Source, options: Xray.Session.Options?) async throws
        func stop() throws
        func isRunning() throws -> Bool

        func recentLogs(limit: Int) -> [String]
        func recentEngineLogs(_ kind: Xray.Session.EngineLogKind, lines: Int) throws -> [String]
        func preflightForProvider(_ source: Xray.Config.Source, options: Xray.Session.Options?) throws
        func preflightIssues(_ source: Xray.Config.Source, options: Xray.Session.Options?) throws -> [String]
    }

    /// The real thing. Every requirement is already satisfied by `Session`'s
    /// public surface with identical signatures.
}

extension Xray.Session: Xray.XraySessionProviding {}

extension Xray.XraySessionProviding {
    public func build(_ source: Xray.Config.Source) throws -> Xray.Config {
        try build(source, options: nil)
    }

    public func start(_ source: Xray.Config.Source) throws {
        try start(source, options: nil)
    }

    public func start(_ source: Xray.Config.Source) async throws {
        try await start(source, options: nil)
    }

    public func validate(_ source: Xray.Config.Source) throws {
        try validate(source, options: nil)
    }

    public func validate(_ source: Xray.Config.Source) async throws {
        try await validate(source, options: nil)
    }

    public func recentLogs() -> [String] {
        recentLogs(limit: 200)
    }

    public func preflightForProvider(_ source: Xray.Config.Source) throws {
        try preflightForProvider(source, options: nil)
    }

    public func preflightIssues(_ source: Xray.Config.Source) throws -> [String] {
        try preflightIssues(source, options: nil)
    }
}
