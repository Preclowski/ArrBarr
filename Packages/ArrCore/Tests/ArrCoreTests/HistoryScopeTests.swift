import Testing
import Foundation
import MediaKit
@testable import ArrCore

@Suite("History scope")
struct HistoryScopeTests {
    private func record(_ json: String) throws -> ArrHistoryRecord {
        try JSONDecoder().decode(ArrHistoryRecord.self, from: Data(json.utf8))
    }

    @Test("Each scope keeps only its own subject's rows")
    func rowsAreCheckedAgainstTheScope() throws {
        let e55 = try record(#"{"id":1,"seriesId":7,"episodeId":55}"#)
        let e61 = try record(#"{"id":2,"seriesId":7,"episodeId":61}"#)
        #expect(HistoryScope.episode(seriesId: 7, episodeId: 61).admits(e61))
        #expect(!HistoryScope.episode(seriesId: 7, episodeId: 61).admits(e55))
        let album = try record(#"{"id":3,"artistId":4,"albumId":9}"#)
        #expect(HistoryScope.artist(4).admits(album))
        #expect(!HistoryScope.artist(5).admits(album))
        #expect(HistoryScope.record(9).admits(album))
    }

    @Test("An episode reads its series' history by episode id, the artist the arr-wide one by artist")
    func scopesPickTheirEndpoint() {
        let sonarr = ServarrService(instance: InstanceID(.sonarr), profile: .sonarr)
        let episode = HistoryScope.episode(seriesId: 7, episodeId: 61).resource(sonarr, page: 2, pageSize: 100).plan
        #expect(episode.query.contains(.init("seriesIds", "7")) && episode.query.contains(.init("episodeId", "61")))
        #expect(episode.query.contains(.init("page", "2")))
        let lidarr = ServarrService(instance: InstanceID(.lidarr), profile: .lidarr)
        let artist = HistoryScope.artist(4).resource(lidarr, page: 1, pageSize: 100).plan
        #expect(artist.operation.name == "fetchHistory" && artist.query.contains(.init("artistIds", "4")))
    }
}
