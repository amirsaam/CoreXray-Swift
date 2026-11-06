import Foundation

// The log section: level plus where access and error output go. Written
// verbatim; replaces any log section already in the document.

public enum XrayLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case none
}

/// A `log` section, written verbatim.
///
/// ```swift
/// Xray.shared.log(level: .warning, dnsLog: true)
/// ```
public struct XrayLog: Sendable {

    public var level: XrayLogLevel?
    public var access: String?
    public var error: String?
    public var dnsLog: Bool?

    internal init(
        level: XrayLogLevel? = nil,
        access: String? = nil,
        error: String? = nil,
        dnsLog: Bool? = nil
    ) {
        self.level = level
        self.access = access
        self.error = error
        self.dnsLog = dnsLog
    }

    var wireObject: XrayJSONObject {
        var section: XrayJSONObject = [:]
        if let level {
            section["loglevel"] = .string(level.rawValue)
        }
        if let access {
            section["access"] = .string(access)
        }
        if let error {
            section["error"] = .string(error)
        }
        if let dnsLog {
            section["dnsLog"] = .bool(dnsLog)
        }
        return section
    }
}

// Value factory for the log section.
extension Xray {
    public func log(
        level: XrayLogLevel? = nil,
        access: String? = nil,
        error: String? = nil,
        dnsLog: Bool? = nil
    ) -> XrayLog {
        XrayLog(level: level, access: access, error: error, dnsLog: dnsLog)
    }
}
