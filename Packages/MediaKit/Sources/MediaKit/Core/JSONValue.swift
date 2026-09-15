import Foundation

/// Untyped JSON for the fields a wire model keeps but does not interpret, so a read-modify-write
/// PUT returns every field the server sent.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): n == n.rounded() && abs(n) < 1e15 ? try c.encode(Int64(n)) : try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var intValue: Int? { if case let .number(n) = self { Int(n) } else { nil } }
    public var boolValue: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
}
