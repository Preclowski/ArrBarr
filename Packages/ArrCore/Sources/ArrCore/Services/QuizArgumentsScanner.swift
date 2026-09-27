import Foundation
import MediaKit

/// Reads a `discover_in_quiz` argument string that is still being streamed:
/// the top-level scalars seen so far plus every `items` element that has
/// already closed. Whatever is incomplete is ignored, never guessed.
nonisolated enum QuizArgumentsScanner {

    struct Partial {
        var scalars: [String: JSONValue] = [:]
        var items: [JSONValue] = []

        func string(_ key: String) -> String? {
            if case .string(let v) = scalars[key] { return v }
            return nil
        }

        func bool(_ key: String) -> Bool? {
            if case .bool(let v) = scalars[key] { return v }
            return nil
        }
    }

    static func scan(_ text: String) -> Partial {
        var partial = Partial()
        let bytes = Array(text.utf8)
        var i = skipWhitespace(bytes, 0)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return partial }
        i += 1
        while true {
            i = skipSeparators(bytes, i)
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\""),
                  let keyEnd = stringEnd(bytes, i),
                  case .string(let key)? = decode(bytes[i...keyEnd]) else { return partial }
            i = skipWhitespace(bytes, keyEnd + 1)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return partial }
            i = skipWhitespace(bytes, i + 1)
            guard i < bytes.count else { return partial }

            if key == "items", bytes[i] == UInt8(ascii: "[") {
                i += 1
                while true {
                    i = skipSeparators(bytes, i)
                    guard i < bytes.count else { return partial }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; break }
                    guard let end = valueEnd(bytes, i) else { return partial }
                    if let value = decode(bytes[i...end]) { partial.items.append(value) }
                    i = end + 1
                }
                continue
            }
            guard let end = valueEnd(bytes, i) else { return partial }
            if let value = decode(bytes[i...end]) { partial.scalars[key] = value }
            i = end + 1
        }
    }

    private static func skipWhitespace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    private static func skipSeparators(_ b: [UInt8], _ start: Int) -> Int {
        var i = skipWhitespace(b, start)
        while i < b.count, b[i] == UInt8(ascii: ",") { i = skipWhitespace(b, i + 1) }
        return i
    }

    /// Index of the closing quote, or nil while the string is still open.
    private static func stringEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i }
            i += 1
        }
        return nil
    }

    /// Last index of the value starting at `start`, or nil if it has not
    /// finished arriving. A bare literal only counts once its terminator shows
    /// up — `20` may still become `2024`.
    private static func valueEnd(_ b: [UInt8], _ start: Int) -> Int? {
        switch b[start] {
        case UInt8(ascii: "\""):
            return stringEnd(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(b, i) else { return nil }
                    i = end
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i }
                default:
                    break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count {
                if b[i] == UInt8(ascii: ",") || b[i] == UInt8(ascii: "}") || b[i] == UInt8(ascii: "]") {
                    return i > start ? i - 1 : nil
                }
                i += 1
            }
            return nil
        }
    }

    private static func decode(_ slice: ArraySlice<UInt8>) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(slice))
    }
}
