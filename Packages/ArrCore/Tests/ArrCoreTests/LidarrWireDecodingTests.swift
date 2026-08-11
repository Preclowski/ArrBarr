import Testing
import Foundation
@testable import ArrCore

// Complements the "Lidarr JSON Decoding" suite in JSONDecodingTests.swift,
// which covers the plain queue and calendar records. This file covers the
// shapes those tests don't reach: the artist/album nesting and images the
// queue unifier reads, the side-loaded track files that produce the
// album-level upgrade diff, the album/track detail payloads, history, and
// lookup.
//
// Lidarr is the odd arr out — /api/v1 instead of v3, albums instead of
// movies/episodes, and a queue that does *not* embed the on-disk files — so
// its wire shapes share almost nothing with the Radarr-derived clients and
// need to be pinned separately.

@Suite("Lidarr queue nesting")
struct LidarrQueueNestingTests {
    /// The full shape `includeArtist=true&includeAlbum=true` returns: artist
    /// at the top level *and* nested inside the album, plus cover art on both.
    @Test("Decodes a queue record with artist, album and cover art")
    func fullQueueRecord() throws {
        let json = """
        {
          "page": 1, "pageSize": 1000, "totalRecords": 1,
          "records": [{
            "id": 12,
            "artistId": 7,
            "albumId": 15,
            "title": "Example Artist - Example Album [FLAC]",
            "status": "downloading",
            "trackedDownloadStatus": "ok",
            "trackedDownloadState": "downloading",
            "downloadId": "SABnzbd_nzo_lid001",
            "downloadClient": "SABnzbd",
            "indexer": "ExampleIndexer",
            "protocol": "usenet",
            "size": 524288000,
            "sizeleft": 131072000,
            "timeleft": "00:03:20",
            "quality": {"quality": {"name": "FLAC"}},
            "artist": {
              "id": 7, "artistName": "Example Artist",
              "foreignArtistId": "a74b1b7f-71a5-4011-9441-d0b5e4122711",
              "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/artist.jpg"}]
            },
            "album": {
              "id": 15, "title": "Example Album",
              "releaseDate": "1997-06-16T00:00:00Z",
              "foreignAlbumId": "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
              "images": [{"coverType": "cover", "remoteUrl": "https://images.example.com/cover.jpg"}]
            },
            "statusMessages": [{"title": "Not a preferred word upgrade for existing album file(s)"}]
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.id == 12)
        #expect(r.albumId == 15)
        #expect(r.artist?.artistName == "Example Artist")
        #expect(r.artist?.foreignArtistId == "a74b1b7f-71a5-4011-9441-d0b5e4122711")
        #expect(r.album?.title == "Example Album")
        // The album's MBID is what the row carries as its content slug, so a
        // tap can deep-link to the album rather than the artist.
        #expect(r.album?.foreignAlbumId == "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
        #expect(r.quality?.name == "FLAC")
        #expect(r.protocol == "usenet")
        #expect(r.statusMessages.flattenToLines()
                == ["Not a preferred word upgrade for existing album file(s)"])
    }

    /// Lidarr answers some queue rows with the artist only inside the album,
    /// which is why the unifier reads `artist ?? album.artist` rather than
    /// just the top-level field — without the fallback those rows lose their
    /// artist name and render as a bare album title.
    @Test("An artist nested inside the album is still reachable when the top-level one is absent")
    func artistOnlyNestedInAlbum() throws {
        let json = """
        {
          "page": 1, "pageSize": 1000, "totalRecords": 1,
          "records": [{
            "id": 13,
            "albumId": 15,
            "title": "Example Artist - Example Album [FLAC]",
            "album": {
              "id": 15, "title": "Example Album",
              "artist": {"id": 7, "artistName": "Example Artist"}
            }
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.artist == nil)
        #expect(r.album?.artist?.artistName == "Example Artist")
    }

    /// Album art is a "cover", not a "poster" — the reverse of every other
    /// arr — so the resolver is asked for cover-first on the album and
    /// poster-first on the artist. Getting the order wrong shows the artist
    /// photo where the sleeve belongs.
    @Test("Album art resolves cover-first, artist art poster-first")
    func coverTypePreference() throws {
        let json = """
        {
          "page": 1, "pageSize": 1000, "totalRecords": 1,
          "records": [{
            "id": 14,
            "artist": {"id": 7, "artistName": "Example Artist", "images": [
              {"coverType": "banner", "remoteUrl": "https://images.example.com/banner.jpg"},
              {"coverType": "poster", "remoteUrl": "https://images.example.com/artist.jpg"}
            ]},
            "album": {"id": 15, "title": "Example Album", "images": [
              {"coverType": "cover", "remoteUrl": "https://images.example.com/cover.jpg"}
            ]}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        let (albumArt, _) = (r.album?.images ?? []).posterURL(baseURL: "http://localhost:8686",
                                                              coverTypes: ["cover", "poster"])
        let (artistArt, _) = (r.artist?.images ?? []).posterURL(baseURL: "http://localhost:8686",
                                                                coverTypes: ["poster", "cover"])
        #expect(albumArt?.absoluteString == "https://images.example.com/cover.jpg")
        #expect(artistArt?.absoluteString == "https://images.example.com/artist.jpg")
    }

    /// An album with no art at all is common for niche releases — the
    /// resolver has to answer "no poster" rather than pick an unrelated
    /// cover type.
    @Test("An album with no matching cover type resolves to no art")
    func noMatchingCoverType() throws {
        let json = """
        {"page":1,"pageSize":1000,"totalRecords":1,"records":[{
          "id": 16,
          "album": {"id": 15, "title": "Example Album",
                    "images": [{"coverType": "disc", "remoteUrl": "https://images.example.com/disc.jpg"}]}
        }]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        let (art, needsAuth) = (page.records[0].album?.images ?? []).posterURL(
            baseURL: "http://localhost:8686", coverTypes: ["cover", "poster"]
        )
        #expect(art == nil)
        #expect(needsAuth == false)
    }
}

@Suite("Lidarr track-file decoding")
struct LidarrTrackFileDecodingTests {
    /// `/trackfile?albumId=N` — the side-load that gives an album grab its
    /// upgrade diff. Lidarr's queue never embeds these, so they're fetched
    /// per album and aggregated into album-level "existing file" fields.
    @Test("Decodes the side-loaded track files an album upgrade diffs against")
    func fullTrackFiles() throws {
        let json = """
        [
          {"id": 101, "albumId": 15, "size": 41943040,
           "quality": {"quality": {"name": "MP3-320"}},
           "customFormats": [{"id": 2, "name": "Lossy"}],
           "customFormatScore": 10},
          {"id": 102, "albumId": 15, "size": 39845888,
           "quality": {"quality": {"name": "MP3-320"}},
           "customFormats": [], "customFormatScore": 10}
        ]
        """
        let files = try JSONDecoder().decode([LidarrTrackFile].self, from: Data(json.utf8))
        #expect(files.count == 2)
        #expect(files[0].albumId == 15)
        #expect(files[0].size == 41_943_040)
        #expect(files[0].quality?.name == "MP3-320")
        #expect(files[0].customFormats?.first?.name == "Lossy")
        #expect(files[0].customFormatScore == 10)
        #expect(files[1].customFormats?.isEmpty == true)
    }

    /// An album whose files predate a Lidarr rescan can be missing quality,
    /// score and even size. The diff then shows less, which is the point —
    /// a strict model would drop the whole side-load and the row would claim
    /// there was nothing on disk at all.
    @Test("A track file with nothing but an id decodes")
    func minimalTrackFile() throws {
        let files = try JSONDecoder().decode([LidarrTrackFile].self, from: Data(#"[{"id": 103}]"#.utf8))
        let f = try #require(files.first)

        #expect(f.id == 103)
        #expect(f.albumId == nil)
        #expect(f.size == nil)
        #expect(f.quality == nil)
        #expect(f.customFormats == nil)
        #expect(f.customFormatScore == nil)
    }

    @Test("An album with no files on disk decodes as an empty array")
    func emptyTrackFiles() throws {
        let files = try JSONDecoder().decode([LidarrTrackFile].self, from: Data("[]".utf8))
        #expect(files.isEmpty)
    }
}

@Suite("Lidarr album and track shapes")
struct LidarrAlbumShapeTests {
    @Test("Decodes a full album detail payload")
    func fullAlbumDetail() throws {
        let json = """
        {
          "id": 15,
          "title": "Example Album",
          "overview": "The third studio album",
          "releaseDate": "1997-06-16T00:00:00Z",
          "genres": ["Alternative Rock"],
          "ratings": {"value": 8.9, "votes": 1200},
          "albumType": "Album",
          "duration": 3196000,
          "foreignAlbumId": "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29",
          "artist": {"id": 7, "artistName": "Example Artist",
                     "foreignArtistId": "a74b1b7f-71a5-4011-9441-d0b5e4122711"},
          "statistics": {"trackCount": 12, "trackFileCount": 12,
                         "totalTrackCount": 12, "sizeOnDisk": 419430400},
          "images": [{"coverType": "cover", "remoteUrl": "https://images.example.com/cover.jpg"}]
        }
        """
        let album = try JSONDecoder().decode(LidarrAlbumDetail.self, from: Data(json.utf8))

        #expect(album.id == 15)
        #expect(album.title == "Example Album")
        #expect(album.albumType == "Album")
        // Lidarr reports album duration in milliseconds, not seconds.
        #expect(album.duration == 3_196_000)
        #expect(album.ratings?.value == 8.9)
        #expect(album.ratings?.votes == 1200)
        #expect(album.artist?.artistName == "Example Artist")
        #expect(album.statistics?.trackCount == 12)
        #expect(album.statistics?.sizeOnDisk == 419_430_400)
        #expect(album.genres == ["Alternative Rock"])
    }

    @Test("An album detail with only id and title decodes")
    func minimalAlbumDetail() throws {
        let album = try JSONDecoder().decode(
            LidarrAlbumDetail.self,
            from: Data(#"{"id": 1, "title": "Untitled"}"#.utf8)
        )
        #expect(album.id == 1)
        #expect(album.artist == nil)
        #expect(album.ratings == nil)
        #expect(album.statistics == nil)
        #expect(album.releaseDate == nil)
        #expect(album.images == nil)
    }

    @Test("Decodes the slim album list an artist's discography uses")
    func albumListRecords() throws {
        let json = """
        [
          {"id": 15, "title": "Example Album", "albumType": "Album",
           "releaseDate": "1997-06-16T00:00:00Z", "monitored": true,
           "statistics": {"trackCount": 12, "trackFileCount": 12, "sizeOnDisk": 419430400}},
          {"id": 16, "title": "Follow-up"}
        ]
        """
        let albums = try JSONDecoder().decode([LidarrAlbumListRecord].self, from: Data(json.utf8))

        #expect(albums.count == 2)
        #expect(albums[0].albumType == "Album")
        #expect(albums[0].monitored == true)
        #expect(albums[0].statistics?.trackFileCount == 12)
        // An album Lidarr hasn't scanned yet has no statistics at all — the
        // list still has to render it, just without the "N tracks" line.
        #expect(albums[1].statistics == nil)
        #expect(albums[1].monitored == nil)
        #expect(albums[1].releaseDate == nil)
    }

    /// `trackNumber` is a **string**, not an int: vinyl and multi-disc
    /// releases number their sides "A1" / "B2", which is why the model can't
    /// declare it numeric. `absoluteTrackNumber` is the int for ordering.
    @Test("Track numbers decode as strings so vinyl side labels survive")
    func trackNumbersAreStrings() throws {
        let json = """
        [
          {"id": 501, "trackNumber": "A1", "absoluteTrackNumber": 1,
           "title": "Opening Track", "duration": 264000, "mediumNumber": 1, "hasFile": true},
          {"id": 502, "trackNumber": "3", "absoluteTrackNumber": 3,
           "title": "Third Track", "duration": 198000, "mediumNumber": 1, "hasFile": false}
        ]
        """
        let tracks = try JSONDecoder().decode([LidarrTrackDetail].self, from: Data(json.utf8))

        #expect(tracks[0].trackNumber == "A1")
        #expect(tracks[0].absoluteTrackNumber == 1)
        #expect(tracks[0].duration == 264_000)
        #expect(tracks[0].hasFile == true)
        #expect(tracks[1].trackNumber == "3")
        #expect(tracks[1].hasFile == false)
    }

    @Test("A track with nothing but an id decodes")
    func minimalTrack() throws {
        let tracks = try JSONDecoder().decode([LidarrTrackDetail].self, from: Data(#"[{"id": 503}]"#.utf8))
        let t = try #require(tracks.first)

        #expect(t.id == 503)
        #expect(t.trackNumber == nil)
        #expect(t.title == nil)
        #expect(t.duration == nil)
        #expect(t.hasFile == nil)
    }
}

@Suite("Lidarr history decoding")
struct LidarrHistoryDecodingTests {
    @Test("Decodes a history page carrying both the artist and the album")
    func fullHistoryPage() throws {
        let json = """
        {
          "page": 1, "pageSize": 50, "totalRecords": 1,
          "records": [{
            "id": 77,
            "albumId": 15,
            "artistId": 7,
            "sourceTitle": "Example Artist - Example Album [FLAC]",
            "date": "2026-07-19T22:05:00Z",
            "eventType": "grabbed",
            "quality": {"quality": {"name": "FLAC"}},
            "customFormats": [{"id": 2, "name": "Lossless"}],
            "customFormatScore": 40,
            "artist": {"id": 7, "artistName": "Example Artist"},
            "album": {"id": 15, "title": "Example Album"}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrHistoryRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.id == 77)
        #expect(r.artist?.artistName == "Example Artist")
        // Lidarr rows are titled by artist and subtitled by album — the one
        // history shape where the subtitle isn't optional decoration.
        #expect(r.album?.title == "Example Album")
        #expect(r.quality?.name == "FLAC")
        #expect(r.customFormatScore == 40)
        #expect(HistoryItem.EventType.parse(r.eventType) == .grabbed)

        let dateString = try #require(r.date)
        #expect(parseArrDate(dateString) != nil)
    }

    /// Lidarr spells its import event `trackFileImported`, which is neither
    /// of the names Radarr and Sonarr use — `EventType.parse` maps it to
    /// `.imported` so per-track rows can fold into album batches.
    @Test("An import event decodes with Lidarr's own event name")
    func importEventName() throws {
        let json = """
        {"page":1,"pageSize":50,"totalRecords":1,"records":[
          {"id": 78, "sourceTitle": "Example Artist - Example Album [FLAC]",
           "downloadId": "abc123", "date": "2026-07-19T22:11:00Z",
           "eventType": "trackFileImported"}
        ]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrHistoryRecord>.self, from: Data(json.utf8))
        #expect(page.records.first?.eventType == "trackFileImported")
        #expect(page.records.first?.downloadId == "abc123")
        #expect(HistoryItem.EventType.parse(page.records.first?.eventType) == .imported)
    }

    @Test("A history record with nothing but an id decodes")
    func minimalHistoryRecord() throws {
        let json = #"{"page":1,"pageSize":50,"totalRecords":1,"records":[{"id":79}]}"#
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrHistoryRecord>.self, from: Data(json.utf8))
        let r = try #require(page.records.first)

        #expect(r.date == nil)
        #expect(r.artist == nil)
        #expect(r.album == nil)
        #expect(r.sourceTitle == nil)
        #expect(HistoryItem.EventType.parse(r.eventType) == .other)
    }
}

@Suite("Lidarr calendar decoding")
struct LidarrCalendarArtTests {
    /// The calendar row falls back to the artist's photo when the album has
    /// no sleeve yet — unreleased albums usually don't.
    @Test("A calendar record carries album art, artist art, or neither")
    func calendarArtFallback() throws {
        let json = """
        [
          {"id": 91, "title": "Album With Cover", "releaseDate": "2026-08-01",
           "images": [{"coverType": "cover", "remoteUrl": "https://images.example.com/cover.jpg"}],
           "artist": {"id": 7, "artistName": "Example Artist",
                      "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/artist.jpg"}]}},
          {"id": 92, "title": "Album Without Cover", "releaseDate": "2026-08-08",
           "artist": {"id": 7, "artistName": "Example Artist",
                      "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/artist.jpg"}]}},
          {"id": 93, "title": "Album With No Art At All", "releaseDate": "2026-08-15"}
        ]
        """
        let records = try JSONDecoder().decode([LidarrCalendarRecord].self, from: Data(json.utf8))
        #expect(records.count == 3)

        #expect(records[0].images?.first?.coverType == "cover")
        #expect(records[1].images == nil)
        #expect(records[1].artist?.images?.first?.remoteUrl == "https://images.example.com/artist.jpg")
        #expect(records[2].images == nil)
        #expect(records[2].artist == nil)
    }

    /// Lidarr ships release dates as calendar days, not instants — the shape
    /// `parseArrDate` anchors at *local* midnight so today's releases don't
    /// disappear for anyone west of Greenwich.
    @Test("A date-only release date parses")
    func dateOnlyReleaseDate() throws {
        let records = try JSONDecoder().decode(
            [LidarrCalendarRecord].self,
            from: Data(#"[{"id": 94, "title": "Example Album", "releaseDate": "2026-08-01"}]"#.utf8)
        )
        let releaseDate = try #require(records.first?.releaseDate)
        #expect(parseArrDate(releaseDate) != nil)
    }
}

@Suite("Lidarr lookup decoding and unification")
struct LidarrLookupDecodingTests {
    private let baseURL = "http://localhost:8686"

    /// Lidarr's search is artist-level, so the unified result is keyed by
    /// MusicBrainz id rather than a numeric one — the only source whose
    /// `MediaRef` carries a string.
    @Test("Decodes an artist lookup record and unifies it onto a MusicBrainz-keyed result")
    func fullLookupRecord() throws {
        let json = """
        [{
          "foreignArtistId": "a74b1b7f-71a5-4011-9441-d0b5e4122711",
          "artistName": "Example Artist",
          "disambiguation": "English rock band",
          "overview": "Formed in 1985",
          "genres": ["Alternative Rock", "Art Rock"],
          "ratings": {"value": 9.0},
          "images": [{"coverType": "poster", "remoteUrl": "https://images.example.com/artist.jpg"}]
        }]
        """
        let records = try JSONDecoder().decode([LidarrLookupRecord].self, from: Data(json.utf8))
        let record = try #require(records.first)
        let result = try #require(SearchClient.unifyLidarr(record, baseURL: baseURL))

        #expect(result.title == "Example Artist")
        // The disambiguation is what keeps two same-named artists apart, so
        // it becomes the row's subtitle rather than being dropped.
        #expect(result.subtitle == "English rock band")
        #expect(result.foreignId == "a74b1b7f-71a5-4011-9441-d0b5e4122711")
        #expect(result.mediaRef == .musicBrainz("a74b1b7f-71a5-4011-9441-d0b5e4122711"))
        #expect(result.source == .lidarr)
        #expect(result.rating == 9.0)
        #expect(result.genres == ["Alternative Rock", "Art Rock"])
        #expect(result.posterURL?.absoluteString == "https://images.example.com/artist.jpg")
        // Artists have no release year and no runtime — both stay nil rather
        // than being faked from the first album.
        #expect(result.year == nil)
        #expect(result.runtime == nil)
    }

    /// MusicBrainz is the only identity Lidarr has for an artist; without it
    /// there's nothing to add or route to, so the record is dropped.
    @Test("A lookup record with a missing or empty MusicBrainz id is dropped", arguments: [
        #"{"artistName": "Example Artist"}"#,
        #"{"foreignArtistId": "", "artistName": "Example Artist"}"#,
    ])
    func lookupWithoutMusicBrainzId(_ recordJSON: String) throws {
        let records = try JSONDecoder().decode(
            [LidarrLookupRecord].self, from: Data("[\(recordJSON)]".utf8)
        )
        let record = try #require(records.first)
        #expect(SearchClient.unifyLidarr(record, baseURL: baseURL) == nil)
    }

    @Test("A lookup record with only an id and a name decodes and unifies")
    func minimalLookupRecord() throws {
        let records = try JSONDecoder().decode(
            [LidarrLookupRecord].self,
            from: Data(#"[{"foreignArtistId": "mbid-1", "artistName": "Example Artist"}]"#.utf8)
        )
        let record = try #require(records.first)

        #expect(record.disambiguation == nil)
        #expect(record.ratings == nil)
        #expect(record.genres == nil)
        #expect(record.images == nil)

        let result = try #require(SearchClient.unifyLidarr(record, baseURL: baseURL))
        #expect(result.subtitle == nil)
        #expect(result.rating == nil)
        #expect(result.genres.isEmpty)
        #expect(result.posterURL == nil)
    }
}
