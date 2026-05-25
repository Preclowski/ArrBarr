import Foundation

public enum DiscoverLLMPrompt {

    public struct Suggestion: Equatable, Sendable {
        public let title: String
        public let year: Int?
        /// Optional kind annotation from the LLM response.
        /// `nil` means the caller infers the kind from the current mediaSelection.
        public let kind: DiscoverItemKind?
    }

    public struct Response: Equatable, Sendable {
        public let suggestions: [Suggestion]
    }

    public enum ParseError: Error {
        case noJSONObjectFound
        case malformedJSON(underlying: Error)
    }

    public static func build(mood: String,
                             count: Int,
                             exclude: [String],
                             kindHint: DiscoverMediaSelection = .movie) -> String {
        var lines: [String] = []
        switch kindHint {
        case .movie:
            lines.append(
                "You recommend movies for a tinder-style picker. " +
                "Reply with a single JSON object, no prose, no markdown: " +
                "{ \"titles\": [ { \"title\": string, \"year\": int|null } ] }."
            )
            lines.append("Return only movies — no TV shows.")
        case .show:
            lines.append(
                "You recommend TV shows for a tinder-style picker. " +
                "Reply with a single JSON object, no prose, no markdown: " +
                "{ \"titles\": [ { \"title\": string, \"year\": int|null } ] }."
            )
            lines.append("Return only TV shows — no movies.")
        }
        lines.append("Mood: \(mood)")
        let kindLabel: String
        switch kindHint {
        case .movie: kindLabel = "movies"
        case .show:  kindLabel = "TV shows"
        }
        lines.append("Return exactly \(count) distinct \(kindLabel) in `titles`.")
        if !exclude.isEmpty {
            lines.append("Do NOT include any of these already-shown titles:")
            lines.append(exclude.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ raw: String) throws -> Response {
        let cleaned = stripFences(raw)
        guard let jsonSlice = extractFirstObject(from: cleaned) else {
            throw ParseError.noJSONObjectFound
        }
        struct TitleRow: Decodable { let title: String; let year: Int?; let kind: String? }
        struct Root: Decodable { let titles: [TitleRow] }
        do {
            let root = try JSONDecoder().decode(Root.self, from: Data(jsonSlice.utf8))
            let suggestions = root.titles.map { row -> Suggestion in
                let kind: DiscoverItemKind? = row.kind.flatMap { raw in
                    switch raw.lowercased() {
                    case "movie": return .movie
                    case "show", "tv", "series": return .show
                    default: return nil
                    }
                }
                return Suggestion(title: row.title, year: row.year, kind: kind)
            }
            return Response(suggestions: suggestions)
        } catch {
            throw ParseError.malformedJSON(underlying: error)
        }
    }

    private static func stripFences(_ s: String) -> String {
        var out = s
        if let r = out.range(of: "```json") { out.removeSubrange(out.startIndex..<r.upperBound) }
        out = out.replacingOccurrences(of: "```", with: "")
        return out
    }

    private static func extractFirstObject(from s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if c == "\\" { escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
