import Testing
import Foundation
@testable import ArrCore

@Suite("DiscoverItem & DiscoverFilter")
struct DiscoverItemTests {
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

    @Test("dedupKey prefers the TMDB id carried in foreignId")
    func dedupKeyUsesTmdbIdFromForeignId() {
        let item = DiscoverItem(result: mockSearchResult(id: 42), action: .addToRadarr)
        #expect(item.dedupKey == "tmdb:42")
    }

    @Test("dedupKey falls back to title+year when there is no foreignId")
    func dedupKeyFallsBackToTitleYear() {
        let result = SearchResult(
            id: 0, foreignId: "", title: "Untitled", subtitle: nil,
            year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
        let item = DiscoverItem(result: result, action: .addToRadarr)
        #expect(item.dedupKey == "title:untitled|1999")
    }

    @Test("An unconstrained filter passes everything through")
    func filterPassesItemWhenNoConstraints() {
        let filter = DiscoverFilter()
        #expect(filter.matches(year: 2011, monitored: false))
    }

    @Test("A decade filter passes only years inside the range")
    func filterPassesItemInDecadeRange() {
        let filter = DiscoverFilter(decade: .twoThousandTens)
        #expect(filter.matches(year: 2011, monitored: false))
        #expect(!filter.matches(year: 1995, monitored: false))
        #expect(!filter.matches(year: nil, monitored: false))
    }

    @Test("monitoredOnly excludes unmonitored and unknown-monitoring items")
    func filterMonitoredOnlyExcludesUnmonitored() {
        let filter = DiscoverFilter(monitoredOnly: true)
        #expect(filter.matches(year: 2011, monitored: true))
        #expect(!filter.matches(year: 2011, monitored: false))
        #expect(!filter.matches(year: 2011, monitored: nil))
    }

    @Test("Genre intersection and owned status must both hold")
    func filterGenreIntersectionAndStatus() {
        var f = DiscoverFilter()
        f.genres = [.comedy]
        f.status = .owned

        #expect(f.matches(year: 2010, monitored: true, hasFile: true,
                          genres: ["Comedy", "Drama"]))
        #expect(!f.matches(year: 2010, monitored: true, hasFile: false,
                           genres: ["Comedy"]),
                "status=owned requires hasFile=true")
        #expect(!f.matches(year: 2010, monitored: true, hasFile: true,
                           genres: ["Drama"]),
                "genre intersection must be non-empty")
    }

    @Test("Rating and runtime tiers expose their thresholds")
    func filterRatingAndRuntimeAreExposed() {
        var f = DiscoverFilter()
        f.rating = .highlyRated
        f.runtime = .short
        #expect(f.rating.minRating == 7.5)
        #expect(f.runtime.lessThan == 90)
    }

    @Test("The runtime overload rejects items past the tier's ceiling")
    func filterRuntimeOverloadExcludesByRuntime() {
        var f = DiscoverFilter()
        f.runtime = .short
        #expect(f.matches(year: 2010, monitored: true, hasFile: true,
                          genres: ["Comedy"], runtime: 85))
        #expect(!f.matches(year: 2010, monitored: true, hasFile: true,
                           genres: ["Comedy"], runtime: 95))
    }
}
