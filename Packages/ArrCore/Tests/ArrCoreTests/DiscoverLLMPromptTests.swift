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

    // MARK: - Kind parsing

    func test_parse_kindField_parsesMovieAndShow() throws {
        let raw = """
        { "titles": [
            {"title":"Drive","year":2011,"kind":"movie"},
            {"title":"Breaking Bad","year":2008,"kind":"show"}
          ] }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions[0].kind, .movie)
        XCTAssertEqual(r.suggestions[1].kind, .show)
    }

    func test_parse_kindField_nilWhenAbsent() throws {
        let raw = """
        { "titles": [{"title":"Drive","year":2011}] }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertNil(r.suggestions[0].kind)
    }

    func test_parse_kindField_tvAliasesResolveToShow() throws {
        let raw = """
        { "titles": [{"title":"Sopranos","year":1999,"kind":"tv"}] }
        """
        let r = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(r.suggestions[0].kind, .show)
    }

    // MARK: - Kind hint in build

    func test_buildPrompt_movieHint_mentionsMoviesOnly() {
        let p = DiscoverLLMPrompt.build(mood: "noir", decade: .any,
                                        count: 10, exclude: [], kindHint: .movie)
        XCTAssertTrue(p.contains("movies"), "should mention movies")
        XCTAssertFalse(p.contains("\"kind\""), "movie mode should omit kind field in schema")
    }

    func test_buildPrompt_showHint_mentionsTVShows() {
        let p = DiscoverLLMPrompt.build(mood: "noir", decade: .any,
                                        count: 10, exclude: [], kindHint: .show)
        XCTAssertTrue(p.lowercased().contains("tv show") || p.lowercased().contains("shows"),
                      "should mention TV shows")
    }

}
