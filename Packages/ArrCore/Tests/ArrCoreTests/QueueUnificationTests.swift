import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// `ArrCompositions.queueItem` is where every field a queue row displays is decided — title,
/// subtitle, poster, slug, upgrade diff. One record shape serves all four arrs.
@Suite("Queue unification")
struct QueueUnificationTests {
    private func record(_ recordJSON: String) throws -> ArrQueueRecord {
        let json = """
        {"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [\(recordJSON)]}
        """
        let page = try WireCodec.decoder.decode(ArrPage<ArrQueueRecord>.self, from: Data(json.utf8))
        return try #require(page.records.first)
    }

    private func files(_ json: String) throws -> [MediaKit.ArrFile] {
        try WireCodec.decoder.decode([MediaKit.ArrFile].self, from: Data(json.utf8))
    }

    private func item(_ r: ArrQueueRecord, _ source: QueueItem.Source, baseURL: String = "http://arr.local",
                      files: [Int: [MediaKit.ArrFile]] = [:], meta: [Int: ArrCompositions.EntityMeta] = [:]) -> QueueItem {
        ArrCompositions.queueItem(r, source: source, baseURL: baseURL, files: files, meta: meta)
    }

    // MARK: - Lidarr

    @Test("Lidarr: embedded artist + album give the display title, poster and slug")
    func lidarrWithEmbeddedObjects() throws {
        let r = try record("""
        {
          "id": 12, "artistId": 7, "albumId": 15,
          "title": "Example Artist - Example Album [FLAC]",
          "status": "downloading", "trackedDownloadState": "downloading",
          "size": 524288000, "sizeleft": 131072000,
          "artist": {"id": 7, "artistName": "Example Artist",
            "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/artist.jpg"}]},
          "album": {"id": 15, "title": "Example Album",
            "foreignAlbumId": "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
            "images": [{"coverType": "cover", "remoteUrl": "https://img.example.com/cover.jpg"}]}
        }
        """)
        let item = item(r, .lidarr)
        #expect(item.title == "Example Artist — Example Album")
        #expect(item.releaseName == "Example Artist - Example Album [FLAC]")
        #expect(item.entityId == 15)
        #expect(item.contentSlug == "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/cover.jpg")
        #expect(item.posterRequiresAuth == false)
        #expect(item.isUpgrade == false)
    }

    @Test("Lidarr: artist image is the poster fallback when the album has none")
    func lidarrArtistPosterFallback() throws {
        let r = try record("""
        {"id": 13, "albumId": 16, "title": "Rel",
         "artist": {"id": 7, "artistName": "A", "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/artist.jpg"}]},
         "album": {"id": 16, "title": "B"}}
        """)
        #expect(item(r, .lidarr).posterURL?.absoluteString == "https://img.example.com/artist.jpg")
    }

    @Test("Lidarr: without embedded objects the row degrades to the release name")
    func lidarrLeanShape() throws {
        let r = try record("""
        {"id": 12, "artistId": 7, "albumId": 15, "title": "Example Artist - Example Album [FLAC]",
         "status": "downloading", "size": 524288000, "sizeleft": 131072000}
        """)
        let item = item(r, .lidarr)
        #expect(item.title == "Example Artist - Example Album [FLAC]")
        #expect(item.posterURL == nil)
        #expect(item.contentSlug == nil)
        #expect(item.entityId == 15)
    }

    @Test("Lidarr: entity metadata restores everything the lean record dropped")
    func lidarrLeanShapeWithMetadata() throws {
        let r = try record("""
        {"id": 12, "artistId": 7, "albumId": 15, "title": "Example Artist - Example Album [FLAC]",
         "status": "downloading", "size": 524288000, "sizeleft": 131072000}
        """)
        let meta = ArrCompositions.EntityMeta(title: "Example Album", secondary: "Example Artist", slug: "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
                                              poster: URL(string: "https://img.example.com/cover.jpg"))
        let item = item(r, .lidarr, meta: [15: meta])
        #expect(item.title == "Example Artist — Example Album")
        #expect(item.contentSlug == "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/cover.jpg")
        #expect(item.releaseName == "Example Artist - Example Album [FLAC]")
    }

    @Test("Lidarr: entity metadata takes precedence over an embedded album")
    func lidarrMetadataBeatsEmbedded() throws {
        let r = try record("""
        {"id": 12, "albumId": 15, "title": "Rel", "album": {"id": 15, "title": "Stale Album"}, "artist": {"id": 7, "artistName": "Stale Artist"}}
        """)
        let meta = ArrCompositions.EntityMeta(title: "Fresh Album", secondary: "Fresh Artist")
        #expect(item(r, .lidarr, meta: [15: meta]).title == "Fresh Artist — Fresh Album")
    }

    @Test("Lidarr: track files aggregate into an album-level upgrade diff")
    func lidarrUpgradeDiff() throws {
        let r = try record(#"{"id": 12, "albumId": 15, "title": "Rel", "album": {"id": 15, "title": "B"}}"#)
        let decoded = try files("""
        [{"id": 1, "albumId": 15, "size": 1000, "quality": {"quality": {"name": "MP3-320"}}},
         {"id": 2, "albumId": 15, "size": 3000, "quality": {"quality": {"name": "MP3-320"}}}]
        """)
        let item = item(r, .lidarr, files: [15: decoded])
        #expect(item.isUpgrade == true)
        #expect(item.existingSize == 4000)
        #expect(item.existingQuality == "MP3-320")
        #expect(item.existingFileName == nil)
    }

    // MARK: - Radarr

    @Test("Radarr: embedded movie gives a year-stamped title and poster")
    func radarrWithEmbeddedMovie() throws {
        let r = try record("""
        {"id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL", "size": 1000, "sizeleft": 250,
         "movie": {"id": 42, "title": "Movie", "year": 2024, "titleSlug": "movie-2024",
           "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/m.jpg"}]}}
        """)
        let item = item(r, .radarr)
        #expect(item.title == "Movie (2024)")
        #expect(item.releaseName == "Movie.2024.1080p.WEB-DL")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/m.jpg")
        #expect(item.progress == 0.75)
    }

    @Test("Radarr: without the embedded movie the row degrades to the release name")
    func radarrLeanShape() throws {
        let r = try record(#"{"id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL", "size": 1000, "sizeleft": 250}"#)
        let item = item(r, .radarr)
        #expect(item.title == "Movie.2024.1080p.WEB-DL")
        #expect(item.posterURL == nil)
        #expect(item.entityId == 42)
    }

    @Test("Radarr: entity metadata restores the year-stamped title, poster and slug")
    func radarrLeanShapeWithMetadata() throws {
        let r = try record(#"{"id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL", "size": 1000, "sizeleft": 250}"#)
        let meta = ArrCompositions.EntityMeta(title: "Movie", year: 2024, slug: "movie-2024", poster: URL(string: "https://img.example.com/m.jpg"))
        let item = item(r, .radarr, meta: [42: meta])
        #expect(item.title == "Movie (2024)")
        #expect(item.contentSlug == "movie-2024")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/m.jpg")
    }

    @Test("Radarr: the existing file drives the upgrade diff")
    func radarrUpgradeDiff() throws {
        let r = try record(#"{"id": 5, "movieId": 42, "title": "Movie.2024.2160p", "size": 1000, "sizeleft": 250, "quality": {"quality": {"name": "Remux-2160p"}}}"#)
        let decoded = try files(#"[{"id": 9, "movieId": 42, "size": 700, "relativePath": "Movie (2024)/Movie.mkv", "quality": {"quality": {"name": "Bluray-1080p"}}}]"#)
        let item = item(r, .radarr, files: [42: decoded])
        #expect(item.isUpgrade && item.existingQuality == "Bluray-1080p" && item.existingSize == 700 && item.existingFileName == "Movie.mkv")
    }

    // MARK: - Sonarr

    @Test("Sonarr: embedded series + episode give the title and the SxxExx subtitle")
    func sonarrWithEmbeddedObjects() throws {
        let r = try record("""
        {"id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2, "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500,
         "series": {"id": 3, "title": "Series", "year": 2019, "titleSlug": "series",
           "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/s.jpg"}]},
         "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3, "title": "The Episode"}}
        """)
        let item = item(r, .sonarr)
        #expect(item.title == "Series (2019)")
        #expect(item.subtitle == "S02E03 · The Episode")
        #expect(item.seasonNumber == 2)
        #expect(item.episodeNumber == 3)
        #expect(item.episodeTitle == "The Episode")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/s.jpg")
    }

    @Test("Sonarr: entity metadata supplies the series, the episode still comes inline")
    func sonarrLeanSeriesWithMetadata() throws {
        let r = try record("""
        {"id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2, "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500,
         "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3, "title": "The Episode"}}
        """)
        let meta = ArrCompositions.EntityMeta(title: "Series", year: 2019, slug: "series", poster: URL(string: "https://img.example.com/s.jpg"))
        let item = item(r, .sonarr, meta: [3: meta])
        #expect(item.title == "Series (2019)")
        #expect(item.subtitle == "S02E03 · The Episode")
        #expect(item.episodeNumber == 3)
        #expect(item.seasonNumber == 2)
        #expect(item.contentSlug == "series")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/s.jpg")
    }

    @Test("Sonarr: without embedded objects the title, subtitle and episode ids are lost")
    func sonarrLeanShape() throws {
        let r = try record(#"{"id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2, "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500}"#)
        let item = item(r, .sonarr)
        #expect(item.title == "Series.S02E03.1080p")
        #expect(item.subtitle == nil)
        #expect(item.seasonNumber == nil)
        #expect(item.episodeNumber == nil)
        #expect(item.posterURL == nil)
    }

    @Test("Sonarr: the episode's own file is picked out of the series' files")
    func sonarrEpisodeFile() throws {
        let r = try record(#"{"id": 9, "seriesId": 3, "title": "S.S02E03", "size": 10, "sizeleft": 5, "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3, "episodeFileId": 501}}"#)
        let decoded = try files(#"[{"id": 500, "seriesId": 3, "size": 1}, {"id": 501, "seriesId": 3, "size": 2, "relativePath": "S02/e03.mkv", "quality": {"quality": {"name": "HDTV-720p"}}}]"#)
        let item = item(r, .sonarr, files: [3: decoded])
        #expect(item.isUpgrade && item.existingSize == 2 && item.existingQuality == "HDTV-720p" && item.existingFileName == "e03.mkv")
    }
}
