import Foundation

public enum DiscoverLLMPrompt {

    public struct Suggestion: Equatable, Sendable {
        public let title: String
        public let year: Int?
    }

    public enum ParseError: Error {
        case noJSONArrayFound
        case malformedJSON(underlying: Error)
    }

    /// Build a single-shot user prompt for the LLM source. Stateless —
    /// any "more suggestions" call passes the cumulative exclude list.
    public static func build(
        mood: String,
        decade: DiscoverDecade,
        count: Int,
        exclude: [String]
    ) -> String {
        var lines: [String] = []
        lines.append(
            "You recommend movies for a tinder-style picker. " +
            "Respond ONLY as a JSON array of objects with keys " +
            "{\"title\": string, \"year\": int|null, \"reason\": string}. " +
            "No prose, no markdown."
        )
        lines.append("Mood: \(mood)")
        if let range = decade.range {
            lines.append("Era constraint: movies released between \(range.lowerBound) and \(range.upperBound).")
        }
        lines.append("Return exactly \(count) distinct movies.")
        if !exclude.isEmpty {
            lines.append("Do NOT include any of these already-shown titles:")
            lines.append(exclude.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Tolerant JSON parse: strips ``` fences, finds the first `[` ...
    /// matching `]`, decodes. Trailing prose after the array is ignored.
    public static func parse(_ raw: String) throws -> [Suggestion] {
        let cleaned = stripFences(raw)
        guard let jsonSlice = extractFirstArray(from: cleaned) else {
            throw ParseError.noJSONArrayFound
        }
        let data = Data(jsonSlice.utf8)
        struct Row: Decodable { let title: String; let year: Int? }
        do {
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return rows.map { Suggestion(title: $0.title, year: $0.year) }
        } catch {
            throw ParseError.malformedJSON(underlying: error)
        }
    }

    private static func stripFences(_ s: String) -> String {
        var out = s
        if let r = out.range(of: "```json") {
            out.removeSubrange(out.startIndex..<r.upperBound)
        }
        out = out.replacingOccurrences(of: "```", with: "")
        return out
    }

    private static func extractFirstArray(from s: String) -> String? {
        guard let start = s.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if c == "\\" { escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
