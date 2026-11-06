import Foundation

// Failures from the engine or the bridge. Catch sites discriminate by case
// instead of parsing message text.

public enum XrayError: Swift.Error, LocalizedError, Sendable {
    /// The engine answered with success=false; the message is its complaint.
    case engineFailed(String)

    /// The bridge itself failed: undecodable envelope, unserializable
    /// document, unreadable file.
    case bridgeFailed(String)

    /// The input was unusable before it ever reached the engine: not JSON,
    /// not an object, unknown shape.
    case invalidInput(String)

    /// The operation ran past its time budget: a start that never came
    /// up, a health check against a wedged bridge.
    case timedOut(String)

    /// A geo database a configuration depends on (`geosite:` / `geoip:`
    /// references) is missing, empty, or unreadable where the engine will
    /// look for it. The message names every file that was searched.
    case geoAssets(String)

    public var errorDescription: String? {
        switch self {
        case .engineFailed(let message),
             .bridgeFailed(let message),
             .invalidInput(let message),
             .timedOut(let message),
             .geoAssets(let message):
            return message
        }
    }

    /// What to do about it, in one line. The message says what happened;
    /// this says where to look next — including when the failure names
    /// a step (fetch, metrics, log tail, envelope), which means the step
    /// broke, not the operation around it.
    public var recoveryHint: String? {
        switch self {
        case .engineFailed:
            return "the engine refused the operation — for configs, validate(...) shows its complaint; for anything else the message says what it wanted"
        case .bridgeFailed:
            return "something outside the engine failed — the message names the step (fetch, metrics, log tail, envelope): check that step before retrying"
        case .invalidInput:
            return "the input was unusable before reaching the engine — check the call's documented rules"
        case .timedOut:
            return "the engine did not answer in time — for a start, check geo assets and listener ports, then health(); a wedged bridge needs a process restart"
        case .geoAssets:
            return "fetch the database with XrayGeoDownloader into a searched directory, or pass xray.location.asset through XraySessionOptions.environment"
        }
    }
}

