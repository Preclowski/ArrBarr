import Testing
import Foundation
@testable import ArrCore

@Suite("Search Decoding")
struct SearchDecodingTests {
    @Test("Decodes Radarr lookup record")
    func radarrLookup() throws {
        let json = """
        [{"tmdbId":438631,"title":"Dune: Part Two","year":2024,
          "overview":"Paul Atreides...","runtime":166,
          "ratings":{"tmdb":{"value":8.5}},
          "images":[{"coverType":"poster","remoteUrl":"https://example.com/p.jpg"}]}]
        """.data(using: .utf8)!
        let records = try JSONDecoder().decode([RadarrLookupRecord].self, from: json)
        #expect(records[0].tmdbId == 438631)
        #expect(records[0].title == "Dune: Part Two")
        #expect(records[0].ratings?.tmdb?.value == 8.5)
    }

    @Test("Decodes Sonarr lookup record")
    func sonarrLookup() throws {
        let json = """
        [{"tvdbId":81189,"title":"Breaking Bad","year":2008,
          "overview":"A teacher...","ratings":{"value":9.5},
          "statistics":{"seasonCount":5},
          "images":[]}]
        """.data(using: .utf8)!
        let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: json)
        #expect(records[0].tvdbId == 81189)
        #expect(records[0].statistics?.seasonCount == 5)
        #expect(records[0].title == "Breaking Bad")
        #expect(records[0].ratings?.value == 9.5)
    }
}
