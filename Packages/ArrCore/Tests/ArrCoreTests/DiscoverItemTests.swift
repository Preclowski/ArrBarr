import Testing
import Foundation
@testable import ArrCore

@Suite("DiscoverItem")
struct DiscoverItemTests {
    private func mockSearchResult(externalId: Int = 42, title: String = "Drive",
                                  year: Int? = 2011) -> SearchResult {
        SearchResult(
            externalId: externalId, foreignId: String(externalId), title: title, subtitle: nil,
            year: year, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: "drive overview", runtime: 100,
            genres: ["Crime"], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
    }

    @Test("dedupKey prefers the TMDB id carried in foreignId")
    func dedupKeyUsesTmdbIdFromForeignId() {
        let item = DiscoverItem(result: mockSearchResult(externalId: 42))
        #expect(item.dedupKey == "tmdb:42")
    }

    @Test("dedupKey falls back to title+year when there is no foreignId")
    func dedupKeyFallsBackToTitleYear() {
        let result = SearchResult(
            externalId: 0, foreignId: "", title: "Untitled", subtitle: nil,
            year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
        let item = DiscoverItem(result: result)
        #expect(item.dedupKey == "title:untitled|1999")
    }
}
