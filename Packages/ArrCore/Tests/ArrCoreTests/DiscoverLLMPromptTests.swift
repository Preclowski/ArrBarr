import Testing
import Foundation
@testable import ArrCore

@Suite("DiscoverLLMPrompt")
struct DiscoverLLMPromptTests {

    // MARK: - build

    @Test("A movie prompt carries the mood, the exact count and the exclusion list")
    func buildMovieIncludesMoodCountAndExclusions() {
        let p = DiscoverLLMPrompt.build(
            mood: "cozy 90s comedy",
            count: 12,
            exclude: ["Toy Story", "Heat"],
            kindHint: .movie
        )
        #expect(p.contains("Mood: cozy 90s comedy"))
        #expect(p.contains("Return exactly 12 distinct movies"))
        #expect(p.contains("Toy Story, Heat"))
        #expect(p.contains("Return only movies"))
        #expect(!p.contains("filters"))    // no structured filter schema anymore
        #expect(!p.contains("decade"))     // no era constraint anymore
    }

    @Test("A show prompt asks for TV shows only")
    func buildShowReturnsOnlyTVShows() {
        let p = DiscoverLLMPrompt.build(
            mood: "moody crime",
            count: 8,
            exclude: [],
            kindHint: .show
        )
        #expect(p.contains("Return only TV shows"))
        #expect(p.contains("Return exactly 8 distinct TV shows"))
    }

    @Test("An empty exclusion list omits the exclusion section entirely")
    func buildEmptyExclusionOmitsSection() {
        let p = DiscoverLLMPrompt.build(
            mood: "anything",
            count: 5,
            exclude: [],
            kindHint: .movie
        )
        #expect(!p.contains("Do NOT include"))
    }

    // MARK: - parse

    @Test("A titles-only payload parses into ordered suggestions")
    func parseTitlesOnlyReturnsSuggestions() throws {
        let raw = #"""
        {"titles":[{"title":"Heat","year":1995},{"title":"Inception","year":2010}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        #expect(resp.suggestions.count == 2)
        #expect(resp.suggestions[0].title == "Heat")
        #expect(resp.suggestions[0].year == 1995)
        #expect(resp.suggestions[1].title == "Inception")
    }

    @Test("A per-title kind annotation is honoured")
    func parseTitleKindAnnotationIsHonoured() throws {
        let raw = #"""
        {"titles":[{"title":"Breaking Bad","year":2008,"kind":"show"}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        #expect(resp.suggestions.first?.kind == .show)
    }

    @Test("Markdown fences wrapped around the JSON are stripped")
    func parseStripsMarkdownFences() throws {
        let raw = """
        ```json
        {"titles":[{"title":"Akira","year":1988}]}
        ```
        """
        let resp = try DiscoverLLMPrompt.parse(raw)
        #expect(resp.suggestions.first?.title == "Akira")
    }

    @Test("A reply with no JSON object at all throws noJSONObjectFound")
    func parseWithoutJSONThrows() {
        let error = #expect(throws: DiscoverLLMPrompt.ParseError.self) {
            try DiscoverLLMPrompt.parse("hello there")
        }
        // ParseError can't be compared with `==` — `.malformedJSON` wraps an
        // `any Error` — so the specific case is pattern-matched instead.
        guard case .noJSONObjectFound? = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }
}
