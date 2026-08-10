import Foundation

// Upcoming-episodes and health-check fixtures for demo mode. Calendar uses only
// curated entities; health is all-green.

extension DemoMocks {
    // MARK: - Upcoming

    public static var upcoming: [UpcomingItem] {
        [
            // Tonight: next Pioneer One episode (S02 -> shows multi-season).
            upcomingItem(
                source: .sonarr, id: "demo-cal-tonight-1",
                title: "Pioneer One (2010)",
                subtitle: "S02E01 · Reentry",
                hoursAhead: 3, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
            // Tonight: a movie digital release.
            upcomingItem(
                source: .radarr, id: "demo-cal-tonight-2",
                title: "Sintel (2010)",
                hoursAhead: 8, releaseType: "Digital", hasFile: false,
                posterSeed: "sintel", aspect: .portrait,
                entityId: 202
            ),
            // This week: Caminandes future episode.
            upcomingItem(
                source: .sonarr, id: "demo-cal-2",
                title: "Caminandes (2013)",
                subtitle: "S01E04 · Snow Day",
                daysAhead: 2, releaseType: "Airing", hasFile: false,
                posterSeed: "caminandes", aspect: .portrait,
                entityId: 102
            ),
            // This week: album release.
            upcomingItem(
                source: .lidarr, id: "demo-cal-3",
                title: "Brad Sucks — Out of It",
                daysAhead: 4, releaseType: "Album", hasFile: false,
                posterSeed: "bradsucks", aspect: .square,
                entityId: 302
            ),
            // This week: movie physical release.
            upcomingItem(
                source: .radarr, id: "demo-cal-4",
                title: "Big Buck Bunny (2008)",
                daysAhead: 5, releaseType: "Physical", hasFile: false,
                posterSeed: "bigbuckbunny", aspect: .portrait,
                entityId: 201
            ),
            // This week: the library-only movie (no queue row), which is how a
            // demo user reaches a movie detail that still offers Manual search.
            upcomingItem(
                source: .radarr, id: "demo-cal-6",
                title: "Elephants Dream (2006)",
                daysAhead: 6, releaseType: "Physical", hasFile: true,
                posterSeed: "elephantsdream", aspect: .portrait,
                entityId: 204
            ),
            // Next week: Pioneer One S02E02.
            upcomingItem(
                source: .sonarr, id: "demo-cal-5",
                title: "Pioneer One (2010)",
                subtitle: "S02E02 · Witness",
                daysAhead: 8, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
        ]
        .sorted { $0.airDate < $1.airDate }
    }

    // MARK: - Health (all green)

    static var health: HealthResult {
        HealthResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])
    }
}
