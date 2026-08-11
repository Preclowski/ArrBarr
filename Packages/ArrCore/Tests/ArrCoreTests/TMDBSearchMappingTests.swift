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
        #expect(result?.id == 550)
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

    @Test("A series keeps id 0 — the tvdb id isn't a tmdb id, add resolves at add-time")
    func seriesIdIsZero() throws {
        let s = try decodeTV(#"""
        {"id": 1396, "name": "Breaking Bad", "first_air_date": "2008-01-20",
         "vote_average": 8.9, "genre_ids": [18], "overview": "…"}
        """#)
        let result = TMDBSearchMapping.series([s]).first
        #expect(result?.id == 0)
        #expect(result?.title == "Breaking Bad")
        #expect(result?.year == 2008)
        #expect(result?.source == .sonarr)
    }
}
