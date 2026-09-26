import Foundation
import Testing
@testable import ArrCore

/// "Airing now" means a fresh season under way, not "has an episode this week".
@Suite("TMDB airing schedule")
struct TMDBScheduleTests {

    private let today = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!

    private func schedule(last: (String, Int)?, next: (String, Int)? = nil, premieres: [Int: String]) -> TMDBTVSchedule {
        TMDBTVSchedule(
            lastEpisodeToAir: last.map { .init(airDate: $0.0, seasonNumber: $0.1) },
            nextEpisodeToAir: next.map { .init(airDate: $0.0, seasonNumber: $0.1) },
            seasons: premieres.map { .init(airDate: $0.value, seasonNumber: $0.key) }
        )
    }

    @Test("A season that began six weeks ago and airs this week is on air")
    func midSeason() {
        #expect(schedule(last: ("2026-09-23", 4), premieres: [3: "2024-05-01", 4: "2026-08-12"]).isFreshSeason(around: today))
    }

    @Test("A premiere next week counts")
    func premiereAhead() {
        #expect(schedule(last: ("2026-05-01", 37), next: ("2026-09-27", 38), premieres: [38: "2026-09-27"]).isFreshSeason(around: today))
    }

    @Test("A long-running season and a finished show don't")
    func stale() {
        #expect(!schedule(last: ("2026-09-24", 1), premieres: [1: "1996-01-08"]).isFreshSeason(around: today))
        #expect(!schedule(last: ("2026-06-01", 2), premieres: [2: "2026-04-01"]).isFreshSeason(around: today))
    }
}
