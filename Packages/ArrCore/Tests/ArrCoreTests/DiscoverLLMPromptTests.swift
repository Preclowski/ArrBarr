import XCTest
@testable import ArrCore

final class DiscoverLLMPromptTests: XCTestCase {

    // MARK: - build

    func test_build_movie_includesMoodAndCount_andExclusionList() {
        let p = DiscoverLLMPrompt.build(
            mood: "cozy 90s comedy",
            count: 12,
            exclude: ["Toy Story", "Heat"],
            kindHint: .movie
        )
        XCTAssertTrue(p.contains("Mood: cozy 90s comedy"))
        XCTAssertTrue(p.contains("Return exactly 12 distinct movies"))
        XCTAssertTrue(p.contains("Toy Story, Heat"))
        XCTAssertTrue(p.contains("Return only movies"))
        XCTAssertFalse(p.contains("filters"))    // no structured filter schema anymore
        XCTAssertFalse(p.contains("decade"))     // no era constraint anymore
    }

    func test_build_show_returnsOnlyTVShows() {
        let p = DiscoverLLMPrompt.build(
            mood: "moody crime",
            count: 8,
            exclude: [],
            kindHint: .show
        )
        XCTAssertTrue(p.contains("Return only TV shows"))
        XCTAssertTrue(p.contains("Return exactly 8 distinct TV shows"))
    }

    func test_build_emptyExclusion_omitsExclusionSection() {
        let p = DiscoverLLMPrompt.build(
            mood: "anything",
            count: 5,
            exclude: [],
            kindHint: .movie
        )
        XCTAssertFalse(p.contains("Do NOT include"))
    }

    // MARK: - parse

    func test_parse_titlesOnly_returnsSuggestions() throws {
        let raw = #"""
        {"titles":[{"title":"Heat","year":1995},{"title":"Inception","year":2010}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.count, 2)
        XCTAssertEqual(resp.suggestions[0].title, "Heat")
        XCTAssertEqual(resp.suggestions[0].year, 1995)
        XCTAssertEqual(resp.suggestions[1].title, "Inception")
    }

    func test_parse_titleKindAnnotation_isHonoured() throws {
        let raw = #"""
        {"titles":[{"title":"Breaking Bad","year":2008,"kind":"show"}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.first?.kind, .show)
    }

    func test_parse_stripsMarkdownFences() throws {
        let raw = """
        ```json
        {"titles":[{"title":"Akira","year":1988}]}
        ```
        """
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.first?.title, "Akira")
    }

    func test_parse_noJSON_throws() {
        XCTAssertThrowsError(try DiscoverLLMPrompt.parse("hello there")) { err in
            guard case DiscoverLLMPrompt.ParseError.noJSONObjectFound = err else {
                return XCTFail("Unexpected error: \(err)")
            }
        }
    }
}
