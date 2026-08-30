import Testing
import Foundation
@testable import ArrCore

// A season pack is one download whose rows all belong to one season, so it has
// a season poster to show where a single episode row (or a multi-season grab)
// has none. `seasonPackSeasons` is where that decision is made, and `unify` is
// where the resolved artwork has to beat both the metadata store's poster and
// the arr's own images — pinning both keeps the override from quietly reverting
// to series art.
@Suite("Season pack artwork")
struct SeasonPackArtworkTests {

    private func records(_ recordsJSON: String) throws -> [SonarrQueueRecord] {
        let json = """
        {"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [\(recordsJSON)]}
        """
        return try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: Data(json.utf8)).records
    }

    private func row(id: Int, downloadId: String, season: Int, episode: Int) -> String {
        """
        {"id": \(id), "seriesId": 3, "downloadId": "\(downloadId)", "seasonNumber": \(season),
         "title": "Series.S\(String(format: "%02d", season)).1080p", "size": 1000, "sizeleft": 500,
         "episode": {"id": \(id * 10), "seasonNumber": \(season), "episodeNumber": \(episode)}}
        """
    }

    @Test("Several rows of one season sharing a download are a pack")
    func packDetected() throws {
        let rs = try records([
            row(id: 1, downloadId: "abc", season: 2, episode: 1),
            row(id: 2, downloadId: "abc", season: 2, episode: 2),
            row(id: 3, downloadId: "abc", season: 2, episode: 3),
        ].joined(separator: ","))
        #expect(SonarrClient.seasonPackSeasons(rs) == ["abc": 2])
    }

    @Test("A single-row download is not a pack — it is indistinguishable from one episode")
    func singleRowIsNotAPack() throws {
        let rs = try records(row(id: 1, downloadId: "abc", season: 2, episode: 1))
        #expect(SonarrClient.seasonPackSeasons(rs).isEmpty)
    }

    @Test("A download spanning two seasons has no one season to show")
    func multiSeasonDownloadIsNotAPack() throws {
        let rs = try records([
            row(id: 1, downloadId: "abc", season: 1, episode: 10),
            row(id: 2, downloadId: "abc", season: 2, episode: 1),
        ].joined(separator: ","))
        #expect(SonarrClient.seasonPackSeasons(rs).isEmpty)
    }

    @Test("Rows without a download id are ignored rather than grouped together")
    func missingDownloadIds() throws {
        let rs = try records("""
        {"id": 1, "seriesId": 3, "seasonNumber": 2, "size": 1, "sizeleft": 1},
        {"id": 2, "seriesId": 3, "seasonNumber": 2, "size": 1, "sizeleft": 1}
        """)
        #expect(SonarrClient.seasonPackSeasons(rs).isEmpty)
    }

    @Test("Season artwork beats both the cached series poster and the arr's images")
    func seasonPosterWins() throws {
        let r = try #require(try records("""
        {"id": 9, "seriesId": 3, "downloadId": "abc", "seasonNumber": 2,
         "title": "Series.S02.1080p", "size": 1000, "sizeleft": 500,
         "series": {"id": 3, "title": "Series", "year": 2019, "titleSlug": "series",
           "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/series.jpg"}]},
         "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3}}
        """).first)
        let cached = TitleMetadataStore.Metadata(
            title: "Series", year: 2019, slug: "series",
            posterURL: URL(string: "https://cache.example.com/series.jpg"),
            posterRequiresAuth: true
        )
        let season = URL(string: "http://plex.local:32400/library/metadata/42/thumb/1")

        let item = SonarrClient.unify(r, baseURL: "http://sonarr.local:8989", fileMap: [:],
                                      meta: [3: cached], seasonPoster: season)

        #expect(item.posterURL == season)
        // Media-server artwork authenticates by header, never with the arr key.
        #expect(item.posterRequiresAuth == false)
    }

    @Test("Without season artwork the row keeps the series poster it had")
    func fallsBackToSeriesPoster() throws {
        let r = try #require(try records("""
        {"id": 9, "seriesId": 3, "downloadId": "abc", "seasonNumber": 2,
         "title": "Series.S02.1080p", "size": 1000, "sizeleft": 500,
         "series": {"id": 3, "title": "Series", "year": 2019, "titleSlug": "series",
           "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/series.jpg"}]},
         "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3}}
        """).first)

        let item = SonarrClient.unify(r, baseURL: "http://sonarr.local:8989", fileMap: [:])

        #expect(item.posterURL?.absoluteString == "https://img.example.com/series.jpg")
    }
}
