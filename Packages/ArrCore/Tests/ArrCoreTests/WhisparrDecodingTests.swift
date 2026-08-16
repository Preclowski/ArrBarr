import Testing
import Foundation
@testable import ArrCore

// Whisparr is a Radarr fork, so its wire shapes track Radarr's — which is
// exactly why it needs its own fixtures: it is the arr most likely to drift
// from the upstream it was forked from, and nothing else in the suite would
// notice. Every record here is deliberately *incomplete* somewhere, because
// the wire models are almost entirely optional on purpose: a bare {"id": N}
// has to survive decoding rather than take the whole page down with it.

@Suite("Whisparr queue decoding")
struct WhisparrQueueDecodingTests {
    /// A grab in flight on a scene the user already has on disk — the shape
    /// that drives every field of a queue row, including the upgrade diff
    /// Whisparr can serve inline because `includeMovie=true` embeds
    /// `movieFile`.
    @Test("Decodes a full queue page with the embedded movie and its on-disk file")
    func fullQueuePage() throws {
        let json = """
        {
          "page": 1,
          "pageSize": 1000,
          "totalRecords": 1,
          "records": [{
            "id": 7,
            "movieId": 31,
            "title": "Studio.Scene.Title.2024.1080p.WEB-DL",
            "status": "downloading",
            "trackedDownloadStatus": "ok",
            "trackedDownloadState": "downloading",
            "downloadId": "0123456789ABCDEF",
            "downloadClient": "qBittorrent",
            "indexer": "ExampleIndexer (Prowlarr)",
            "protocol": "torrent",
            "size": 3221225472.0,
            "sizeleft": 1610612736.0,
            "timeleft": "00:20:00",
            "estimatedCompletionTime": "2026-07-22T18:40:00Z",
            "customFormats": [{"id": 3, "name": "1080p Web"}],
            "customFormatScore": 25,
            "quality": {"quality": {"name": "WEBDL-1080p"}},
            "movie": {
              "id": 31,
              "title": "Scene Title",
              "year": 2024,
              "studio": "Example Studio",
              "hasFile": true,
              "titleSlug": "scene-title-2024",
              "images": [
                {"coverType": "poster", "url": "/MediaCover/31/poster.jpg",
                 "remoteUrl": "https://images.example.com/poster.jpg"}
              ],
              "movieFile": {
                "size": 2147483648,
                "relativePath": "Scene Title (2024)/Scene.Title.2024.720p.mkv",
                "quality": {"quality": {"name": "WEBDL-720p"}},
                "customFormats": [{"id": 9, "name": "720p Web"}],
                "customFormatScore": 5
              }
            }
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        #expect(page.totalRecords == 1)

        let r = try #require(page.records.first)
        #expect(r.id == 7)
        #expect(r.movieId == 31)
        #expect(r.title == "Studio.Scene.Title.2024.1080p.WEB-DL")
        #expect(r.downloadId == "0123456789ABCDEF")
        #expect(r.downloadClient == "qBittorrent")
        #expect(r.indexer == "ExampleIndexer (Prowlarr)")
        #expect(r.protocol == "torrent")
        #expect(r.size == 3_221_225_472)
        #expect(r.sizeleft == 1_610_612_736)
        #expect(r.timeleft == "00:20:00")
        #expect(r.quality?.name == "WEBDL-1080p")
        #expect(r.customFormatScore == 25)
        #expect(r.movie?.title == "Scene Title")
        #expect(r.movie?.studio == "Example Studio")
        #expect(r.movie?.titleSlug == "scene-title-2024")
        #expect(r.movie?.hasFile == true)

        // The upgrade diff: Whisparr embeds the file being replaced, so the
        // row can show "720p → 1080p" without a second round-trip.
        #expect(r.movie?.movieFile?.quality?.name == "WEBDL-720p")
        #expect(r.movie?.movieFile?.size == 2_147_483_648)
        #expect(r.movie?.movieFile?.customFormatScore == 5)
        #expect(r.movie?.movieFile?.relativePath == "Scene Title (2024)/Scene.Title.2024.720p.mkv")
    }

    /// The philosophy the whole wire layer is built on: nothing but `id` is
    /// guaranteed. A record that decoded strictly would drop the *page*, not
    /// the row, and the queue would look empty rather than degraded.
    @Test("A bare id-only record decodes with every other field nil")
    func minimalRecord() throws {
        let json = #"{"page":1,"pageSize":1000,"totalRecords":1,"records":[{"id":1}]}"#
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.id == 1)
        #expect(r.title == nil)
        #expect(r.movie == nil)
        #expect(r.movieId == nil)
        #expect(r.size == nil)
        #expect(r.sizeleft == nil)
        #expect(r.status == nil)
        #expect(r.protocol == nil)
        #expect(r.quality == nil)
        #expect(r.customFormats == nil)
        #expect(r.statusMessages == nil)
    }

    /// Whisparr serves unmatched grabs with `includeUnknownMovieItems=true`,
    /// so a record with no embedded movie is routine — the release title is
    /// then the only name the row has.
    @Test("A record with no embedded movie keeps the release title as its only name")
    func recordWithoutMovie() throws {
        let json = """
        {"page":1,"pageSize":1000,"totalRecords":1,"records":[
          {"id": 8, "title": "Unmatched.Release.2024.1080p", "status": "warning",
           "trackedDownloadStatus": "warning", "trackedDownloadState": "importBlocked"}
        ]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.movie == nil)
        #expect(r.title == "Unmatched.Release.2024.1080p")
        #expect(parseStatus(arrStatus: r.status,
                            trackedState: r.trackedDownloadState,
                            trackedStatus: r.trackedDownloadStatus) == .warning)
    }

    /// Both status-message shapes show up on the wire — a bare title, and a
    /// title with a nested message list — and the empty strings the arr pads
    /// them with must not reach the UI as blank rows.
    @Test("Status messages flatten to one user-facing line per real message")
    func statusMessagesFlatten() throws {
        let json = """
        {"page":1,"pageSize":1000,"totalRecords":1,"records":[{
          "id": 9,
          "statusMessages": [
            {"title": "Title mismatch"},
            {"title": "Sample check", "messages": ["Sample detected", "   "]},
            {"title": "", "messages": []}
          ]
        }]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        let lines = page.records[0].statusMessages.flattenToLines()
        #expect(lines == ["Title mismatch", "Sample check: Sample detected"])
    }

    /// The poster resolver prefers the remote (TMDB) URL because it needs no
    /// API key; the local `/MediaCover` path is the authenticated fallback.
    @Test("Poster resolution prefers the auth-free remote URL over the arr's own path")
    func posterPrefersRemote() throws {
        let json = """
        {"page":1,"pageSize":1000,"totalRecords":1,"records":[{
          "id": 10,
          "movie": {"id": 31, "title": "Scene Title", "images": [
            {"coverType": "fanart", "remoteUrl": "https://images.example.com/fanart.jpg"},
            {"coverType": "poster", "url": "/MediaCover/31/poster.jpg",
             "remoteUrl": "https://images.example.com/poster.jpg"}
          ]}
        }]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        let (poster, needsAuth) = (page.records[0].movie?.images ?? []).posterURL(baseURL: "http://localhost:6969")
        #expect(poster?.absoluteString == "https://images.example.com/poster.jpg")
        #expect(needsAuth == false)
    }

    @Test("A poster with only a local path resolves against the server and needs auth")
    func posterFallsBackToLocalPath() throws {
        let json = """
        {"page":1,"pageSize":1000,"totalRecords":1,"records":[{
          "id": 11,
          "movie": {"id": 31, "title": "Scene Title",
                    "images": [{"coverType": "poster", "url": "/MediaCover/31/poster.jpg?lastWrite=1"}]}
        }]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: Data(json.utf8))
        let (poster, needsAuth) = (page.records[0].movie?.images ?? []).posterURL(baseURL: "http://localhost:6969")
        #expect(poster?.absoluteString == "http://localhost:6969/MediaCover/31/poster.jpg")
        #expect(needsAuth == true)
    }
}

@Suite("Whisparr calendar decoding")
struct WhisparrCalendarDecodingTests {
    /// The calendar is a plain array, not a page — one of the shapes that
    /// silently differs from `/queue` and would break on a fork drift.
    @Test("Decodes a calendar array carrying all three release dates")
    func fullCalendarRecord() throws {
        let json = """
        [{
          "id": 55,
          "title": "Upcoming Scene",
          "year": 2026,
          "digitalRelease": "2026-08-01T00:00:00Z",
          "physicalRelease": "2026-08-15T00:00:00Z",
          "inCinemas": "2026-07-20T00:00:00Z",
          "hasFile": false,
          "overview": "A scene that has not aired yet",
          "runtime": 28,
          "studio": "Example Studio",
          "titleSlug": "upcoming-scene",
          "ratings": {"imdb": {"value": 7.4, "votes": 120}, "tmdb": {"value": 6.9, "votes": 340}},
          "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/poster.jpg"}]
        }]
        """
        let records = try JSONDecoder().decode([WhisparrCalendarRecord].self, from: Data(json.utf8))
        let r = try #require(records.first)

        #expect(r.id == 55)
        #expect(r.title == "Upcoming Scene")
        #expect(r.year == 2026)
        #expect(r.digitalRelease == "2026-08-01T00:00:00Z")
        #expect(r.physicalRelease == "2026-08-15T00:00:00Z")
        #expect(r.inCinemas == "2026-07-20T00:00:00Z")
        #expect(r.hasFile == false)
        #expect(r.runtime == 28)
        #expect(r.studio == "Example Studio")
        // The Upcoming row shows the IMDB score, so the nested ratings object
        // has to survive Whisparr's Radarr-shaped payload intact.
        #expect(r.ratings?.imdb?.value == 7.4)
    }

    @Test("A calendar record with only id and title decodes")
    func minimalCalendarRecord() throws {
        let records = try JSONDecoder().decode(
            [WhisparrCalendarRecord].self,
            from: Data(#"[{"id": 1, "title": "Scene"}]"#.utf8)
        )
        let r = try #require(records.first)

        #expect(r.id == 1)
        #expect(r.title == "Scene")
        #expect(r.year == nil)
        #expect(r.digitalRelease == nil)
        #expect(r.physicalRelease == nil)
        #expect(r.inCinemas == nil)
        #expect(r.hasFile == nil)
        #expect(r.ratings == nil)
        #expect(r.images == nil)
    }

    /// Whisparr ships release dates in both the full-instant and the
    /// calendar-day shape depending on the metadata source. Both have to
    /// parse, or the item silently vanishes from Upcoming — the client
    /// `compactMap`s away anything whose date it can't read.
    @Test("Both the instant and the date-only release shapes parse", arguments: [
        "2026-08-01T00:00:00Z", "2026-08-01",
    ])
    func releaseDateShapesParse(_ raw: String) throws {
        let json = #"[{"id": 1, "title": "Scene", "digitalRelease": "\#(raw)"}]"#
        let records = try JSONDecoder().decode([WhisparrCalendarRecord].self, from: Data(json.utf8))
        let dateString = try #require(records.first?.digitalRelease)
        #expect(parseArrDate(dateString) != nil)
    }
}

@Suite("Whisparr history decoding")
struct WhisparrHistoryDecodingTests {
    @Test("Decodes a history page with the movie, quality and custom formats")
    func fullHistoryPage() throws {
        let json = """
        {
          "page": 1, "pageSize": 50, "totalRecords": 1,
          "records": [{
            "id": 91,
            "movieId": 31,
            "sourceTitle": "Studio.Scene.Title.2024.1080p.WEB-DL",
            "date": "2026-07-20T09:15:00Z",
            "eventType": "downloadFolderImported",
            "quality": {"quality": {"name": "WEBDL-1080p"}},
            "customFormats": [{"id": 3, "name": "1080p Web"}],
            "customFormatScore": 25,
            "movie": {"id": 31, "title": "Scene Title", "year": 2024, "titleSlug": "scene-title-2024"}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrHistoryRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.id == 91)
        #expect(r.sourceTitle == "Studio.Scene.Title.2024.1080p.WEB-DL")
        #expect(r.movie?.title == "Scene Title")
        #expect(r.quality?.name == "WEBDL-1080p")
        #expect(r.customFormats?.first?.name == "1080p Web")
        #expect(r.customFormatScore == 25)
        #expect(HistoryItem.EventType.parse(r.eventType) == .imported)

        let dateString = try #require(r.date)
        #expect(parseArrDate(dateString) != nil)
    }

    /// An undated record decodes fine and is dropped a layer up — the model
    /// must not be the thing that fails, or one malformed row would cost the
    /// whole history page.
    @Test("A record with neither date nor event type decodes and maps to the catch-all event")
    func undatedHistoryRecord() throws {
        let json = #"{"page":1,"pageSize":50,"totalRecords":1,"records":[{"id":92}]}"#
        let page = try JSONDecoder().decode(ArrQueuePage<WhisparrHistoryRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.date == nil)
        #expect(r.movie == nil)
        #expect(r.sourceTitle == nil)
        #expect(HistoryItem.EventType.parse(r.eventType) == .other)
    }
}

@Suite("Whisparr lookup decoding and unification")
struct WhisparrLookupDecodingTests {
    private let baseURL = "http://localhost:6969"

    @Test("Decodes a lookup record and unifies it onto a TMDB-keyed search result")
    func lookupWithTmdbId() throws {
        let json = """
        [{
          "tmdbId": 987654,
          "foreignId": "example-scene-id",
          "title": "Scene Title",
          "year": 2024,
          "overview": "A scene",
          "runtime": 28,
          "studio": "Example Studio",
          "genres": ["Genre A", "Genre B"],
          "ratings": {"tmdb": {"value": 7.1, "votes": 500}},
          "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/poster.jpg"}]
        }]
        """
        let records = try JSONDecoder().decode([WhisparrLookupRecord].self, from: Data(json.utf8))
        let record = try #require(records.first)
        let result = try #require(SearchClient.unifyWhisparr(record, baseURL: baseURL))

        #expect(result.externalId == 987654)
        #expect(result.foreignId == "987654")
        #expect(result.title == "Scene Title")
        #expect(result.year == 2024)
        #expect(result.rating == 7.1)
        #expect(result.runtime == 28)
        #expect(result.genres == ["Genre A", "Genre B"])
        // Whisparr has studios where Radarr has them too, and Sonarr has
        // networks — they share the one `network` slot on SearchResult.
        #expect(result.network == "Example Studio")
        #expect(result.source == .whisparr)
        #expect(result.mediaRef == .tmdb(987654))
        #expect(result.posterURL?.absoluteString == "https://images.example.com/poster.jpg")
    }

    /// Whisparr v3 indexes scenes that have no TMDB entry at all and reports
    /// `tmdbId: 0` for them — a real id of zero, not a missing key. Treating
    /// it as present would collide every unmatched scene onto id 0.
    @Test("A zero or absent tmdbId falls back to the foreign id", arguments: [
        #"{"tmdbId": 0, "foreignId": "example-scene-id", "title": "Scene Title"}"#,
        #"{"foreignId": "example-scene-id", "title": "Scene Title"}"#,
    ])
    func lookupWithoutTmdbId(_ recordJSON: String) throws {
        let records = try JSONDecoder().decode([WhisparrLookupRecord].self, from: Data("[\(recordJSON)]".utf8))
        let record = try #require(records.first)
        let result = try #require(SearchClient.unifyWhisparr(record, baseURL: baseURL))

        #expect(result.foreignId == "example-scene-id")
        // The synthesized id only has to be non-negative and stable within a
        // run — it's derived from the foreign id's hash, which Swift seeds
        // per process, so its actual value is not a contract.
        #expect(result.externalId >= 0)
        let again = try #require(SearchClient.unifyWhisparr(record, baseURL: baseURL))
        #expect(again.externalId == result.externalId)
    }

    /// With no id of any kind there is nothing to add to the library or route
    /// a tap to, so the record is dropped rather than shown as an unusable row.
    @Test("A lookup record with no id of any kind is dropped")
    func lookupWithoutAnyId() throws {
        let records = try JSONDecoder().decode(
            [WhisparrLookupRecord].self,
            from: Data(#"[{"title": "Scene Title"}]"#.utf8)
        )
        let record = try #require(records.first)
        #expect(SearchClient.unifyWhisparr(record, baseURL: baseURL) == nil)
    }

    @Test("A lookup record with nothing but a title decodes")
    func minimalLookupRecord() throws {
        let records = try JSONDecoder().decode(
            [WhisparrLookupRecord].self,
            from: Data(#"[{"title": "Scene Title"}]"#.utf8)
        )
        let r = try #require(records.first)

        #expect(r.title == "Scene Title")
        #expect(r.tmdbId == nil)
        #expect(r.foreignId == nil)
        #expect(r.year == nil)
        #expect(r.ratings == nil)
        #expect(r.genres == nil)
        #expect(r.images == nil)
    }
}
