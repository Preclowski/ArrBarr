import Foundation

// Upcoming-episodes and health-check fixtures for demo mode.

extension DemoMocks {
    // MARK: - Upcoming

    static var upcoming: [UpcomingItem] {
        [
            upcomingItem(
                source: .sonarr, id: "demo-cal-tonight-1",
                title: "Pioneer One (2010)",
                subtitle: "S01E06 · Tomorrow Belongs to Us",
                hoursAhead: 3, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
            upcomingItem(
                source: .radarr, id: "demo-cal-tonight-2",
                title: "Spring (2019)",
                hoursAhead: 8, releaseType: "Digital", hasFile: false,
                posterSeed: "spring", aspect: .portrait
            ),
            upcomingItem(
                source: .sonarr, id: "demo-cal-2",
                title: "Pioneer One (2010)",
                subtitle: "S02E01 · Reentry",
                daysAhead: 1, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
            upcomingItem(
                source: .radarr, id: "demo-cal-3",
                title: "Charge (2018)",
                daysAhead: 3, releaseType: "Physical", hasFile: false,
                posterSeed: "charge", aspect: .portrait
            ),
            upcomingItem(
                source: .lidarr, id: "demo-cal-4",
                title: "Jonathan Coulton — Some Guys",
                daysAhead: 5, releaseType: "Album", hasFile: false,
                posterSeed: "coultonsomeguys", aspect: .square
            ),
            upcomingItem(
                source: .sonarr, id: "demo-cal-5",
                title: "Pioneer One (2010)",
                subtitle: "S02E02 · Witness",
                daysAhead: 8, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
            upcomingItem(
                source: .whisparr, id: "demo-cal-whisparr-1",
                title: "Garage Cat Files (2024)",
                daysAhead: 4, releaseType: "Digital", hasFile: false,
                posterSeed: "kitten:poppy", aspect: .portrait
            ),
            upcomingItem(
                source: .whisparr, id: "demo-cal-whisparr-2",
                title: "Whiskers & Whispers Vol. II",
                daysAhead: 9, releaseType: "Digital", hasFile: false,
                posterSeed: "kitten:bella", aspect: .portrait
            ),
        ]
        .sorted { $0.airDate < $1.airDate }
    }

    // MARK: - Health

    static var health: HealthResult {
        HealthResult(
            radarr: [],
            sonarr: [
                ArrHealthRecord(source: "IndexerStatusCheck", type: "warning",
                                message: "Indexer 'Demo Tracker' is unavailable due to errors for more than 6 hours",
                                wikiUrl: nil),
            ],
            lidarr: [],
            whisparr: [
                ArrHealthRecord(source: "ImportCheck", type: "warning",
                                message: "Whisparr remote storage at 87% capacity",
                                wikiUrl: nil),
            ]
        )
    }

}
