import Testing
@testable import ArrCore

struct TrailerSelectionTests {
    private func video(_ key: String, type: String?, official: Bool?, site: String? = "YouTube") -> TMDBVideo {
        TMDBVideo(key: key, site: site, type: type, official: official)
    }

    @Test("An official trailer beats a teaser, a clip and an unofficial trailer")
    func officialTrailerWins() {
        let picked = TMDBVideo.bestTrailerKey([
            video("clip", type: "Clip", official: true),
            video("teaser", type: "Teaser", official: true),
            video("fan", type: "Trailer", official: false),
            video("official", type: "Trailer", official: true),
        ])
        #expect(picked == "official")
    }

    @Test("Falls through to whatever exists rather than showing no trailer at all")
    func fallsThroughToLesserClips() {
        #expect(TMDBVideo.bestTrailerKey([video("fan", type: "Trailer", official: false)]) == "fan")
        #expect(TMDBVideo.bestTrailerKey([video("teaser", type: "Teaser", official: nil)]) == "teaser")
        #expect(TMDBVideo.bestTrailerKey([video("featurette", type: "Featurette", official: true)]) == "featurette")
    }

    @Test("Non-YouTube and empty-key entries are unusable")
    func skipsWhatCannotBePlayed() {
        #expect(TMDBVideo.bestTrailerKey([video("v", type: "Trailer", official: true, site: "Vimeo")]) == nil)
        #expect(TMDBVideo.bestTrailerKey([video("", type: "Trailer", official: true)]) == nil)
        #expect(TMDBVideo.bestTrailerKey([]) == nil)
        // A missing `site` is TMDB's overwhelming default (YouTube), not a
        // reason to drop the only clip a title has.
        #expect(TMDBVideo.bestTrailerKey([video("k", type: "Trailer", official: true, site: nil)]) == "k")
    }

    @Test("Ties keep TMDB's own order — its first entry is the featured one")
    func tiesKeepSourceOrder() {
        let picked = TMDBVideo.bestTrailerKey([
            video("first", type: "Trailer", official: true),
            video("second", type: "Trailer", official: true),
        ])
        #expect(picked == "first")
    }
}
