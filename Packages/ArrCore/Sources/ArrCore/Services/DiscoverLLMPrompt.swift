import Foundation

public enum DiscoverLLMPrompt {

    public struct Suggestion: Equatable, Sendable {
        public let title: String
        public let year: Int?
    }

    public struct SuggestedFilters: Equatable, Sendable {
        public let genres: [DiscoverGenre]      // resolved from names by parser
        public let decade: DiscoverDecade?
        public let status: DiscoverStatus?
    }

    public struct Response: Equatable, Sendable {
        public let suggestions: [Suggestion]
        public let filters: SuggestedFilters
    }

    public enum ParseError: Error {
        case noJSONObjectFound
        case malformedJSON(underlying: Error)
    }

    public static func build(mood: String,
                             decade: DiscoverDecade,
                             count: Int,
                             exclude: [String]) -> String {
        var lines: [String] = []
        lines.append(
            "You recommend movies for a tinder-style picker. " +
            "Reply with a single JSON object, no prose, no markdown: " +
            "{ \"titles\": [ { \"title\": string, \"year\": int|null } ], " +
            "\"filters\": { \"genres\": [string], \"decade\": \"1980s\"|\"1990s\"|\"2000s\"|\"2010s\"|\"2020s\"|null, " +
            "\"status\": \"any\"|\"owned\"|\"to_download\"|null } }."
        )
        lines.append("Mood: \(mood)")
        if let range = decade.range {
            lines.append("User-set era constraint already: \(range.lowerBound)-\(range.upperBound). Respect or refine it.")
        }
        lines.append("Return exactly \(count) distinct movies in `titles`.")
        lines.append("`filters.genres` may name standard movie genres (Action, Comedy, Drama, Thriller, etc.) — at most 3.")
        lines.append("`filters.status` is `owned` only when the user clearly wants what they already have.")
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
        struct TitleRow: Decodable { let title: String; let year: Int? }
        struct FiltersRow: Decodable {
            let genres: [String]?
            let decade: String?
            let status: String?
        }
        struct Root: Decodable {
            let titles: [TitleRow]
            let filters: FiltersRow?
        }
        do {
            let root = try JSONDecoder().decode(Root.self, from: Data(jsonSlice.utf8))
            let suggestions = root.titles.map { Suggestion(title: $0.title, year: $0.year) }
            let genres = (root.filters?.genres ?? []).compactMap { DiscoverGenre.from(name: $0) }
            let decade: DiscoverDecade? = (root.filters?.decade).flatMap { raw in
                DiscoverDecade.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
            }
            let status: DiscoverStatus? = (root.filters?.status).flatMap { raw in
                switch raw.lowercased() {
                case "owned": return .owned
                case "to_download", "todownload", "to-download": return .toDownload
                case "any": return .any
                default: return nil
                }
            }
            return Response(suggestions: suggestions,
                            filters: SuggestedFilters(genres: genres, decade: decade, status: status))
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
