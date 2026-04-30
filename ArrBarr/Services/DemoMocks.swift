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

    private static let seedDoneKey = "ArrBarr.demoSeedDone"

    /// First-time demo users get all three arrs flipped to `enabled` so the popover
    /// has something to show out of the box. After the seed runs once, we respect
    /// the user's toggles — disabling Lidarr in settings actually hides it.
    @MainActor
    static func seedConfigsIfNeeded(_ store: ConfigStore) {
        guard isActive else { return }
        guard !UserDefaults.standard.bool(forKey: seedDoneKey) else { return }
        if store.radarr == .empty { store.radarr.enabled = true }
        if store.sonarr == .empty { store.sonarr.enabled = true }
        if store.lidarr == .empty { store.lidarr.enabled = true }
        UserDefaults.standard.set(true, forKey: seedDoneKey)
    }
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
                releaseName: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                status: .downloading, progress: 0.42,
                quality: "Bluray-2160p", formats: ["x265", "HDR", "Atmos"], score: 120,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "bigbuckbunny", aspect: .portrait
            ),
            queueItem(
                source: .radarr, id: "demo-radarr-2",
                title: "Sintel (2010)",
                releaseName: "Sintel.2010.1080p.WEB-DL.AV1-DEMO",
                status: .importing, progress: 1.0,
                quality: "WEB-DL 1080p", formats: ["AV1"], score: 80,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "HDTV-720p", formats: ["x264"], score: 10,
                    size: 850_000_000,
                    fileName: "Sintel.2010.720p.HDTV.x264-OLD.mkv"
                ),
                posterSeed: "sintel", aspect: .portrait
            ),
            queueItem(
                source: .radarr, id: "demo-radarr-3",
                title: "Tears of Steel (2012)",
                releaseName: "Tears.of.Steel.2012.720p.WEB-DL.x264-DEMO",
                status: .paused, progress: 0.18,
                quality: "WEB-DL 720p", formats: [], score: -20,
                client: "Transmission", indexer: "DemoTracker",
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
                releaseName: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                status: .downloading, progress: 0.67,
                quality: "HDTV-720p", formats: ["x264"], score: 50,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "WEBRip-480p", formats: [], score: 0,
                    size: 350_000_000,
                    fileName: "Pioneer.One.S01E03.480p.WEBRip-OLD.mkv"
                ),
                posterSeed: "pioneerone", aspect: .portrait
            ),
            queueItem(
                source: .sonarr, id: "demo-sonarr-2",
                title: "Cosmos Laundromat",
                subtitle: "S01E01 · The Beginning",
                releaseName: "Cosmos.Laundromat.S01E01.1080p.WEB-DL-DEMO",
                status: .queued, progress: 0,
                quality: nil, formats: [], score: 0,
                client: "NZBGet", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "cosmoslaundromat", aspect: .portrait
            ),
            queueItem(
                source: .sonarr, id: "demo-sonarr-3",
                title: "Caminandes",
                subtitle: "S01E02 · Gran Dillama",
                releaseName: "Caminandes.S01E02.1080p.WEBRip-DEMO",
                status: .warning, progress: 1.0,
                quality: "WEBRip-1080p", formats: ["x264"], score: 25,
                client: "Deluge", indexer: "DemoTracker",
                upgrade: false, posterSeed: "caminandes", aspect: .portrait
            ),
        ]
    }

    static var lidarrQueue: [QueueItem] {
        [
            queueItem(
                source: .lidarr, id: "demo-lidarr-1",
                title: "Nine Inch Nails — Ghosts I-IV",
                releaseName: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                status: .downloading, progress: 0.81,
                quality: "FLAC", formats: ["Lossless"], score: 30,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "MP3-320", formats: [], score: 0,
                    size: 220_000_000,
                    fileName: "Nine Inch Nails - Ghosts I-IV (320kbps).zip"
                ),
                posterSeed: "ninghosts", aspect: .square
            ),
            queueItem(
                source: .lidarr, id: "demo-lidarr-2",
                title: "Brad Sucks — Out of It",
                releaseName: "Brad.Sucks-Out.of.It-MP3-DEMO",
                status: .completed, progress: 1.0,
                quality: "MP3-320", formats: [], score: 0,
                client: "rTorrent", indexer: "DemoTracker",
                upgrade: false, posterSeed: "bradsucks", aspect: .square
            ),
        ]
    }

    // MARK: - Upcoming

    static var upcoming: [UpcomingItem] {
        [
            upcomingItem(
                source: .sonarr, id: "demo-cal-tonight-1",
                title: "Pioneer One",
                subtitle: "S01E06 · Tomorrow Belongs to Us",
                hoursAhead: 3, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait
            ),
            upcomingItem(
                source: .radarr, id: "demo-cal-tonight-2",
                title: "Spring (2019)",
                hoursAhead: 8, releaseType: "Digital", hasFile: false,
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

    // MARK: - History

    static func history(for source: QueueItem.Source) -> [HistoryItem] {
        switch source {
        case .radarr: return radarrHistory
        case .sonarr: return sonarrHistory
        case .lidarr: return lidarrHistory
        }
    }

    private static var radarrHistory: [HistoryItem] {
        [
            historyItem(.radarr, id: "rh1", minutesAgo: 12, event: .grabbed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                        quality: "Bluray-2160p", formats: ["x265", "HDR"], score: 120),
            historyItem(.radarr, id: "rh2", minutesAgo: 95, event: .imported,
                        title: "Sintel (2010)",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AV1"], score: 80),
            historyItem(.radarr, id: "rh3", minutesAgo: 240, event: .grabbed,
                        title: "Tears of Steel (2012)",
                        sourceTitle: "Tears.of.Steel.2012.720p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 720p", formats: [], score: -20),
            historyItem(.radarr, id: "rh4", minutesAgo: 1440, event: .failed,
                        title: "Spring (2019)",
                        sourceTitle: "Spring.2019.1080p.WEB-DL.BAD-RELEASE",
                        quality: "WEB-DL 1080p", formats: [], score: 0),
            historyItem(.radarr, id: "rh5", minutesAgo: 4320, event: .deleted,
                        title: "Charge (2018)",
                        sourceTitle: "Charge.2018.720p.WEBRip-OLD",
                        quality: "WEBRip-720p", formats: [], score: 0),
        ]
    }

    private static var sonarrHistory: [HistoryItem] {
        [
            historyItem(.sonarr, id: "sh1", minutesAgo: 5, event: .grabbed,
                        title: "Pioneer One",
                        subtitle: "S01E03 · Endurance",
                        sourceTitle: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 50),
            historyItem(.sonarr, id: "sh2", minutesAgo: 60, event: .imported,
                        title: "Pioneer One",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 50),
            historyItem(.sonarr, id: "sh3", minutesAgo: 320, event: .imported,
                        title: "Caminandes",
                        subtitle: "S01E01 · Llama Drama",
                        sourceTitle: "Caminandes.S01E01.1080p.WEBRip-DEMO",
                        quality: "WEBRip-1080p", formats: ["x264"], score: 25),
            historyItem(.sonarr, id: "sh4", minutesAgo: 2880, event: .failed,
                        title: "Cosmos Laundromat",
                        subtitle: "S01E01 · The Beginning",
                        sourceTitle: "Cosmos.Laundromat.S01E01.bad.release",
                        quality: nil, formats: [], score: 0),
        ]
    }

    private static var lidarrHistory: [HistoryItem] {
        [
            historyItem(.lidarr, id: "lh1", minutesAgo: 30, event: .grabbed,
                        title: "Nine Inch Nails",
                        subtitle: "Ghosts I-IV",
                        sourceTitle: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                        quality: "FLAC", formats: ["Lossless"], score: 30),
            historyItem(.lidarr, id: "lh2", minutesAgo: 600, event: .imported,
                        title: "Brad Sucks",
                        subtitle: "Out of It",
                        sourceTitle: "Brad.Sucks-Out.of.It-MP3-DEMO",
                        quality: "MP3-320", formats: [], score: 0),
        ]
    }

    // MARK: - Builders

    private enum Aspect { case portrait, square }

    private struct ExistingFile {
        let quality: String?
        let formats: [String]
        let score: Int
        let size: Int64
        let fileName: String
    }

    private static func queueItem(
        source: QueueItem.Source, id: String,
        title: String, subtitle: String? = nil,
        releaseName: String? = nil,
        status: QueueItem.Status, progress: Double,
        quality: String?, formats: [String], score: Int,
        client: String = "qBittorrent", indexer: String? = nil,
        upgrade: Bool, existing: ExistingFile? = nil,
        posterSeed: String, aspect: Aspect
    ) -> QueueItem {
        let total: Int64 = 4_500_000_000
        let left = Int64(Double(total) * (1 - progress))
        let timeLeft: String? = switch status {
        case .downloading: "00:14:23"
        case .queued: "—"
        default: nil
        }
        let proto: QueueItem.DownloadProtocol = {
            switch client.lowercased() {
            case let c where c.contains("sab") || c.contains("nzbget"): return .usenet
            default: return .torrent
            }
        }()
        let (w, h) = (aspect == .square) ? (200, 200) : (200, 300)
        return QueueItem(
            id: id, source: source, arrQueueId: abs(id.hashValue % 99999),
            downloadId: id, downloadProtocol: proto, downloadClient: client,
            indexer: indexer,
            title: title, subtitle: subtitle, releaseName: releaseName,
            status: status, progress: progress,
            sizeTotal: total, sizeLeft: left, timeLeft: timeLeft,
            customFormats: formats, customFormatScore: score,
            quality: quality, isUpgrade: upgrade,
            existingCustomFormats: existing?.formats ?? [],
            existingCustomFormatScore: existing?.score,
            existingQuality: existing?.quality,
            existingSize: existing?.size,
            existingFileName: existing?.fileName,
            contentSlug: posterSeed,
            posterURL: poster(posterSeed, w: w, h: h),
            posterRequiresAuth: false
        )
    }

    private static func upcomingItem(
        source: UpcomingItem.Source, id: String,
        title: String, subtitle: String? = nil,
        daysAhead: Int = 0, hoursAhead: Int = 0,
        releaseType: String, hasFile: Bool,
        posterSeed: String, aspect: Aspect
    ) -> UpcomingItem {
        let cal = Calendar.current
        let withDays = cal.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
        let date = cal.date(byAdding: .hour, value: hoursAhead, to: withDays) ?? withDays
        let (w, h) = (aspect == .square) ? (200, 200) : (200, 300)
        return UpcomingItem(
            id: id, source: source, title: title, subtitle: subtitle,
            airDate: date, releaseType: releaseType, hasFile: hasFile,
            overview: "Demo overview text. \(title) is part of the open-source / CC-licensed sample content used for ArrBarr previews.",
            posterURL: poster(posterSeed, w: w, h: h),
            posterRequiresAuth: false
        )
    }

    private static func historyItem(
        _ source: QueueItem.Source, id: String,
        minutesAgo: Int, event: HistoryItem.EventType,
        title: String, subtitle: String? = nil,
        sourceTitle: String?,
        quality: String?, formats: [String], score: Int
    ) -> HistoryItem {
        HistoryItem(
            id: "demo-\(id)",
            source: source,
            date: Date().addingTimeInterval(-Double(minutesAgo) * 60),
            eventType: event,
            title: title,
            subtitle: subtitle,
            sourceTitle: sourceTitle,
            quality: quality,
            customFormats: formats,
            customFormatScore: score
        )
    }
}
