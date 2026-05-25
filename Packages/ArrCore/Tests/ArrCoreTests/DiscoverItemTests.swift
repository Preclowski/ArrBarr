import XCTest
@testable import ArrCore

final class DiscoverItemTests: XCTestCase {
    private func mockSearchResult(id: Int = 42, title: String = "Drive",
                                  year: Int? = 2011) -> SearchResult {
        SearchResult(
            id: id, foreignId: String(id), title: title, subtitle: nil,
            year: year, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: "drive overview", runtime: 100,
            genres: ["Crime"], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
    }

    func test_dedupKey_usesTmdbIdFromForeignId() {
        let item = DiscoverItem(result: mockSearchResult(id: 42), action: .addToRadarr)
        XCTAssertEqual(item.dedupKey, "tmdb:42")
    }

    func test_dedupKey_fallsBackToTitleYearWhenNoForeignId() {
        let result = SearchResult(
            id: 0, foreignId: "", title: "Untitled", subtitle: nil,
            year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
        let item = DiscoverItem(result: result, action: .addToRadarr)
        XCTAssertEqual(item.dedupKey, "title:untitled|1999")
    }

    func test_filter_passesItem_whenNoConstraints() {
        let filter = DiscoverFilter()
        XCTAssertTrue(filter.matches(year: 2011, monitored: false))
    }

    func test_filter_passesItem_inDecadeRange() {
        let filter = DiscoverFilter(decade: .twoThousandTens)
        XCTAssertTrue(filter.matches(year: 2011, monitored: false))
        XCTAssertFalse(filter.matches(year: 1995, monitored: false))
        XCTAssertFalse(filter.matches(year: nil, monitored: false))
    }

    func test_filter_monitoredOnly_excludesUnmonitored() {
        let filter = DiscoverFilter(monitoredOnly: true)
        XCTAssertTrue(filter.matches(year: 2011, monitored: true))
        XCTAssertFalse(filter.matches(year: 2011, monitored: false))
        XCTAssertFalse(filter.matches(year: 2011, monitored: nil))
    }
}
