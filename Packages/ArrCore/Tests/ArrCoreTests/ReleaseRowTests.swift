import Foundation
import Testing
import MediaKit
@testable import ArrCore

struct ReleaseRowTests {
    private func release(_ extra: String) throws -> ArrRelease {
        try JSONDecoder().decode(ArrRelease.self, from: Data(#"{"guid":"g","title":"Big.Buck.Bunny.S01E02E03.1080p.WEB-DEMO"\#(extra)}"#.utf8))
    }

    @Test("Flag names badge; an old bitfield decodes to none instead of failing the list")
    func indexerFlagsAreLenient() throws {
        #expect(try release(#","indexerFlags":["freeleech",""]"#).indexerFlagNames == ["freeleech"])
        #expect(try release(#","indexerFlags":9"#).indexerFlagNames.isEmpty)
    }

    @Test("Scope reads a pack or the episode span")
    func scope() throws {
        #expect(try release(#","fullSeason":true"#).scope == .pack)
        #expect(try release(#","episodeNumbers":[3,2]"#).scope == .episodes("E02–03"))
        #expect(try release("").scope == nil)
    }

    @Test("A season search is keyed by its season")
    func seasonTarget() {
        let target = ManualSearchTarget.season(seriesId: 7, seasonNumber: 2, title: "S2")
        #expect(target.season == 2 && target.isSeasonSearch)
        #expect(!ManualSearchTarget.episode(episodeId: 1, title: "E").isSeasonSearch)
        #expect(target.id != ManualSearchTarget.season(seriesId: 7, seasonNumber: 3, title: "S2").id)
    }
}
