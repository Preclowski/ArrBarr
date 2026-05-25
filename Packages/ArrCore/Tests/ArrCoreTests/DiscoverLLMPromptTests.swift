import XCTest
@testable import ArrCore

final class DiscoverLLMPromptTests: XCTestCase {

    func test_buildPrompt_includesMoodAndAskedCount() {
        let p = DiscoverLLMPrompt.build(mood: "short 90s comedy",
                                        decade: .nineties, count: 20, exclude: [])
        XCTAssertTrue(p.contains("short 90s comedy"))
        XCTAssertTrue(p.contains("20"))
        XCTAssertTrue(p.contains("1990"))
    }

    func test_buildPrompt_listsExcludesWhenPresent() {
        let p = DiscoverLLMPrompt.build(mood: "noir", decade: .any, count: 20,
                                        exclude: ["Drive (2011)", "Heat (1995)"])
        XCTAssertTrue(p.contains("Drive (2011)"))
        XCTAssertTrue(p.contains("Heat (1995)"))
    }

    func test_buildPrompt_omitsExcludeSectionWhenEmpty() {
        let p = DiscoverLLMPrompt.build(mood: "anything", decade: .any,
                                        count: 20, exclude: [])
        XCTAssertFalse(p.lowercased().contains("do not include"))
    }

    func test_parse_extractsTitlesAndFilters() throws {
        let raw = """
        { "titles": [{"title":"Drive","year":2011}, {"title":"Heat","year":1995}],
          "filters": { "genres": ["Thriller", "Crime"], "decade": "2010s", "status": "any" } }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions.map(\.title), ["Drive", "Heat"])
        XCTAssertEqual(Set(r.filters.genres), [.thriller, .crime])
        XCTAssertEqual(r.filters.decade, .twoThousandTens)
        XCTAssertEqual(r.filters.status, .any)
    }

    func test_parse_acceptsMissingFiltersBlock() throws {
        let raw = """
        { "titles": [{"title":"Drive","year":2011}] }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions.count, 1)
        XCTAssertTrue(r.filters.genres.isEmpty)
        XCTAssertNil(r.filters.decade)
        XCTAssertNil(r.filters.status)
    }

    func test_parse_toleratesCodeFences() throws {
        let raw = """
        Here you go:
        ```json
        { "titles": [{"title":"Drive","year":2011}] }
        ```
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions.count, 1)
    }

    func test_parse_toleratesTrailingProse() throws {
        let raw = """
        { "titles": [{"title":"Drive","year":2011}] }
        Hope this helps!
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions.count, 1)
    }

    func test_parse_throwsOnNoObject() {
        XCTAssertThrowsError(try DiscoverLLMPrompt.parse("not json at all"))
    }

    func test_parse_unknownGenreNamesIgnored() throws {
        let raw = """
        { "titles": [{"title":"X","year":null}],
          "filters": { "genres": ["Comedy", "Bogus Genre"] } }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.filters.genres, [.comedy])
    }
}
