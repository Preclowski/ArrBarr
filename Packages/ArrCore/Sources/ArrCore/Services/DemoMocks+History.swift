import Foundation

// Per-source history fixtures on the demo queue's entities (same arr ids, so a
// row opens the same detail). Each arr shows off one history shape: a pending
// upgrade grab diffed against the file on disk, an upgrade import paired with
// the deletion it caused, a new download, folded season / album batches, a
// failure and a manual deletion in the older sections.

extension DemoMocks {
    // MARK: - History

    static func history(for source: QueueItem.Source) -> [HistoryItem] {
        switch source {
        case .radarr: return radarrHistory
        case .sonarr: return sonarrHistory
        case .lidarr: return lidarrHistory
        case .whisparr: return whisparrHistory
        }
    }

    private static let hour = 60
    private static let day = 24 * 60

    static var radarrHistory: [HistoryItem] {
        [
            // Still downloading (it's in the demo queue) — compares against
            // the 1080p file on disk.
            historyItem(.radarr, id: "rh1", minutesAgo: 12, event: .grabbed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.BluRay.REMUX.HDR10.DV.Atmos-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "Remux Tier 01"], score: 1850,
                        posterSeed: "bigbuckbunny", arrId: 201, fileKey: "movie-201", downloadId: "demo-bbb-2160",
                        client: "NZBGet", indexer: "DemoTracker", sizeGB: 58.4,
                        fileOnDisk: .init(quality: "Bluray-1080p", score: 950, size: 15_246_083_194,
                                          formats: ["HDR10", "DTS-HD MA", "x264"],
                                          filename: "Big.Buck.Bunny.2008.1080p.BluRay.DTS-HD.x264-OLD.mkv"),
                        hadFile: true),
            // Upgrade import + the deletion of the file it replaced, and the
            // grab that started it.
            historyItem(.radarr, id: "rh2", minutesAgo: 95, event: .imported,
                        title: "Tears of Steel (2012)",
                        sourceTitle: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "x265"], score: 1720,
                        posterSeed: "tearsofsteel", arrId: 203, fileKey: "movie-203", downloadId: "demo-tos",
                        client: "qBittorrent", sizeGB: 4.5),
            historyItem(.radarr, id: "rh2-del", minutesAgo: 95, event: .deleted,
                        title: "Tears of Steel (2012)",
                        sourceTitle: "Tears.of.Steel.2012.1080p.WEB-DL.DDP5.1.x264-OLD.mkv",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "DDP 5.1", "x264"], score: 540,
                        posterSeed: "tearsofsteel", arrId: 203, fileKey: "movie-203",
                        sizeGB: 3.1, reason: "Upgrade"),
            historyItem(.radarr, id: "rh2-grab", minutesAgo: 140, event: .grabbed,
                        title: "Tears of Steel (2012)",
                        sourceTitle: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "x265"], score: 1720,
                        posterSeed: "tearsofsteel", arrId: 203, fileKey: "movie-203", downloadId: "demo-tos",
                        client: "qBittorrent", indexer: "DemoTracker", sizeGB: 4.5, hadFile: true),
            // A first download: no deletion beside the import → New.
            historyItem(.radarr, id: "rh3", minutesAgo: 4 * hour, event: .imported,
                        title: "Sintel (2010)",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "AV1"], score: 720,
                        posterSeed: "sintel", arrId: 202, fileKey: "movie-202", downloadId: "demo-sintel",
                        client: "qBittorrent", sizeGB: 4.5),
            historyItem(.radarr, id: "rh3-grab", minutesAgo: 5 * hour, event: .grabbed,
                        title: "Sintel (2010)",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "AV1"], score: 720,
                        posterSeed: "sintel", arrId: 202, fileKey: "movie-202", downloadId: "demo-sintel",
                        client: "qBittorrent", indexer: "DemoIndexer", sizeGB: 4.5, hadFile: false),
            historyItem(.radarr, id: "rh4", minutesAgo: 30 * hour, event: .failed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.WEB-DL.DDP5.1.H.265-BROKEN",
                        quality: "WEB-DL 2160p", formats: [], score: 0,
                        posterSeed: "bigbuckbunny", arrId: 201, fileKey: "movie-201", downloadId: "demo-bbb-broken",
                        client: "NZBGet"),
            historyItem(.radarr, id: "rh5", minutesAgo: 12 * day, event: .deleted,
                        title: "Elephants Dream (2006)",
                        sourceTitle: "Elephants.Dream.2006.720p.BluRay.x264-DEMO.mkv",
                        quality: "Bluray-720p", formats: ["x264"], score: 60,
                        posterSeed: "elephantsdream", sizeGB: 1.2, reason: "Manual"),
        ]
    }

    /// One Caminandes season pack, per episode as Sonarr logs it: the grabs,
    /// the imports, and the deletions of the 720p files they replaced. The
    /// view model folds grabs and imports into one row each.
    private static var sonarrSeasonPack: [HistoryItem] {
        let episodes = [(1, "Llama Drama"), (2, "Gran Dillama"), (3, "Llamigos")]
        let hint = HistoryItem.GroupHint(
            key: "demo-caminandes-s01|s1",
            collapsedSubtitle: String(format: String(localized: "detail.seasonLld.label", bundle: .module), 1)
        )
        let imports = episodes.flatMap { number, name in [
            historyItem(.sonarr, id: "sh-pack-imp-\(number)", minutesAgo: 3 * hour + number, event: .imported,
                        title: "Caminandes (2013)",
                        subtitle: String(format: "S01E%02d · %@", number, name),
                        sourceTitle: "Caminandes.S01.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264"], score: 640,
                        posterSeed: "caminandes", arrId: 102, fileKey: "episode-10\(number)",
                        downloadId: "demo-caminandes-s01", client: "qBittorrent", sizeGB: 1.5,
                        hint: hint),
            historyItem(.sonarr, id: "sh-pack-del-\(number)", minutesAgo: 3 * hour + number, event: .deleted,
                        title: "Caminandes (2013)",
                        subtitle: String(format: "S01E%02d · %@", number, name),
                        sourceTitle: String(format: "Caminandes.S01E%02d.720p.HDTV.x264-OLD.mkv", number),
                        quality: "HDTV-720p", formats: ["x264"], score: 120,
                        posterSeed: "caminandes", arrId: 102, fileKey: "episode-10\(number)",
                        sizeGB: 0.4, reason: "Upgrade"),
        ] }
        let grabs = episodes.map { number, name in
            historyItem(.sonarr, id: "sh-pack-grab-\(number)", minutesAgo: 4 * hour + number, event: .grabbed,
                        title: "Caminandes (2013)",
                        subtitle: String(format: "S01E%02d · %@", number, name),
                        sourceTitle: "Caminandes.S01.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264"], score: 640,
                        posterSeed: "caminandes", arrId: 102, fileKey: "episode-10\(number)",
                        downloadId: "demo-caminandes-s01", client: "qBittorrent", indexer: "DemoTracker",
                        sizeGB: 4.5, hadFile: true, hint: hint)
        }
        return imports + grabs
    }

    static var sonarrHistory: [HistoryItem] {
        [
            historyItem(.sonarr, id: "sh1", minutesAgo: 5, event: .grabbed,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E03 · Endurance",
                        sourceTitle: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264", "HQ Source Group"], score: 380,
                        posterSeed: "pioneerone", arrId: 101, fileKey: "episode-13", downloadId: "demo-p1-e03",
                        client: "SABnzbd", indexer: "DemoIndexer", sizeGB: 1.2, hadFile: false),
            historyItem(.sonarr, id: "sh2", minutesAgo: 60, event: .imported,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 180,
                        posterSeed: "pioneerone", arrId: 101, fileKey: "episode-12", downloadId: "demo-p1-e02",
                        client: "SABnzbd", sizeGB: 1.1),
            historyItem(.sonarr, id: "sh2-grab", minutesAgo: 80, event: .grabbed,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 180,
                        posterSeed: "pioneerone", arrId: 101, fileKey: "episode-12", downloadId: "demo-p1-e02",
                        client: "SABnzbd", indexer: "DemoIndexer", sizeGB: 1.1, hadFile: false),
        ] + sonarrSeasonPack + [
            historyItem(.sonarr, id: "sh3", minutesAgo: 3 * day, event: .imported,
                        title: "Caminandes (2013)",
                        subtitle: "S01E04 · Snow Day",
                        sourceTitle: "Caminandes.S01E04.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264", "HQ Source Group"], score: 720,
                        posterSeed: "caminandes", arrId: 102, fileKey: "episode-104", downloadId: "demo-cam-e04",
                        client: "qBittorrent", sizeGB: 1.6),
        ]
    }

    static var lidarrHistory: [HistoryItem] {
        [
            historyItem(.lidarr, id: "lh1", minutesAgo: 30, event: .grabbed,
                        title: "Nine Inch Nails",
                        subtitle: "Ghosts I-IV",
                        sourceTitle: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                        quality: "FLAC", formats: ["Lossless", "24bit"], score: 320,
                        posterSeed: "ninghosts", arrId: 301, downloadId: "demo-nin-ghosts",
                        client: "qBittorrent", indexer: "DemoTracker", sizeGB: 1.4),
        ] + bradSucksAlbumImports
    }

    /// Per-track rows of one imported album — folded into a single
    /// "Out of It · N tracks" history row by the view model.
    private static var bradSucksAlbumImports: [HistoryItem] {
        let hint = HistoryItem.GroupHint(key: "demo-brad-sucks-out-of-it|album-1")
        return (0..<11).map { idx in
            historyItem(.lidarr, id: "lh-track-\(idx)", minutesAgo: 10 * hour + idx, event: .imported,
                        title: "Brad Sucks",
                        subtitle: "Out of It",
                        sourceTitle: "Brad.Sucks-Out.of.It-MP3-DEMO",
                        quality: "MP3-320", formats: [], score: 0,
                        posterSeed: "bradsucks", arrId: 302, downloadId: "demo-brad-sucks-out-of-it",
                        client: "rTorrent",
                        hint: hint)
        }
    }

    static var whisparrHistory: [HistoryItem] {
        [
            historyItem(.whisparr, id: "wh1", minutesAgo: 6 * hour, event: .imported,
                        title: "The Black Cat Chronicles (2023)",
                        sourceTitle: "The.Black.Cat.Chronicles.2023.2160p.WEB-DL.HDR-DEMO",
                        quality: "WEB-DL 2160p", formats: ["HDR10", "AV1"], score: 690,
                        posterSeed: "kitten:millie", arrId: 402, fileKey: "movie-402", downloadId: "demo-black-cat",
                        client: "qBittorrent", sizeGB: 6.2),
            historyItem(.whisparr, id: "wh1-del", minutesAgo: 6 * hour, event: .deleted,
                        title: "The Black Cat Chronicles (2023)",
                        sourceTitle: "The.Black.Cat.Chronicles.2023.1080p.WEB-DL.x264-OLD.mkv",
                        quality: "WEB-DL 1080p", formats: ["x264"], score: 280,
                        posterSeed: "kitten:millie", arrId: 402, fileKey: "movie-402",
                        sizeGB: 2.3, reason: "Upgrade"),
            historyItem(.whisparr, id: "wh2", minutesAgo: 14 * hour, event: .grabbed,
                        title: "Kitten Cam: Backyard Drama (2024)",
                        sourceTitle: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["x264"], score: 280,
                        posterSeed: "kitten:neo", arrId: 401, fileKey: "movie-401", downloadId: "demo-kitten-cam",
                        client: "qBittorrent", indexer: "DemoIndexer", sizeGB: 2.1, hadFile: false),
        ]
    }
}
