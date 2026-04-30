import Testing
import Foundation
@testable import ArrBarr

@Suite("Radarr JSON Decoding")
struct RadarrDecodingTests {
    @Test("Decodes full queue page with movie metadata")
    func fullQueuePage() throws {
        let json = """
        {
            "page": 1,
            "pageSize": 10,
            "totalRecords": 1,
            "records": [{
                "id": 42,
                "movieId": 100,
                "title": "Movie.2024.1080p.WEB-DL",
                "status": "downloading",
                "trackedDownloadStatus": "ok",
                "trackedDownloadState": "downloading",
                "downloadId": "SABnzbd_nzo_abc123",
                "downloadClient": "SABnzbd",
                "protocol": "usenet",
                "size": 5000000000.0,
                "sizeleft": 2500000000.0,
                "timeleft": "01:30:00",
                "customFormats": [{"id": 1, "name": "IMAX"}, {"id": 2, "name": "DV"}],
                "customFormatScore": 150,
                "quality": {"quality": {"name": "Bluray-1080p"}},
                "movie": {
                    "id": 100,
                    "title": "Test Movie",
                    "year": 2024,
                    "originalTitle": "Original Title",
                    "hasFile": false,
                    "titleSlug": "test-movie-2024"
                }
            }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: Data(json.utf8))

        #expect(page.page == 1)
        #expect(page.pageSize == 10)
        #expect(page.totalRecords == 1)
        #expect(page.records.count == 1)

        let r = page.records[0]
        #expect(r.id == 42)
        #expect(r.movieId == 100)
        #expect(r.title == "Movie.2024.1080p.WEB-DL")
        #expect(r.status == "downloading")
        #expect(r.trackedDownloadState == "downloading")
        #expect(r.downloadId == "SABnzbd_nzo_abc123")
        #expect(r.downloadClient == "SABnzbd")
        #expect(r.protocol == "usenet")
        #expect(r.size == 5_000_000_000)
        #expect(r.sizeleft == 2_500_000_000)
        #expect(r.timeleft == "01:30:00")
        #expect(r.customFormats?.count == 2)
        #expect(r.customFormats?[0].name == "IMAX")
        #expect(r.customFormatScore == 150)
        #expect(r.quality?.name == "Bluray-1080p")
        #expect(r.movie?.title == "Test Movie")
        #expect(r.movie?.year == 2024)
        #expect(r.movie?.hasFile == false)
        #expect(r.movie?.titleSlug == "test-movie-2024")
    }

    @Test("Decodes record with all optional fields missing")
    func minimalRecord() throws {
        let json = """
        {"page":1,"pageSize":10,"totalRecords":1,"records":[{"id":1}]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: Data(json.utf8))
        let r = page.records[0]

        #expect(r.id == 1)
        #expect(r.title == nil)
        #expect(r.movie == nil)
        #expect(r.size == nil)
        #expect(r.sizeleft == nil)
        #expect(r.downloadId == nil)
        #expect(r.protocol == nil)
        #expect(r.customFormats == nil)
        #expect(r.quality == nil)
    }

    @Test("Decodes calendar record with release dates")
    func calendarRecord() throws {
        let json = """
        {
            "id": 50,
            "title": "Upcoming Movie",
            "year": 2024,
            "digitalRelease": "2024-06-15T00:00:00Z",
            "physicalRelease": "2024-07-01T00:00:00Z",
            "inCinemas": "2024-03-01T00:00:00Z",
            "hasFile": false,
            "overview": "A great movie about testing"
        }
        """
        let r = try JSONDecoder().decode(RadarrCalendarRecord.self, from: Data(json.utf8))

        #expect(r.id == 50)
        #expect(r.title == "Upcoming Movie")
        #expect(r.year == 2024)
        #expect(r.digitalRelease == "2024-06-15T00:00:00Z")
        #expect(r.physicalRelease == "2024-07-01T00:00:00Z")
        #expect(r.inCinemas == "2024-03-01T00:00:00Z")
        #expect(r.hasFile == false)
        #expect(r.overview == "A great movie about testing")
    }

    @Test("Decodes calendar record with minimal fields")
    func minimalCalendar() throws {
        let json = """
        {"id": 1, "title": "Movie"}
        """
        let r = try JSONDecoder().decode(RadarrCalendarRecord.self, from: Data(json.utf8))

        #expect(r.id == 1)
        #expect(r.title == "Movie")
        #expect(r.year == nil)
        #expect(r.digitalRelease == nil)
        #expect(r.physicalRelease == nil)
        #expect(r.inCinemas == nil)
        #expect(r.hasFile == nil)
    }
}

@Suite("Sonarr JSON Decoding")
struct SonarrDecodingTests {
    @Test("Decodes full queue page with series and episode")
    func fullQueuePage() throws {
        let json = """
        {
            "page": 1,
            "pageSize": 10,
            "totalRecords": 1,
            "records": [{
                "id": 99,
                "seriesId": 200,
                "episodeId": 300,
                "seasonNumber": 3,
                "title": "Show.S03E05.720p",
                "status": "downloading",
                "trackedDownloadState": "downloading",
                "downloadId": "abc123",
                "downloadClient": "qBittorrent",
                "protocol": "torrent",
                "size": 1000000000.0,
                "sizeleft": 250000000.0,
                "timeleft": "00:15:00",
                "customFormats": [],
                "customFormatScore": 0,
                "quality": {"quality": {"name": "HDTV-720p"}},
                "series": {
                    "id": 200,
                    "title": "Test Show",
                    "year": 2023,
                    "titleSlug": "test-show"
                },
                "episode": {
                    "id": 300,
                    "seasonNumber": 3,
                    "episodeNumber": 5,
                    "title": "The One With Tests",
                    "hasFile": false
                }
            }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: Data(json.utf8))

        #expect(page.records.count == 1)
        let r = page.records[0]
        #expect(r.id == 99)
        #expect(r.seriesId == 200)
        #expect(r.seasonNumber == 3)
        #expect(r.protocol == "torrent")
        #expect(r.series?.title == "Test Show")
        #expect(r.series?.year == 2023)
        #expect(r.episode?.seasonNumber == 3)
        #expect(r.episode?.episodeNumber == 5)
        #expect(r.episode?.title == "The One With Tests")
        #expect(r.quality?.name == "HDTV-720p")
    }

    @Test("Decodes calendar record with series info")
    func calendarRecord() throws {
        let json = """
        {
            "id": 60,
            "seriesId": 200,
            "seasonNumber": 2,
            "episodeNumber": 1,
            "title": "Season Premiere",
            "airDateUtc": "2024-04-15T20:00:00Z",
            "hasFile": false,
            "overview": "The show returns",
            "series": {
                "id": 200,
                "title": "Popular Show",
                "year": 2022,
                "titleSlug": "popular-show"
            }
        }
        """
        let r = try JSONDecoder().decode(SonarrCalendarRecord.self, from: Data(json.utf8))

        #expect(r.id == 60)
        #expect(r.title == "Season Premiere")
        #expect(r.airDateUtc == "2024-04-15T20:00:00Z")
        #expect(r.series?.title == "Popular Show")
        #expect(r.seasonNumber == 2)
        #expect(r.episodeNumber == 1)
    }

    @Test("Decodes empty records array")
    func emptyRecords() throws {
        let json = """
        {"page":1,"pageSize":10,"totalRecords":0,"records":[]}
        """
        let page = try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: Data(json.utf8))
        #expect(page.records.isEmpty)
        #expect(page.totalRecords == 0)
    }
}

@Suite("Shared ArrTypes Decoding")
struct SharedTypesDecodingTests {
    @Test("ArrQuality extracts nested name")
    func qualityName() throws {
        let json = """
        {"quality": {"name": "Bluray-2160p"}}
        """
        let q = try JSONDecoder().decode(ArrQuality.self, from: Data(json.utf8))
        #expect(q.name == "Bluray-2160p")
    }

    @Test("ArrQuality with null inner quality")
    func nullQuality() throws {
        let json = """
        {"quality": null}
        """
        let q = try JSONDecoder().decode(ArrQuality.self, from: Data(json.utf8))
        #expect(q.name == nil)
    }

    @Test("ArrCustomFormat decodes id and name")
    func customFormat() throws {
        let json = """
        {"id": 5, "name": "HDR10+"}
        """
        let cf = try JSONDecoder().decode(ArrCustomFormat.self, from: Data(json.utf8))
        #expect(cf.id == 5)
        #expect(cf.name == "HDR10+")
    }

    @Test("ArrCustomFormat supports Equatable")
    func customFormatEquatable() throws {
        let a = ArrCustomFormat(id: 1, name: "IMAX")
        let b = ArrCustomFormat(id: 1, name: "IMAX")
        #expect(a == b)
    }
}

// MARK: - Lidarr

@Suite("Lidarr JSON Decoding")
struct LidarrDecodingTests {
    @Test("Decodes full queue page with artist and album")
    func fullQueuePage() throws {
        let json = """
        {
          "page": 1, "pageSize": 10, "totalRecords": 1,
          "records": [{
            "id": 42,
            "artistId": 7,
            "albumId": 15,
            "title": "album-release-title",
            "status": "downloading",
            "trackedDownloadStatus": "ok",
            "trackedDownloadState": "downloading",
            "downloadId": "sab_lidarr_001",
            "downloadClient": "SABnzbd",
            "protocol": "usenet",
            "size": 500000000,
            "sizeleft": 250000000,
            "timeleft": "00:12:00",
            "quality": {"quality": {"name": "FLAC"}},
            "artist": {"id": 7, "artistName": "Radiohead", "foreignArtistId": "abc123"},
            "album": {"id": 15, "title": "OK Computer", "releaseDate": "1997-06-16", "foreignAlbumId": "def456", "artist": null}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        #expect(page.records.count == 1)
        let r = page.records[0]
        #expect(r.id == 42)
        #expect(r.artist?.artistName == "Radiohead")
        #expect(r.album?.title == "OK Computer")
        #expect(r.quality?.name == "FLAC")
        #expect(r.protocol == "usenet")
    }

    @Test("Decodes record with minimal fields")
    func minimalRecord() throws {
        let json = """
        {
          "page": 1, "pageSize": 10, "totalRecords": 1,
          "records": [{
            "id": 1,
            "title": "unknown-release"
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: Data(json.utf8))
        #expect(page.records.count == 1)
        #expect(page.records[0].artist == nil)
        #expect(page.records[0].album == nil)
    }

    @Test("Decodes calendar record with artist info")
    func calendarRecord() throws {
        let json = """
        {
          "id": 99,
          "title": "In Rainbows",
          "releaseDate": "2007-10-10",
          "foreignAlbumId": "album-xyz",
          "overview": "Seventh studio album",
          "artist": {"id": 7, "artistName": "Radiohead", "foreignArtistId": "abc123"}
        }
        """
        let r = try JSONDecoder().decode(LidarrCalendarRecord.self, from: Data(json.utf8))
        #expect(r.title == "In Rainbows")
        #expect(r.artist?.artistName == "Radiohead")
        #expect(r.releaseDate == "2007-10-10")
    }

    @Test("Decodes calendar record with minimal fields")
    func minimalCalendar() throws {
        let json = """
        {"id": 1, "title": "Unknown Album"}
        """
        let r = try JSONDecoder().decode(LidarrCalendarRecord.self, from: Data(json.utf8))
        #expect(r.id == 1)
        #expect(r.artist == nil)
        #expect(r.releaseDate == nil)
    }
}

@Suite("Existing-file decoding")
struct ExistingFileDecodingTests {
    @Test("RadarrMovieFile with score, formats, size, path")
    func radarrMovieFile() throws {
        let json = """
        {
          "id": 7,
          "movieId": 100,
          "size": 8500000000,
          "relativePath": "Movie (2024) [WEBDL-2160p].mkv",
          "quality": {"quality": {"name": "WEBDL-2160p"}},
          "customFormats": [{"id": 1, "name": "IMAX"}, {"id": 2, "name": "Atmos"}],
          "customFormatScore": 100
        }
        """
        let f = try JSONDecoder().decode(RadarrMovieFile.self, from: Data(json.utf8))
        #expect(f.id == 7)
        #expect(f.movieId == 100)
        #expect(f.size == 8_500_000_000)
        #expect(f.relativePath == "Movie (2024) [WEBDL-2160p].mkv")
        #expect(f.quality?.name == "WEBDL-2160p")
        #expect(f.customFormats?.count == 2)
        #expect(f.customFormatScore == 100)
    }

    @Test("RadarrMovieFile minimal (no quality, no formats)")
    func radarrMovieFileMinimal() throws {
        let json = #"{"id": 1}"#
        let f = try JSONDecoder().decode(RadarrMovieFile.self, from: Data(json.utf8))
        #expect(f.id == 1)
        #expect(f.movieId == nil)
        #expect(f.customFormats == nil)
        #expect(f.size == nil)
    }

    @Test("SonarrEpisodeFile with score, formats, size, path")
    func sonarrEpisodeFile() throws {
        let json = """
        {
          "id": 42,
          "seriesId": 5,
          "size": 1500000000,
          "relativePath": "Season 01/Show.S01E02.mkv",
          "quality": {"quality": {"name": "WEBDL-1080p"}},
          "customFormats": [{"id": 3, "name": "DV HDR"}],
          "customFormatScore": 50
        }
        """
        let f = try JSONDecoder().decode(SonarrEpisodeFile.self, from: Data(json.utf8))
        #expect(f.id == 42)
        #expect(f.seriesId == 5)
        #expect(f.relativePath == "Season 01/Show.S01E02.mkv")
        #expect(f.customFormatScore == 50)
        #expect(f.customFormats?.first?.name == "DV HDR")
    }

    @Test("ArrFile (embedded movieFile inside Movie) decodes")
    func embeddedArrFile() throws {
        let json = """
        {
          "size": 1234567,
          "relativePath": "x.mkv",
          "quality": {"quality": {"name": "Bluray-1080p"}},
          "customFormats": [{"id": 1, "name": "IMAX"}],
          "customFormatScore": 25
        }
        """
        let f = try JSONDecoder().decode(ArrFile.self, from: Data(json.utf8))
        #expect(f.size == 1_234_567)
        #expect(f.quality?.name == "Bluray-1080p")
        #expect(f.customFormats?.first?.name == "IMAX")
    }
}

@Suite("History decoding")
struct HistoryDecodingTests {
    @Test("Radarr history record")
    func radarrHistory() throws {
        let json = """
        {
          "page": 1, "pageSize": 1, "totalRecords": 1,
          "records": [{
            "id": 1,
            "movieId": 50,
            "sourceTitle": "Movie.2024.1080p.WEB-DL",
            "date": "2024-09-01T12:34:56Z",
            "eventType": "grabbed",
            "quality": {"quality": {"name": "WEBDL-1080p"}},
            "customFormats": [{"id": 1, "name": "IMAX"}],
            "customFormatScore": 100,
            "movie": {"id": 50, "title": "Test Movie", "titleSlug": "test-movie"}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<RadarrHistoryRecord>.self, from: Data(json.utf8))
        let r = page.records[0]
        #expect(r.eventType == "grabbed")
        #expect(r.movie?.title == "Test Movie")
        #expect(r.customFormatScore == 100)
    }

    @Test("Sonarr history record with episode")
    func sonarrHistory() throws {
        let json = """
        {
          "page": 1, "pageSize": 1, "totalRecords": 1,
          "records": [{
            "id": 9,
            "episodeId": 200,
            "seriesId": 5,
            "sourceTitle": "Show.S01E02.mkv",
            "date": "2024-08-15T10:00:00Z",
            "eventType": "downloadFolderImported",
            "quality": {"quality": {"name": "HDTV-720p"}},
            "series": {"id": 5, "title": "Show", "titleSlug": "show"},
            "episode": {"id": 200, "seasonNumber": 1, "episodeNumber": 2, "title": "Pilot"}
          }]
        }
        """
        let page = try JSONDecoder().decode(ArrQueuePage<SonarrHistoryRecord>.self, from: Data(json.utf8))
        let r = page.records[0]
        #expect(r.eventType == "downloadFolderImported")
        #expect(r.episode?.episodeNumber == 2)
        #expect(r.series?.title == "Show")
    }

    @Test("EventType mapping")
    func eventTypeMapping() {
        #expect(HistoryItem.EventType.parse("grabbed") == .grabbed)
        #expect(HistoryItem.EventType.parse("downloadFolderImported") == .imported)
        #expect(HistoryItem.EventType.parse("episodeFileImported") == .imported)
        #expect(HistoryItem.EventType.parse("movieFileImported") == .imported)
        #expect(HistoryItem.EventType.parse("downloadFailed") == .failed)
        #expect(HistoryItem.EventType.parse("downloadIgnored") == .failed)
        #expect(HistoryItem.EventType.parse("movieFileDeleted") == .deleted)
        #expect(HistoryItem.EventType.parse("episodeFileDeleted") == .deleted)
        #expect(HistoryItem.EventType.parse("unrecognized") == .other)
        #expect(HistoryItem.EventType.parse(nil) == .other)
    }
}

