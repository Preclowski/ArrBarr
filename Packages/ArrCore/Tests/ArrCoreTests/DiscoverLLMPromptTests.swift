import XCTest
@testable import ArrCore

final class DiscoverLLMPromptTests: XCTestCase {
    func test_buildPrompt_includesMoodAndAskedCount() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "short 90s comedy",
            decade: .nineties,
            count: 20,
            exclude: []
        )
        XCTAssertTrue(prompt.contains("short 90s comedy"))
        XCTAssertTrue(prompt.contains("20"))
        XCTAssertTrue(prompt.contains("1990"))
    }

    func test_buildPrompt_listsExcludesWhenPresent() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "noir",
            decade: .any,
            count: 20,
            exclude: ["Drive (2011)", "Heat (1995)"]
        )
        XCTAssertTrue(prompt.contains("Drive (2011)"))
        XCTAssertTrue(prompt.contains("Heat (1995)"))
    }

    func test_buildPrompt_omitsExcludeSectionWhenEmpty() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "anything", decade: .any, count: 20, exclude: [])
        XCTAssertFalse(prompt.lowercased().contains("do not include"))
    }

    func test_parse_extractsTitlesFromCleanJSON() throws {
        let raw = """
        [{"title":"Drive","year":2011,"reason":"x"},
         {"title":"Heat","year":1995,"reason":"y"}]
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "Drive")
        XCTAssertEqual(parsed[0].year, 2011)
        XCTAssertEqual(parsed[1].title, "Heat")
    }

    func test_parse_toleratesCodeFences() throws {
        let raw = """
        Here you go:
        ```json
        [{"title":"Drive","year":2011,"reason":"x"}]
        ```
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "Drive")
    }

    func test_parse_toleratesTrailingProse() throws {
        let raw = """
        [{"title":"Drive","year":2011,"reason":"x"}]
        Hope this helps!
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 1)
    }

    func test_parse_throwsOnNoArray() {
        XCTAssertThrowsError(try DiscoverLLMPrompt.parse("not json at all"))
    }
}
