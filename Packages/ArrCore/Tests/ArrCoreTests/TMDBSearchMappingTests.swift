import Testing
import Foundation
@testable import ArrCore

@Suite("TMDBSearchMapping")
struct TMDBSearchMappingTests {
    private func decodeMovie(_ json: String) throws -> TMDBMovieSummary {
        try JSONDecoder().decode(TMDBMovieSummary.self, from: Data(json.utf8))
    }
    private func decodeTV(_ json: String) throws -> TMDBTVSummary {
        try JSONDecoder().decode(TMDBTVSummary.self, from: Data(json.utf8))
    }

    @Test("A movie carries its tmdb id into id/foreignId and derives the year")
    func movieMapping() throws {
        let m = try decodeMovie(#"""
        {"id": 550, "title": "Fight Club", "release_date": "1999-10-15",
         "vote_average": 8.4, "genre_ids": [18], "overview": "…"}
        """#)
        let result = TMDBSearchMapping.movies([m]).first
        #expect(result?.externalId == 550)
        #expect(result?.foreignId == "550")
        #expect(result?.year == 1999)
        #expect(result?.source == .radarr)
        #expect(result?.rating == 8.4)
        #expect(result?.genres == ["Drama"])
        #expect(result?.inLibraryArrId == nil)
    }

    @Test("An owned movie is tagged from the library map")
    func movieOwnershipTagging() throws {
        let m = try decodeMovie(#"{"id": 550, "title": "Fight Club"}"#)
        let result = TMDBSearchMapping.movies([m], libraryMap: [550: 42]).first
        #expect(result?.inLibraryArrId == 42)
    }

    @Test("A series keeps id 0 but carries its TMDB id, so it stays identifiable")
    func seriesCarriesTMDBId() throws {
        let s = try decodeTV(#"""
        {"id": 1396, "name": "Breaking Bad", "first_air_date": "2008-01-20",
         "vote_average": 8.9, "genre_ids": [18], "overview": "…"}
        """#)
        let result = TMDBSearchMapping.series([s]).first
        // `id` is the tvdbId slot, which TMDB can't fill.
        #expect(result?.externalId == 0)
        // …but the row is no longer anonymous: this is what every downstream
        // consumer resolves from, instead of re-finding the show by name.
        #expect(result?.tmdbTVId == 1396)
        #expect(result?.title == "Breaking Bad")
        #expect(result?.year == 2008)
        #expect(result?.source == .sonarr)
    }

    @Test("An owned series is tagged from the tmdb-keyed library map")
    func seriesOwnershipTagging() throws {
        let s = try decodeTV(#"{"id": 1396, "name": "Breaking Bad"}"#)
        let result = TMDBSearchMapping.series([s], libraryMap: [1396: 7]).first
        #expect(result?.inLibraryArrId == 7)
    }

    /// The "The Closer" case, in miniature. Ownership used to be a title + year
    /// join, so a different show sharing both looked like the one in the
    /// library — and the row drilled into somebody else's detail page.
    @Test("A same-titled, same-year series with another tmdb id is NOT tagged")
    func sameTitleDifferentShowIsNotTagged() throws {
        let owned = try decodeTV(#"{"id": 1234, "name": "The Closer", "first_air_date": "2005-06-13"}"#)
        let namesake = try decodeTV(#"{"id": 9999, "name": "The Closer", "first_air_date": "2005-09-01"}"#)
        let rows = TMDBSearchMapping.series([owned, namesake], libraryMap: [1234: 42])
        #expect(rows.first?.inLibraryArrId == 42)
        #expect(rows.last?.inLibraryArrId == nil)
    }


    /// The "104 × The Simpsons" bug: every TMDB series row had `id: 0`, so a
    /// `ForEach` saw one repeated identity and drew the first show over and
    /// over. `SearchResult.id` is a composite now, and the rows that still
    /// cannot identify themselves fall back to title + year rather than
    /// collapsing onto each other.
    @Test("Every series row has its own identity, even without a tvdbId")
    func seriesRowsHaveDistinctIdentities() throws {
        let a = try decodeTV(#"{"id": 1396, "name": "Breaking Bad", "first_air_date": "2008-01-20"}"#)
        let b = try decodeTV(#"{"id": 1434, "name": "Family Guy", "first_air_date": "1999-01-31"}"#)
        let rows = TMDBSearchMapping.series([a, b])

        #expect(rows[0].externalId == 0 && rows[1].externalId == 0)
        #expect(rows[0].id != rows[1].id)
        #expect(rows[0].id == "sonarr:tmdbtv:1396")
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
