import ArrCore
import MCP
import Foundation

/// Converts between ArrCore's schema-less `JSONValue` and the MCP SDK's `Value`.
/// `JSONValue.number(Double)` maps to `Value.double`; `Value.int` folds back to
/// `.number`. `Value.data` has no JSON analogue and base64-encodes into a string.
enum JSONValueBridge {
    static func toMCP(_ v: JSONValue) -> Value {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(toMCP))
        case .object(let o): return .object(o.mapValues(toMCP))
        }
    }

    static func toJSON(_ v: Value) -> JSONValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .data(_, let d): return .string(d.base64EncodedString())
        case .array(let a): return .array(a.map(toJSON))
        case .object(let o): return .object(o.mapValues(toJSON))
        }
    }

    static func argumentsToJSON(_ args: [String: Value]?) -> JSONValue {
        .object((args ?? [:]).mapValues(toJSON))
    }
}
