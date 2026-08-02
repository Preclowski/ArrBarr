import Testing
import Foundation
@testable import ArrCore

// `unify` is where every field a queue row displays is decided — title,
// subtitle, poster, deep-link slug, upgrade diff — and until this file existed
// nothing in the suite reached it. The wire-decoding suites stop at the decoded
// record, and the view-model / grouping suites build `QueueItem` values by hand,
// so the whole mapping in between could be changed freely with 581 tests still
// green. That gap matters now: the queue clients are moving off Servarr's
// embedded `series` / `movie` / `artist` / `album` objects and onto a metadata
// store, which changes where almost every one of these fields comes from.
//
// So each source is pinned twice: once with the embedded object present (what
// `include*=true` returns today) and once without it (what the lean queue
// returns, which is also exactly what an unknown-to-the-arr download has always
// looked like). The second case is the fallback the metadata store has to beat.

@Suite("Queue unification")
struct QueueUnificationTests {

    // MARK: - Lidarr

    private func lidarrPage(_ recordJSON: String) throws -> LidarrQueueRecord {
        let json = """
        {"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [\(recordJSON)]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        return try #require(page.records.first)
    }

    /// The shape `includeArtist=true&includeAlbum=true` returns today.
    @Test("Lidarr: embedded artist + album give the display title, poster and slug")
    func lidarrWithEmbeddedObjects() throws {
        let r = try lidarrPage("""
        {
          "id": 12, "artistId": 7, "albumId": 15,
          "title": "Example Artist - Example Album [FLAC]",
          "status": "downloading", "trackedDownloadState": "downloading",
          "size": 524288000, "sizeleft": 131072000,
          "artist": {
            "id": 7, "artistName": "Example Artist",
            "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/artist.jpg"}]
          },
          "album": {
            "id": 15, "title": "Example Album",
            "foreignAlbumId": "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
            "images": [{"coverType": "cover", "remoteUrl": "https://img.example.com/cover.jpg"}]
          }
        }
        """)
        let item = LidarrClient.unify(r, baseURL: "http://lidarr.local:8686", fileMap: [:])

        #expect(item.title == "Example Artist — Example Album")
        #expect(item.releaseName == "Example Artist - Example Album [FLAC]")
        #expect(item.entityId == 15)
        #expect(item.contentSlug == "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
        // Album cover wins over the artist image — the row is about the album.
        #expect(item.posterURL?.absoluteString == "https://img.example.com/cover.jpg")
        #expect(item.posterRequiresAuth == false)
        #expect(item.isUpgrade == false)
    }

    /// The album has no cover of its own, so the artist image stands in.
    @Test("Lidarr: artist image is the poster fallback when the album has none")
    func lidarrArtistPosterFallback() throws {
        let r = try lidarrPage("""
        {
          "id": 13, "albumId": 16, "title": "Rel",
          "artist": {"id": 7, "artistName": "A",
            "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/artist.jpg"}]},
          "album": {"id": 16, "title": "B"}
        }
        """)
        let item = LidarrClient.unify(r, baseURL: "http://lidarr.local:8686", fileMap: [:])
        #expect(item.posterURL?.absoluteString == "https://img.example.com/artist.jpg")
    }

    /// The lean shape: no `artist` / `album` objects, only the top-level ids.
    /// Everything the embedded objects fed degrades to the release name, and the
    /// poster and deep link disappear. This is the baseline the metadata store
    /// exists to lift — when it lands, this test's expectations are what change.
    @Test("Lidarr: without embedded objects the row degrades to the release name")
    func lidarrLeanShape() throws {
        let r = try lidarrPage("""
        {
          "id": 12, "artistId": 7, "albumId": 15,
          "title": "Example Artist - Example Album [FLAC]",
          "status": "downloading", "size": 524288000, "sizeleft": 131072000
        }
        """)
        let item = LidarrClient.unify(r, baseURL: "http://lidarr.local:8686", fileMap: [:])

        #expect(item.title == "Example Artist - Example Album [FLAC]")
        #expect(item.posterURL == nil)
        #expect(item.contentSlug == nil)
        // The foreign key survives — it is top-level on the queue resource, and
        // it is what the metadata store will be keyed on.
        #expect(item.entityId == 15)
    }

    /// The shape the queue actually returns now: no embedded objects, with the
    /// title, artist, artwork and slug joined back on from `TitleMetadataStore`.
    /// This is the pair to `lidarrLeanShape` — same wire record, and the only
    /// difference is whether the metadata was resolved.
    @Test("Lidarr: store metadata restores everything the lean record dropped")
    func lidarrLeanShapeWithMetadata() throws {
        let r = try lidarrPage("""
        {
          "id": 12, "artistId": 7, "albumId": 15,
          "title": "Example Artist - Example Album [FLAC]",
          "status": "downloading", "size": 524288000, "sizeleft": 131072000
        }
        """)
        let meta = TitleMetadataStore.Metadata(
            title: "Example Album",
            secondary: "Example Artist",
            slug: "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
            posterURL: URL(string: "https://img.example.com/cover.jpg"),
            posterRequiresAuth: false
        )
        let item = LidarrClient.unify(
            r, baseURL: "http://lidarr.local:8686", fileMap: [:], meta: [15: meta]
        )

        // Byte-for-byte what the embedded-object path produced.
        #expect(item.title == "Example Artist — Example Album")
        #expect(item.contentSlug == "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/cover.jpg")
        #expect(item.releaseName == "Example Artist - Example Album [FLAC]")
    }

    /// The store wins over an embedded object when both are somehow present, so
    /// there is one source of truth rather than two that can disagree.
    @Test("Lidarr: store metadata takes precedence over an embedded album")
    func lidarrMetadataBeatsEmbedded() throws {
        let r = try lidarrPage("""
        {"id": 12, "albumId": 15, "title": "Rel",
         "album": {"id": 15, "title": "Stale Album"},
         "artist": {"id": 7, "artistName": "Stale Artist"}}
        """)
        let meta = TitleMetadataStore.Metadata(title: "Fresh Album", secondary: "Fresh Artist")
        let item = LidarrClient.unify(
            r, baseURL: "http://l", fileMap: [:], meta: [15: meta]
        )
        #expect(item.title == "Fresh Artist — Fresh Album")
    }

    /// An album's "existing file" is N track files aggregated, not one file.
    @Test("Lidarr: track files aggregate into an album-level upgrade diff")
    func lidarrUpgradeDiff() throws {
        let r = try lidarrPage("""
        {"id": 12, "albumId": 15, "title": "Rel", "album": {"id": 15, "title": "B"}}
        """)
        let files = """
        [{"id": 1, "albumId": 15, "size": 1000, "quality": {"quality": {"name": "MP3-320"}}},
         {"id": 2, "albumId": 15, "size": 3000, "quality": {"quality": {"name": "MP3-320"}}}]
        """
        let decoded = try JSONDecoder().decode([LidarrTrackFile].self, from: Data(files.utf8))
        let item = LidarrClient.unify(r, baseURL: "http://l", fileMap: [15: decoded])

        #expect(item.isUpgrade == true)
        #expect(item.existingSize == 4000)
        // Representative = the largest track, not the first.
        #expect(item.existingQuality == "MP3-320")
        // An album has no single old filename, the way a movie does.
        #expect(item.existingFileName == nil)
    }

    // MARK: - Radarr

    private func radarrRecord(_ recordJSON: String) throws -> RadarrQueueRecord {
        let json = """
        {"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [\(recordJSON)]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: Data(json.utf8))
        return try #require(page.records.first)
    }

    @Test("Radarr: embedded movie gives a year-stamped title and poster")
    func radarrWithEmbeddedMovie() throws {
        let r = try radarrRecord("""
        {
          "id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL",
          "size": 1000, "sizeleft": 250,
          "movie": {"id": 42, "title": "Movie", "year": 2024, "titleSlug": "movie-2024",
            "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/m.jpg"}]}
        }
        """)
        let item = RadarrClient.unify(r, baseURL: "http://radarr.local:7878", fileMap: [:])

        #expect(item.title == "Movie (2024)")
        #expect(item.releaseName == "Movie.2024.1080p.WEB-DL")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/m.jpg")
        #expect(item.progress == 0.75)
    }

    @Test("Radarr: without the embedded movie the row degrades to the release name")
    func radarrLeanShape() throws {
        let r = try radarrRecord("""
        {"id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL", "size": 1000, "sizeleft": 250}
        """)
        let item = RadarrClient.unify(r, baseURL: "http://radarr.local:7878", fileMap: [:])

        #expect(item.title == "Movie.2024.1080p.WEB-DL")
        #expect(item.posterURL == nil)
        #expect(item.entityId == 42)
    }

    @Test("Radarr: store metadata restores the year-stamped title, poster and slug")
    func radarrLeanShapeWithMetadata() throws {
        let r = try radarrRecord("""
        {"id": 5, "movieId": 42, "title": "Movie.2024.1080p.WEB-DL", "size": 1000, "sizeleft": 250}
        """)
        let meta = TitleMetadataStore.Metadata(
            title: "Movie", year: 2024, slug: "movie-2024",
            posterURL: URL(string: "https://img.example.com/m.jpg")
        )
        let item = RadarrClient.unify(
            r, baseURL: "http://radarr.local:7878", fileMap: [:], meta: [42: meta]
        )
        #expect(item.title == "Movie (2024)")
        #expect(item.contentSlug == "movie-2024")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/m.jpg")
    }

    // MARK: - Sonarr

    private func sonarrRecord(_ recordJSON: String) throws -> SonarrQueueRecord {
        let json = """
        {"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [\(recordJSON)]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: Data(json.utf8))
        return try #require(page.records.first)
    }

    @Test("Sonarr: embedded series + episode give the title and the SxxExx subtitle")
    func sonarrWithEmbeddedObjects() throws {
        let r = try sonarrRecord("""
        {
          "id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2,
          "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500,
          "series": {"id": 3, "title": "Series", "year": 2019, "titleSlug": "series",
            "images": [{"coverType": "poster", "remoteUrl": "https://img.example.com/s.jpg"}]},
          "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3, "title": "The Episode"}
        }
        """)
        let item = SonarrClient.unify(r, baseURL: "http://sonarr.local:8989", fileMap: [:])

        #expect(item.title == "Series (2019)")
        #expect(item.subtitle == "S02E03 · The Episode")
        #expect(item.seasonNumber == 2)
        #expect(item.episodeNumber == 3)
        #expect(item.episodeTitle == "The Episode")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/s.jpg")
    }

    /// The shape the Sonarr queue returns now: `includeSeries` gone but
    /// `includeEpisode` kept, so the series comes from the store while the
    /// episode — whose `episodeNumber` gates the drill-down and whose
    /// `episodeFileId` joins the on-disk file — still arrives on the wire.
    @Test("Sonarr: store metadata supplies the series, the episode still comes inline")
    func sonarrLeanSeriesWithMetadata() throws {
        let r = try sonarrRecord("""
        {
          "id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2,
          "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500,
          "episode": {"id": 88, "seasonNumber": 2, "episodeNumber": 3, "title": "The Episode"}
        }
        """)
        let meta = TitleMetadataStore.Metadata(
            title: "Series", year: 2019, slug: "series",
            posterURL: URL(string: "https://img.example.com/s.jpg")
        )
        let item = SonarrClient.unify(
            r, baseURL: "http://sonarr.local:8989", fileMap: [:], meta: [3: meta]
        )
        #expect(item.title == "Series (2019)")
        #expect(item.subtitle == "S02E03 · The Episode")
        // The drill-down gate — `PopoverContentView` routes on `episodeNumber > 0`.
        #expect(item.episodeNumber == 3)
        #expect(item.seasonNumber == 2)
        #expect(item.contentSlug == "series")
        #expect(item.posterURL?.absoluteString == "https://img.example.com/s.jpg")
    }

    /// Note what is lost here beyond the title: `seasonNumber` and
    /// `episodeNumber` go nil, and `PopoverContentView` routes to the episode
    /// drill-down on `episodeNumber > 0`. A lean Sonarr queue therefore has to
    /// restore those from somewhere, or rows silently open the wrong view.
    @Test("Sonarr: without embedded objects the title, subtitle and episode ids are lost")
    func sonarrLeanShape() throws {
        let r = try sonarrRecord("""
        {
          "id": 9, "seriesId": 3, "episodeId": 88, "seasonNumber": 2,
          "title": "Series.S02E03.1080p", "size": 1000, "sizeleft": 500
        }
        """)
        let item = SonarrClient.unify(r, baseURL: "http://sonarr.local:8989", fileMap: [:])

        #expect(item.title == "Series.S02E03.1080p")
        #expect(item.subtitle == nil)
        #expect(item.seasonNumber == nil)
        #expect(item.episodeNumber == nil)
        #expect(item.posterURL == nil)
    }
}
