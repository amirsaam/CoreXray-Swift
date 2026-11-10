import Foundation

// A JSON value with a static type. Everything the bridge assembles, inspects,
// or transforms goes through this instead of `Any`, so misuse fails at
// compile time and every failure path below throws a typed `XrayError`.

/// A JSON value. Build trees with literals, read them with subscripts or
/// dynamic members, encode them with `JSONEncoder`:
///
/// ```swift
/// var doc: XrayJSONValue = ["log": ["loglevel": "warning"]]
/// doc["log"]?["loglevel"] = "error"
/// doc.log?.loglevel?.stringValue // "error"
/// ```
///
/// Decoding probes the narrowest type first: whole JSON numbers stay
/// `.int` (only fractions become `.double`), and `doubleValue` reads
/// an `.int` back as a `Double` so thresholds compare without casting.
/// A whole double like `1.0` therefore decodes as `.int(1)` and
/// re-encodes as `1`. Only the representation changes. The engine parses
/// sections by value, never by spelling. A non-finite `.double`
/// (`.nan`, `.infinity`) has no JSON spelling, so encoding one throws
/// `.invalidInput` (a value that cannot travel, not a bridge failure).
/// Large numbers saturate instead of trapping: ints above
/// `.int`'s range decode as an approximating `.double`, so
/// pass-through of huge values is lossy by design. Nesting decodes
/// recursively. Hostile depth (thousands of levels) overflows the
/// stack instead of failing cleanly, so treat document depth as a trust
/// boundary on untrusted input. Object key order is
/// not preserved. Swift dictionaries have no order,
/// and the engine parses sections by name, so never depend on it.
@dynamicMemberLookup
public enum XrayJSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([XrayJSONValue])
    case object([String: XrayJSONValue])

    // MARK: - Decoding (probes narrowest type first)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let whole = try? container.decode(Int.self) {
            self = .int(whole)
        } else if let fraction = try? container.decode(Double.self) {
            self = .double(fraction)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([XrayJSONValue].self) {
            self = .array(items)
        } else if let fields = try? container.decode([String: XrayJSONValue].self) {
            self = .object(fields)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "engine answered with a JSON value this type cannot represent"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let flag):
            try container.encode(flag)
        case .int(let whole):
            try container.encode(whole)
        case .double(let fraction):
            try container.encode(fraction)
        case .string(let text):
            try container.encode(text)
        case .array(let items):
            try container.encode(items)
        case .object(let fields):
            try container.encode(fields)
        }
    }

    // MARK: - Typed accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public var intValue: Int? {
        if case .int(let whole) = self { return whole }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let fraction) = self { return fraction }
        // Ints read back as doubles so thresholds compare without casting.
        if case .int(let whole) = self { return Double(whole) }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var arrayValue: [XrayJSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: XrayJSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    // MARK: - Subscripts (nil-safe; misuse is a no-op, never a trap)

    /// Reads a field of an object. Assigning writes it; assigning nil
    /// removes it. Reading or writing any other shape is a no-op.
    public subscript(key: String) -> XrayJSONValue? {
        get {
            if case .object(let fields) = self { return fields[key] }
            return nil
        }
        set {
            if case .object(var fields) = self {
                fields[key] = newValue
                self = .object(fields)
            }
        }
    }

    /// Reads an element of an array. Assigning replaces it; out-of-range
    /// access and any other shape are no-ops.
    public subscript(index: Int) -> XrayJSONValue? {
        get {
            if case .array(let items) = self, items.indices.contains(index) { return items[index] }
            return nil
        }
        set {
            if case .array(var items) = self, items.indices.contains(index), let value = newValue {
                items[index] = value
                self = .array(items)
            }
        }
    }

    /// Object field access for inspection: `doc.log?.loglevel`.
    public subscript(dynamicMember member: String) -> XrayJSONValue? {
        self[member]
    }
}

/// A JSON object: the shape every configuration document takes.
public typealias XrayJSONObject = [String: XrayJSONValue]

// MARK: - Literals (so documents read like the JSON they are)

extension XrayJSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension XrayJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension XrayJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension XrayJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension XrayJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension XrayJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: XrayJSONValue...) {
        self = .array(elements)
    }
}

extension XrayJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, XrayJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
