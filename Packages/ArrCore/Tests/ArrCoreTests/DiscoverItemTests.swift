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

    /// A Quiz card built from the library used to carry the arr's *internal*
    /// record id in `SearchResult.id`, which `mediaRef` reads as a foreign id.
    /// Every ref derived from such a card therefore named a different title,
    /// and the chat's library cross-reference keyed on it looked up the wrong
    /// row. The arr id lives in `inLibraryArrId` and in the card's action.
    @Test("A library-sourced card identifies the title, not the arr record")
    @MainActor
    func libraryCardCarriesForeignId() async {
        let record = RadarrLibraryRecord(
            id: 4242, tmdbId: 550, title: "Fight Club", year: 1999, hasFile: true,
            titleSlug: nil, monitored: true, images: nil, genres: ["Drama"],
            runtime: 139, overview: nil, ratings: nil, certification: nil,
            studio: nil, sizeOnDisk: nil)
        let source = DiscoverSources.radarrLibrary(fetchAll: { [record] })

        let items = (try? await source(DiscoverFilter())) ?? []
        let card = items.first

        #expect(card?.result.id == 550)
        #expect(card?.result.mediaRef == .tmdb(550))
        // The arr id is still there, in the two places that mean "the record".
        #expect(card?.result.inLibraryArrId == 4242)
        #expect(card?.action == .openDetail(source: .radarr, arrId: 4242))
    }
}
