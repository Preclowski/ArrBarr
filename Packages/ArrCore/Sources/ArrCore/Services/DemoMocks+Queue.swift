import Foundation

// Queue fixtures: per-arr static queue arrays plus the season-pack and independent-episode helpers used to assemble them.

extension DemoMocks {
    // MARK: - Queue

    static var radarrQueue: [QueueItem] {
        [
            queueItem(
                source: .radarr, id: "demo-radarr-1",
                title: "Big Buck Bunny (2008)",
                releaseName: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                status: .downloading, progress: 0.42,
                quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "TrueHD", "Remux Tier 01", "HQ Source Group"], score: 1850,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "bigbuckbunny", aspect: .portrait,
                entityId: 201
            ),
            queueItem(
                source: .radarr, id: "demo-radarr-2",
                title: "Sintel (2010)",
                releaseName: "Sintel.2010.1080p.WEB-DL.AV1-DEMO",
                status: .importing, progress: 1.0,
                quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "x264", "HQ Source Group"], score: 720,
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
            queueItem(
                source: .radarr, id: "demo-radarr-3",
                title: "Tears of Steel (2012)",
                releaseName: "Tears.of.Steel.2012.720p.WEB-DL.x264-DEMO",
                status: .paused, progress: 0.18,
                quality: "WEB-DL 720p", formats: ["LQ Release Group", "x264", "AAC 2.0"], score: -160,
                client: "Transmission", indexer: "DemoTracker",
                upgrade: false, posterSeed: "tearsofsteel", aspect: .portrait,
                entityId: 203
            ),
        ]
    }

    static var sonarrQueue: [QueueItem] {
        // Order: a single grabbed episode, then the Caminandes season pack
        // (so it sits in the middle and isn't last in the section), then the
        // three independent Pioneer One episodes (different downloadIds —
        // they should NOT group), then the remaining standalones.
        var items: [QueueItem] = [
            queueItem(
                source: .sonarr, id: "demo-sonarr-1",
                title: "Pioneer One (2010)",
                subtitle: "Season 01 · Episode 3 — Endurance",
                seasonNumber: 1, episodeNumber: 3, episodeTitle: "Endurance",
                releaseName: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                status: .downloading, progress: 0.67,
                quality: "HDTV-720p", formats: ["x264", "AAC 2.0", "Internal", "HQ Source Group"], score: 380,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "WEBRip-480p", formats: ["x264", "Repack"], score: 30,
                    size: 350_000_000,
                    fileName: "Pioneer.One.S01E03.480p.WEBRip-OLD.mkv"
                ),
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
        ]
        items.append(contentsOf: caminandesSeasonPack)
        items.append(contentsOf: tearsOfSteelSeasonPack)
        items.append(contentsOf: pioneerOneIndependentEpisodes)
        items.append(contentsOf: springTalesIndependentEpisodes)
        items.append(contentsOf: [
            queueItem(
                source: .sonarr, id: "demo-sonarr-2",
                title: "Cosmos Laundromat (2015)",
                subtitle: "Season 01 · Episode 1 — The Beginning",
                seasonNumber: 1, episodeNumber: 1, episodeTitle: "The Beginning",
                releaseName: "Cosmos.Laundromat.S01E01.1080p.WEB-DL-DEMO",
                status: .queued, progress: 0,
                quality: "WEB-DL 1080p", formats: ["AMZN", "x264"], score: 180,
                client: "NZBGet", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "cosmoslaundromat", aspect: .portrait,
                entityId: 104
            ),
            queueItem(
                source: .sonarr, id: "demo-sonarr-3",
                title: "Northern Cascade (2023)",
                subtitle: "Season 02 · Episode 4 — Cold Start",
                seasonNumber: 2, episodeNumber: 4, episodeTitle: "Cold Start",
                releaseName: "Northern.Cascade.S02E04.2160p.WEB-DL.DV.HDR10-DEMO",
                status: .warning, progress: 0.92,
                quality: "WEB-DL 2160p", formats: ["AMZN", "DV", "HDR10", "Atmos", "x265", "10bit"], score: 1240,
                client: "Deluge", indexer: "DemoTracker",
                upgrade: false, posterSeed: "northerncascade", aspect: .portrait,
                entityId: 105,
                statusMessages: [
                    "Import failed: No matching episode found in series.",
                    "The release group conflicts with the configured preferred-words list."
                ]
            ),
        ])
        return items
    }

    /// A 5-episode Caminandes season pack — all members share the same
    /// `downloadId` so QueueGrouping renders them as a single Sonarr row
    /// labelled "Caminandes · S01". Each episode's *existing* file comes
    /// from a different original release (mixed-source upgrade), which is
    /// the realistic case: one was a crisp HDTV grab, two were lower-tier,
    /// one missing entirely. The tooltip's per-episode grid shows it all.
    static var caminandesSeasonPack: [QueueItem] {
        let sharedDownloadId = "demo-pack-caminandes-s01"
        let baseRelease = "Caminandes.S01.1080p.WEB-DL.x264-DEMO"
        let episodes: [(num: Int, title: String, existing: ExistingFile?)] = [
            (1, "Llama Drama", ExistingFile(
                quality: "HDTV-720p", formats: ["x264", "Repack"], score: 60,
                size: 320_000_000,
                fileName: "Caminandes.S01E01.720p.HDTV.x264-CRISPY.mkv"
            )),
            (2, "Gran Dillama", ExistingFile(
                quality: "WEBRip-480p", formats: ["x264"], score: 20,
                size: 180_000_000,
                fileName: "Caminandes.S01E02.480p.WEBRip.x264-OTHER.mkv"
            )),
            (3, "Llamigos", nil), // missing — no existing file, just a fresh add
            (4, "Mountain Pass", ExistingFile(
                quality: "HDTV-720p", formats: ["x264"], score: 50,
                size: 290_000_000,
                fileName: "Caminandes.S01E04.720p.HDTV.x264-CRISPY.mkv"
            )),
            (5, "Frozen Lake", ExistingFile(
                quality: "DVDRip", formats: ["XviD", "MP3"], score: -40,
                size: 410_000_000,
                fileName: "Caminandes.S01E05.DVDRip.XviD-ANCIENT.avi"
            )),
        ]
        return episodes.map { ep in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pack-\(ep.num)",
                title: "Caminandes (2013)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@"), ep.num, ep.title),
                seasonNumber: 1, episodeNumber: ep.num, episodeTitle: ep.title,
                releaseName: baseRelease,
                status: .downloading,
                progress: 0.55,
                quality: "WEB-DL 1080p",
                formats: ["AMZN", "x264", "AAC 2.0", "HQ Source Group"],
                score: 720,
                client: "qBittorrent",
                indexer: "DemoTracker",
                upgrade: true,
                existing: ep.existing,
                posterSeed: "caminandes",
                aspect: .portrait,
                downloadId: sharedDownloadId,
                entityId: 102
            )
        }
    }

    /// A second season pack — fresh grab (not an upgrade) — so the demo
    /// has both a NEW pack and an UPGRADE pack visible side by side.
    static var tearsOfSteelSeasonPack: [QueueItem] {
        let sharedDownloadId = "demo-pack-tearsofsteel-s01"
        let baseRelease = "Tears.of.Steel.S01.2160p.WEB-DL.HDR-DEMO"
        let episodes: [(num: Int, title: String)] = [
            (1, "First Light"),
            (2, "Mecha"),
            (3, "Reunion"),
        ]
        return episodes.map { ep in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-tos-pack-\(ep.num)",
                title: "Tears of Steel (2012)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@"), ep.num, ep.title),
                seasonNumber: 1, episodeNumber: ep.num, episodeTitle: ep.title,
                releaseName: baseRelease,
                status: .downloading,
                progress: 0.18,
                quality: "WEB-DL 2160p",
                formats: ["AMZN", "DV", "HDR10", "Atmos", "x265"],
                score: 1450,
                client: "SABnzbd",
                indexer: "DemoUsenet",
                upgrade: false,
                posterSeed: "tearsofsteel",
                aspect: .portrait,
                downloadId: sharedDownloadId,
                entityId: 103
            )
        }
    }

    /// Three Pioneer One episodes downloaded as separate releases — each
    /// has its own `downloadId`, so QueueGrouping must render them as three
    /// independent rows even though they share a series. Verifies the
    /// "only group true season packs" rule.
    static var pioneerOneIndependentEpisodes: [QueueItem] {
        let releases: [(num: Int, title: String, status: QueueItem.Status, progress: Double, score: Int, formats: [String])] = [
            (4, "Brave New Earth",      .downloading, 0.34, 420, ["x264", "AAC 2.0"]),
            (5, "Foothold",             .queued,      0.0,  60,  []),
            (6, "Tomorrow Belongs to Us", .downloading, 0.78, 380, ["x264", "AAC 2.0", "HQ Source Group"]),
        ]
        return releases.map { rel in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pone-\(rel.num)",
                title: "Pioneer One (2010)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@"), rel.num, rel.title),
                seasonNumber: 1, episodeNumber: rel.num, episodeTitle: rel.title,
                releaseName: String(format: "Pioneer.One.S01E%02d.720p.HDTV.x264-DEMO", rel.num),
                status: rel.status,
                progress: rel.progress,
                quality: "HDTV-720p",
                formats: rel.formats,
                score: rel.score,
                client: "qBittorrent",
                indexer: "DemoTracker",
                upgrade: false,
                posterSeed: "pioneerone",
                aspect: .portrait,
                entityId: 101
                // No downloadId override — defaults to id, so each is unique.
            )
        }
    }

    /// Four Spring Tales episodes downloaded as separate releases. With
    /// the virtual-bundle collapse removed, each one renders as its own
    /// queue row — exactly like four independent Radarr movies would.
    /// Pause/resume targets exactly what the user sees; no fan-out
    /// trickery, no aggregate progress lying about which one is at what
    /// percent.
    static var springTalesIndependentEpisodes: [QueueItem] {
        let cfs = ["AMZN", "DDP 5.1", "x264"]
        let episodes: [(num: Int, title: String, status: QueueItem.Status, progress: Double)] = [
            (1, "Bloom",   .downloading, 0.82),
            (2, "Petals",  .downloading, 0.54),
            (3, "Pollen",  .downloading, 0.31),
            (4, "Wilt",    .queued,      0.00),
        ]
        return episodes.map { ep in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-springtales-\(ep.num)",
                title: "Spring Tales (2019)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@"), ep.num, ep.title),
                seasonNumber: 1, episodeNumber: ep.num, episodeTitle: ep.title,
                releaseName: String(format: "Spring.Tales.S01E%02d.1080p.WEB-DL.x264-DEMO", ep.num),
                status: ep.status,
                progress: ep.progress,
                quality: "WEB-DL 1080p",
                formats: cfs,
                score: 420,
                client: "qBittorrent",
                indexer: "DemoTracker",
                upgrade: false,
                posterSeed: "spring",
                aspect: .portrait,
                releaseGroup: "DEMO",
                entityId: 106
            )
        }
    }

    static var lidarrQueue: [QueueItem] {
        [
            queueItem(
                source: .lidarr, id: "demo-lidarr-1",
                title: "Nine Inch Nails — Ghosts I-IV",
                releaseName: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                status: .downloading, progress: 0.81,
                quality: "FLAC", formats: ["Lossless", "24bit", "Original Source"], score: 320,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "MP3-320", formats: ["Lossy"], score: -50,
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
        ]
    }

    static var whisparrQueue: [QueueItem] {
        [
            queueItem(
                source: .whisparr, id: "demo-whisparr-1",
                title: "Kitten Cam: Backyard Drama (2024)",
                releaseName: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                status: .downloading, progress: 0.55,
                quality: "WEB-DL 1080p", formats: ["x264", "Atmos", "HQ Source Group"], score: 280,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: false,
                posterSeed: "kitten:neo", aspect: .portrait,
                entityId: 401
            ),
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
