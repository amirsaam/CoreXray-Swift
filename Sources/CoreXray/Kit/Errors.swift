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
    /// this says where to look next.
    public var recoveryHint: String? {
        switch self {
        case .engineFailed:
            return "the engine rejected the document — validate the config to see its complaint"
        case .bridgeFailed:
            return "the bridge itself failed — check the document size and shape before retrying"
        case .invalidInput:
            return "the input was unusable before reaching the engine — check the call's documented rules"
        case .timedOut:
            return "the engine did not answer in time — check geo assets and listener ports, then retry"
        case .geoAssets:
            return "fetch the database with XrayGeoDownloader or point XraySessionOptions.environment at it"
        }
    }
}

