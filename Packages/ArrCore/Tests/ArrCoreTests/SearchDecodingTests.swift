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

    /// Fixture mirrors a REAL `/api/v1/search` payload: an in-library album
    /// (ids present), a foreign album whose embedded artist has NO `id`
    /// (Lidarr omits it outside the library — the exact shape that used to
    /// fail the whole array decode and blank the music search), and a plain
    /// artist entry.
    @Test("Decodes Lidarr /search mixed payload, incl. album artists without ids")
    func lidarrMixedSearch() throws {
        let json = """
        [{"foreignId":"017f2a37","id":1,
          "album":{"id":5446,"title":"Hounds of Love","foreignAlbumId":"017f2a37",
            "monitored":true,"albumType":"Album","releaseDate":"1985-07-30T00:00:00Z",
            "ratings":{"votes":16,"value":7.9},"images":[],
            "artist":{"id":82,"artistName":"Kate Bush","foreignArtistId":"4b585938"}}},
         {"foreignId":"a1b2c3","id":2,
          "album":{"title":"Hounds of Love","foreignAlbumId":"a1b2c3",
            "monitored":false,"albumType":"Album","releaseDate":"2005-04-25T00:00:00Z",
            "artist":{"artistName":"The Futureheads"}}},
         {"foreignId":"36bbaf5a","id":3,
          "artist":{"artistName":"The Hound Of Love","foreignArtistId":"36bbaf5a",
            "genres":[],"ratings":{"value":0}}}]
        """.data(using: .utf8)!
        let records = try JSONDecoder().decode([LidarrSearchRecord].self, from: json)
        #expect(records.count == 3)
        #expect(records[0].album?.id == 5446)
        #expect(records[0].album?.artist?.id == 82)
        #expect(records[1].album?.artist?.id == nil)
        #expect(records[1].album?.artist?.artistName == "The Futureheads")
        #expect(records[2].artist?.artistName == "The Hound Of Love")

        // Unify: in-library album keeps its arr id, foreign album has none.
        let inLibrary = SearchClient.unifyLidarrAlbum(records[0].album!, baseURL: "http://x")
        #expect(inLibrary?.inLibraryArrId == 5446)
        #expect(inLibrary?.isLidarrAlbum == true)
        #expect(inLibrary?.subtitle == "Kate Bush · Album")
        let foreign = SearchClient.unifyLidarrAlbum(records[1].album!, baseURL: "http://x")
        #expect(foreign?.inLibraryArrId == nil)
    }

    /// Lidarr artist records carry a RELATIVE `remoteUrl`
    /// ("/config/MediaCover/…" — the server's own container path). It must
    /// be ignored in favour of resolving `url` against the base URL;
    /// trusting it produced a scheme-less URL and artist posters never
    /// loaded anywhere (search rows AND the artist detail header).
    @Test("Relative remoteUrl is ignored; url resolves against base")
    func relativeRemoteUrlFallsThrough() {
        let images = [ArrImage(
            coverType: "poster",
            url: "/MediaCover/82/poster.jpg?lastWrite=639220808915209853",
            remoteUrl: "/config/MediaCover/82/poster.jpg"
        )]
        let (url, auth) = images.posterURL(baseURL: "https://lidarr.example")
        #expect(url?.absoluteString == "https://lidarr.example/MediaCover/82/poster.jpg")
        #expect(auth == true)

        // A genuine absolute remoteUrl still wins (no auth needed).
        let remote = [ArrImage(
            coverType: "poster",
            url: "/MediaCover/1/poster.jpg",
            remoteUrl: "https://images.example/p.jpg"
        )]
        let (rUrl, rAuth) = remote.posterURL(baseURL: "https://lidarr.example")
        #expect(rUrl?.absoluteString == "https://images.example/p.jpg")
        #expect(rAuth == false)
    }
}
