import Foundation

/// Demo mode: ship a runnable preview without needing real Radarr/Sonarr/Lidarr instances.
///
/// Activate by any of:
///   - Launch arg:        --demo
///   - Env var:           ARRBARR_DEMO=1
///   - UserDefaults:      defaults write com.preclowski.ArrBarr ArrBarrDemo -bool true
///   - Or via NSArgs:     open ArrBarr.app --args -ArrBarrDemo YES
enum DemoMode {
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") { return true }
        if ProcessInfo.processInfo.environment["ARRBARR_DEMO"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "ArrBarrDemo")
    }()
}

/// Public-domain / CC-licensed titles used as preview content.
/// Posters come from picsum.photos with deterministic seeds, no auth.
enum DemoMocks {
    private static func poster(_ seed: String, w: Int = 200, h: Int = 300) -> URL? {
        URL(string: "https://picsum.photos/seed/\(seed)/\(w)/\(h)")
    }

    // MARK: - Queue

    static var radarrQueue: [QueueItem] {
        [
            queueItem(
                source: .radarr, id: "demo-radarr-1",
                title: "Big Buck Bunny (2008)",
                status: .downloading, progress: 0.42,
                quality: "Bluray-2160p", formats: ["x265", "HDR"], score: 120,
                upgrade: false, posterSeed: "bigbuckbunny", aspect: .portrait
            ),
            queueItem(
                source: .radarr, id: "demo-radarr-2",
                title: "Sintel (2010)",
                status: .completed, progress: 1.0,
                quality: "WEB-DL 1080p", formats: ["AV1"], score: 80,
                upgrade: true, posterSeed: "sintel", aspect: .portrait
            ),
            queueItem(
                source: .radarr, id: "demo-radarr-3",
                title: "Tears of Steel (2012)",
                status: .paused, progress: 0.18,
                quality: "WEB-DL 720p", formats: [], score: -20,
                upgrade: false, posterSeed: "tearsofsteel", aspect: .portrait
            ),
        ]
    }

    static var sonarrQueue: [QueueItem] {
        [
            queueItem(
                source: .sonarr, id: "demo-sonarr-1",
                title: "Pioneer One",
                subtitle: "S01E03 · Endurance",
                status: .downloading, progress: 0.67,
                quality: "HDTV-720p", formats: ["x264"], score: 50,
                upgrade: false, posterSeed: "pioneerone", aspect: .portrait
            ),
            queueItem(
                source: .sonarr, id: "demo-sonarr-2",
                title: "Cosmos Laundromat",
                subtitle: "S01E01 · The Beginning",
                status: .queued, progress: 0,
                quality: nil, formats: [], score: 0,
                upgrade: false, posterSeed: "cosmoslaundromat", aspect: .portrait
            ),
        ]
    }

    static var lidarrQueue: [QueueItem] {
        [
            queueItem(
                source: .lidarr, id: "demo-lidarr-1",
                title: "Nine Inch Nails — Ghosts I-IV",
                status: .downloading, progress: 0.81,
                quality: "FLAC", formats: ["Lossless"], score: 30,
                upgrade: false, posterSeed: "ninghosts", aspect: .square
            ),
            queueItem(
                source: .lidarr, id: "demo-lidarr-2",
                title: "Brad Sucks — Out of It",
                status: .completed, progress: 1.0,
                quality: "MP3-320", formats: [], score: 0,
                upgrade: false, posterSeed: "bradsucks", aspect: .square
            ),
        ]
    }

    // MARK: - Upcoming

    static var upcoming: [UpcomingItem] {
        [
            upcomingItem(
                source: .radarr, id: "demo-cal-1",
                title: "Spring (2019)",
                daysAhead: 0, releaseType: "Digital", hasFile: false,
                posterSeed: "spring", aspect: .portrait
            ),
            upcomingItem(
                source: .sonarr, id: "demo-cal-2",
                title: "Pioneer One",
                subtitle: "S02E01 · Reentry",
                daysAhead: 1, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait
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
                title: "Pioneer One",
                subtitle: "S02E02 · Witness",
                daysAhead: 8, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait
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
            lidarr: []
        )
    }

    // MARK: - Builders

    private enum Aspect { case portrait, square }

    private static func queueItem(
        source: QueueItem.Source, id: String,
        title: String, subtitle: String? = nil,
        status: QueueItem.Status, progress: Double,
        quality: String?, formats: [String], score: Int,
        upgrade: Bool, posterSeed: String, aspect: Aspect
    ) -> QueueItem {
        let total: Int64 = 4_500_000_000
        let left = Int64(Double(total) * (1 - progress))
        let timeLeft: String? = switch status {
        case .downloading: "00:14:23"
        case .queued: "—"
        default: nil
        }
        let (w, h) = (aspect == .square) ? (200, 200) : (200, 300)
        return QueueItem(
            id: id, source: source, arrQueueId: abs(id.hashValue % 99999),
            downloadId: id, downloadProtocol: .torrent, downloadClient: "qBittorrent",
            title: title, subtitle: subtitle,
            status: status, progress: progress,
            sizeTotal: total, sizeLeft: left, timeLeft: timeLeft,
            customFormats: formats, customFormatScore: score,
            quality: quality, isUpgrade: upgrade, contentSlug: posterSeed,
            posterURL: poster(posterSeed, w: w, h: h),
            posterRequiresAuth: false
        )
    }

    private static func upcomingItem(
        source: UpcomingItem.Source, id: String,
        title: String, subtitle: String? = nil,
        daysAhead: Int, releaseType: String, hasFile: Bool,
        posterSeed: String, aspect: Aspect
    ) -> UpcomingItem {
        let date = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
        let (w, h) = (aspect == .square) ? (200, 200) : (200, 300)
        return UpcomingItem(
            id: id, source: source, title: title, subtitle: subtitle,
            airDate: date, releaseType: releaseType, hasFile: hasFile,
            overview: "Demo overview text. \(title) is part of the open-source / CC-licensed sample content used for ArrBarr previews.",
            posterURL: poster(posterSeed, w: w, h: h),
            posterRequiresAuth: false
        )
    }
}
