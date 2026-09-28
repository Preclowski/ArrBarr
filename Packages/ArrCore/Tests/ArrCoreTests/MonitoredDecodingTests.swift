import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// The monitored flag drives whether a bookmark renders at all: present →
/// show it, absent → show nothing. That "absent stays nil" contract is what
/// keeps an arr (or a fork like Whisparr V3) that never reports the field
/// from getting a bookmark asserting a state we never learned — so it is
/// pinned here rather than left to Decodable's defaults.
@Suite("Monitored flag decoding")
struct MonitoredDecodingTests {

    @Test("Radarr movie detail decodes monitored")
    func movieMonitored() throws {
        let json = """
        {"id": 100, "title": "Test Movie", "year": 2024, "monitored": false}
        """
        let detail = try JSONDecoder().decode(ArrMovie.self, from: Data(json.utf8))
        #expect(detail.monitored == false)
    }

    @Test("Sonarr series detail decodes monitored and its seasons' flags")
    func seriesMonitored() throws {
        let json = """
        {
            "id": 7, "title": "Test Series", "monitored": true,
            "seasons": [
                {"seasonNumber": 1, "monitored": true},
                {"seasonNumber": 2, "monitored": false}
            ]
        }
        """
        let detail = try JSONDecoder().decode(ArrSeries.self, from: Data(json.utf8))
        #expect(detail.monitored == true)
        #expect(detail.seasons?.first { $0.seasonNumber == 2 }?.monitored == false)
    }

    @Test("Sonarr episode decodes monitored")
    func episodeMonitored() throws {
        let json = """
        {"id": 42, "seasonNumber": 2, "episodeNumber": 4, "monitored": false, "hasFile": false}
        """
        let episode = try JSONDecoder().decode(ArrEpisode.self, from: Data(json.utf8))
        #expect(episode.monitored == false)
    }

    @Test("Lidarr album detail decodes monitored")
    func albumMonitored() throws {
        let json = """
        {"id": 301, "title": "Test Album", "monitored": true}
        """
        let album = try JSONDecoder().decode(ArrAlbum.self, from: Data(json.utf8))
        #expect(album.monitored == true)
    }

    /// An arr that omits the field must leave `nil`, NOT default to false —
    /// `false` would dim every row and show an outline bookmark on a server
    /// that simply doesn't report monitoring.
    @Test("Absent monitored stays nil rather than defaulting to false")
    func absentStaysNil() throws {
        let movie = try JSONDecoder().decode(
            ArrMovie.self, from: Data(#"{"id": 1, "title": "M"}"#.utf8))
        let series = try JSONDecoder().decode(
            ArrSeries.self, from: Data(#"{"id": 2, "title": "S"}"#.utf8))
        let album = try JSONDecoder().decode(
            ArrAlbum.self, from: Data(#"{"id": 3, "title": "A"}"#.utf8))
        let episode = try JSONDecoder().decode(
            ArrEpisode.self, from: Data(#"{"id": 4}"#.utf8))
        #expect(movie.monitored == nil)
        #expect(series.monitored == nil)
        #expect(album.monitored == nil)
        #expect(episode.monitored == nil)
    }

    /// Demo has to be able to show BOTH states — an all-monitored fixture set
    /// makes the outline glyph unreachable in the one build meant to show the
    /// feature off (and unscreenshottable for the site).
}
