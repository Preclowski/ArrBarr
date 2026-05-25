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

    func test_filter_genreIntersection_andStatus() {
        var f = DiscoverFilter()
        f.genres = [.comedy]
        f.status = .owned

        XCTAssertTrue(f.matches(year: 2010, monitored: true, hasFile: true,
                                genres: ["Comedy", "Drama"]))
        XCTAssertFalse(f.matches(year: 2010, monitored: true, hasFile: false,
                                 genres: ["Comedy"]),
                       "status=owned requires hasFile=true")
        XCTAssertFalse(f.matches(year: 2010, monitored: true, hasFile: true,
                                 genres: ["Drama"]),
                       "genre intersection must be non-empty")
    }

    func test_filter_ratingAndRuntime_areExposed() {
        var f = DiscoverFilter()
        f.rating = .highlyRated
        f.runtime = .short
        XCTAssertEqual(f.rating.minRating, 7.5)
        XCTAssertEqual(f.runtime.lessThan, 90)
    }

    func test_filter_runtimeOverload_excludesByRuntime() {
        var f = DiscoverFilter()
        f.runtime = .short
        XCTAssertTrue(f.matches(year: 2010, monitored: true, hasFile: true,
                                genres: ["Comedy"], runtime: 85))
        XCTAssertFalse(f.matches(year: 2010, monitored: true, hasFile: true,
                                 genres: ["Comedy"], runtime: 95))
    }
}
