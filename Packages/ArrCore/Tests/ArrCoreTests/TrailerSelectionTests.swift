import Foundation
import Testing
import MediaKit
@testable import ArrCore

struct TrailerSelectionTests {
    private func video(_ key: String, type: String?, official: Bool?, site: String? = "YouTube") -> TMDBVideo {
        var json: [String: Any] = ["key": key]
        json["site"] = site; json["type"] = type; json["official"] = official
        return try! tmdbDecoder.decode(TMDBVideo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func best(_ videos: [TMDBVideo]) -> String? { TMDBVideo.rankedYouTube(videos).first?.key }

    @Test("An official trailer beats a teaser, a clip and an unofficial trailer")
    func officialTrailerWins() {
        let picked = best([
            video("clip", type: "Clip", official: true),
            video("teaser", type: "Teaser", official: true),
            video("fan", type: "Trailer", official: false),
            video("official", type: "Trailer", official: true),
        ])
        #expect(picked == "official")
    }

    @Test("Falls through to whatever exists rather than showing no trailer at all")
    func fallsThroughToLesserClips() {
        #expect(best([video("fan", type: "Trailer", official: false)]) == "fan")
        #expect(best([video("teaser", type: "Teaser", official: nil)]) == "teaser")
        #expect(best([video("featurette", type: "Featurette", official: true)]) == "featurette")
    }

    @Test("Non-YouTube and empty-key entries are unusable")
    func skipsWhatCannotBePlayed() {
        #expect(best([video("v", type: "Trailer", official: true, site: "Vimeo")]) == nil)
        #expect(best([video("", type: "Trailer", official: true)]) == nil)
        #expect(best([]) == nil)
        // A missing `site` is TMDB's overwhelming default (YouTube), not a
        // reason to drop the only clip a title has.
        #expect(best([video("k", type: "Trailer", official: true, site: nil)]) == "k")
    }

    @Test("Ties keep TMDB's own order — its first entry is the featured one")
    func tiesKeepSourceOrder() {
        let picked = best([
            video("first", type: "Trailer", official: true),
            video("second", type: "Trailer", official: true),
        ])
        #expect(picked == "first")
    }

    @Test("The reel keeps every clip, and Radarr's own pick leads it")
    func reelOrdering() {
        let clips = TMDBVideo.rankedYouTube([
            video("clip", type: "Clip", official: true),
            video("official", type: "Trailer", official: true),
            video("teaser", type: "Teaser", official: true),
        ]).map { TrailerClip(key: $0.key, name: $0.name) }
        #expect(clips.map(\.key) == ["official", "teaser", "clip"])
        #expect(TrailerReel(featuredKey: "teaser", clips: clips)?.clips.map(\.key) == ["teaser", "official", "clip"])
        #expect(TrailerReel(featuredKey: "radarr", clips: clips)?.clips.map(\.key) == ["radarr", "official", "teaser", "clip"])
        #expect(TrailerReel(featuredKey: "", clips: [])  == nil)
    }
}
