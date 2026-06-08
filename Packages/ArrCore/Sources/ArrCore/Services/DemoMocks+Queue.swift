import Foundation

// Queue fixtures: curated open-source universe (3 movies, 5 episodes / 2 series,
// 2 albums, 2 cat "nature films"). States are tuned to show off quality upgrades
// and custom-format scores. No failures/warnings — health stays green.

extension DemoMocks {
    // MARK: - Radarr (3 movies)

    static var radarrQueue: [QueueItem] {
        [
            // CF-score showcase: high-tier 2160p remux, big positive score.
            // Paused, to show the paused state alongside the score breakdown.
            queueItem(
                source: .radarr, id: "demo-radarr-1",
                title: "Big Buck Bunny (2008)",
                releaseName: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                status: .paused, progress: 0.42,
                quality: "Bluray-2160p",
                formats: ["HDR10+", "DV", "Atmos", "TrueHD", "Remux Tier 01", "HQ Source Group"], score: 1850,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "bigbuckbunny", aspect: .portrait,
                entityId: 201
            ),
            // Headline UPGRADE: Bluray-1080p -> Bluray-2160p, score jumps, size grows.
            queueItem(
                source: .radarr, id: "demo-radarr-2",
                title: "Tears of Steel (2012)",
                releaseName: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                status: .downloading, progress: 0.62,
                quality: "Bluray-2160p",
                formats: ["HDR10+", "DV", "Atmos", "TrueHD", "x265"], score: 1720,
                client: "NZBGet", indexer: "DemoUsenet",
                upgrade: true,
                existing: ExistingFile(
                    quality: "Bluray-1080p", formats: ["x264", "DTS-HD MA 5.1"], score: 350,
                    size: 8_400_000_000,
                    fileName: "Tears.of.Steel.2012.1080p.BluRay.x264-OLD.mkv"
                ),
                posterSeed: "tearsofsteel", aspect: .portrait,
                entityId: 203
            ),
            // Second upgrade, importing — codec/source bump (SD HDTV -> WEB-DL AV1).
            queueItem(
                source: .radarr, id: "demo-radarr-3",
                title: "Sintel (2010)",
                releaseName: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                status: .importing, progress: 1.0,
                quality: "WEB-DL 1080p",
                formats: ["AMZN", "Atmos", "DDP 5.1", "AV1", "HQ Source Group"], score: 720,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "HDTV-720p", formats: ["x264", "AAC 2.0"], score: 60,
                    size: 850_000_000,
                    fileName: "Sintel.2010.720p.HDTV.x264-OLD.mkv"
                ),
                posterSeed: "sintel", aspect: .portrait,
                entityId: 202
            ),
        ]
    }

    // MARK: - Sonarr (5 episodes / 2 series)

    static var sonarrQueue: [QueueItem] {
        // The Caminandes 2-ep season pack (groups into one row) followed by the
        // three independent Pioneer One S01 rows (distinct downloadIds => do NOT
        // group). 5 episodes total.
        var items: [QueueItem] = []
        items.append(contentsOf: caminandesSeasonPack)
        items.append(contentsOf: pioneerOneIndependentEpisodes)
        return items
    }

    /// Caminandes S01 two-episode pack — shared downloadId so QueueGrouping
    /// renders a single "Caminandes · S01" row. Each member is an upgrade over a
    /// different original file (mixed-source pack), shown in the per-episode grid.
    static var caminandesSeasonPack: [QueueItem] {
        let sharedDownloadId = "demo-pack-caminandes-s01"
        let baseRelease = "Caminandes.S01.1080p.WEB-DL.x264-DEMO"
        let episodes: [(num: Int, title: String, existing: ExistingFile?)] = [
            (2, "Gran Dillama", ExistingFile(
                quality: "WEBRip-480p", formats: ["x264"], score: 20,
                size: 180_000_000,
                fileName: "Caminandes.S01E02.480p.WEBRip.x264-OLD.mkv"
            )),
            (3, "Llamigos", ExistingFile(
                quality: "HDTV-720p", formats: ["x264", "Repack"], score: 60,
                size: 320_000_000,
                fileName: "Caminandes.S01E03.720p.HDTV.x264-OLD.mkv"
            )),
        ]
        return episodes.map { ep in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pack-\(ep.num)",
                title: "Caminandes (2013)",
                subtitle: String(format: "S01E%02lld · %@", ep.num, ep.title),
                seasonNumber: 1, episodeNumber: ep.num, episodeTitle: ep.title,
                releaseName: baseRelease,
                status: .downloading, progress: 0.55,
                quality: "WEB-DL 1080p",
                formats: ["AMZN", "x264", "AAC 2.0", "HQ Source Group"], score: 720,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true, existing: ep.existing,
                posterSeed: "caminandes", aspect: .portrait,
                downloadId: sharedDownloadId,
                entityId: 102
            )
        }
    }

    /// Three Pioneer One S01 episodes grabbed as separate releases — each has its
    /// own downloadId, so they render as three independent rows. E03 is an
    /// upgrade; E04 a fresh grab; E05 queued.
    static var pioneerOneIndependentEpisodes: [QueueItem] {
        let releases: [(num: Int, title: String, status: QueueItem.Status, progress: Double, score: Int, formats: [String], upgrade: Bool, existing: ExistingFile?)] = [
            (3, "Endurance", .downloading, 0.67, 380, ["x264", "AAC 2.0", "HQ Source Group"], true,
                ExistingFile(quality: "WEBRip-480p", formats: ["x264", "Repack"], score: 30,
                             size: 350_000_000, fileName: "Pioneer.One.S01E03.480p.WEBRip-OLD.mkv")),
            (4, "Brave New Earth", .paused, 0.34, 420, ["x264", "AAC 2.0"], false, nil),
            (5, "Foothold", .queued, 0.0, 60, [], false, nil),
        ]
        return releases.map { rel in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pone-\(rel.num)",
                title: "Pioneer One (2010)",
                subtitle: String(format: "S01E%02lld · %@", rel.num, rel.title),
                seasonNumber: 1, episodeNumber: rel.num, episodeTitle: rel.title,
                releaseName: String(format: "Pioneer.One.S01E%02d.720p.HDTV.x264-DEMO", rel.num),
                status: rel.status, progress: rel.progress,
                quality: "HDTV-720p", formats: rel.formats, score: rel.score,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: rel.upgrade, existing: rel.existing,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            )
        }
    }

    // MARK: - Lidarr (2 albums)

    static var lidarrQueue: [QueueItem] {
        [
            // UPGRADE: MP3-320 -> FLAC lossless.
            queueItem(
                source: .lidarr, id: "demo-lidarr-1",
                title: "Nine Inch Nails — Ghosts I-IV",
                releaseName: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                status: .downloading, progress: 0.81,
                quality: "FLAC", formats: ["Lossless", "24bit", "Original Source"], score: 320,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "MP3-320", formats: ["Lossy"], score: 0,
                    size: 220_000_000,
                    fileName: "Nine Inch Nails - Ghosts I-IV (320kbps).zip"
                ),
                posterSeed: "ninghosts", aspect: .square,
                entityId: 301
            ),
            queueItem(
                source: .lidarr, id: "demo-lidarr-2",
                title: "Brad Sucks — Out of It",
                releaseName: "Brad.Sucks-Out.of.It-MP3-DEMO",
                status: .completed, progress: 1.0,
                quality: "MP3-320", formats: [], score: 0,
                client: "rTorrent", indexer: "DemoTracker",
                upgrade: false, posterSeed: "bradsucks", aspect: .square,
                entityId: 302
            ),
            // UPGRADE: MP3-V0 -> FLAC lossless on Brad Sucks' 2003 debut.
            queueItem(
                source: .lidarr, id: "demo-lidarr-3",
                title: "Brad Sucks — I Don't Know What I'm Doing",
                releaseName: "Brad.Sucks-I.Dont.Know.What.Im.Doing-FLAC-2003-DEMO",
                status: .downloading, progress: 0.37,
                quality: "FLAC", formats: ["Lossless", "Original Source"], score: 220,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "MP3-VBR V0", formats: ["Lossy"], score: 0,
                    size: 78_000_000,
                    fileName: "Brad Sucks - I Don't Know What I'm Doing (V0).zip"
                ),
                posterSeed: "bradsucks-debut", aspect: .square,
                entityId: 303
            ),
        ]
    }

    // MARK: - Whisparr (2 cat "nature films")

    static var whisparrQueue: [QueueItem] {
        [
            queueItem(
                source: .whisparr, id: "demo-whisparr-1",
                title: "Kitten Cam: Backyard Drama (2024)",
                releaseName: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                status: .downloading, progress: 0.55,
                quality: "WEB-DL 1080p", formats: ["x264", "Atmos", "HQ Source Group"], score: 280,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: false, posterSeed: "kitten:neo", aspect: .portrait,
                entityId: 401
            ),
            // UPGRADE: 1080p -> 2160p HDR.
            queueItem(
                source: .whisparr, id: "demo-whisparr-2",
                title: "The Black Cat Chronicles (2023)",
                releaseName: "The.Black.Cat.Chronicles.2023.2160p.WEB-DL.HDR-DEMO",
                status: .completed, progress: 1.0,
                quality: "WEB-DL 2160p", formats: ["HDR10", "AV1"], score: 690,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: true,
                existing: ExistingFile(
                    quality: "WEB-DL 1080p", formats: ["x264"], score: 240,
                    size: 2_400_000_000,
                    fileName: "The.Black.Cat.Chronicles.2023.1080p.WEB-DL.x264-OLD.mkv"
                ),
                posterSeed: "kitten:millie", aspect: .portrait,
                entityId: 402
            ),
        ]
    }
}
