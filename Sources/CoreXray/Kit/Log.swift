import Foundation

// The log section: level plus where access and error output go. Written
// verbatim; replaces any log section already in the document.

extension Xray {
    /// A `log` section, written verbatim.
    ///
    /// ```swift
    /// Xray.shared.log(level: .warning, dnsLog: true)
    /// ```
    public struct Log: Sendable {
        public enum Level: String, Sendable {
            case debug
            case info
            case warning
            case error
            case none
        }

        public var level: Level?
        public var access: String?
        public var error: String?
        public var dnsLog: Bool?

        internal init(
            level: Level? = nil,
            access: String? = nil,
            error: String? = nil,
            dnsLog: Bool? = nil
        ) {
            self.level = level
            self.access = access
            self.error = error
            self.dnsLog = dnsLog
        }

        var wireObject: JSONObject {
            var section: JSONObject = [:]
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
}

// Value factory for the log section.
extension Xray {
    public func log(
        level: Log.Level? = nil,
        access: String? = nil,
        error: String? = nil,
        dnsLog: Bool? = nil
    ) -> Log {
        Log(level: level, access: access, error: error, dnsLog: dnsLog)
    }
}
