import Foundation

/// Developer mode: reveals the "Developer options" section in Settings, which
/// is where the Demo mode toggle, test notifications, and replay-welcome
/// buttons live. Decoupled from `DemoMode` so that you can poke at the dev
/// options without forcing fixtures on yourself.
///
/// Activate by any of:
///   - Launch arg:        --demo  (persisted to UserDefaults on first sight)
///   - Env var:           ARRBARR_DEMO=1  (persisted to UserDefaults)
///   - UserDefaults:      defaults write com.preclowski.ArrBarr ArrBarrDeveloperMode -bool true
public enum DeveloperMode {
    public static let key = "ArrBarrDeveloperMode"

    public static var isActive: Bool {
        let defaults = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        let envOn = ProcessInfo.processInfo.environment["ARRBARR_DEMO"] == "1"
        if args.contains("--demo") || envOn {
            // Persist so subsequent launches without the flag still keep
            // dev options visible — matches how the welcome-screen handoff
            // sets the same UserDefault.
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }

    /// Manually flip Developer mode on/off — used by the iOS About-section
    /// 7-tap easter egg since iOS users can't pass launch args.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

/// Demo mode: ship a runnable preview without needing real Radarr/Sonarr/Lidarr instances.
/// Toggled from the "Demo mode" checkbox inside Developer options. The flag is
/// read live from UserDefaults so flipping it can take effect within the same
/// session — every consumer that reads `isActive` (the queue refresh path,
/// the popover's `isVisible(_:)` filter, etc.) sees the new value on its
/// next call.
public enum DemoMode {
    public static let key = "ArrBarrDemo"

    public static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }

    private static let seedDoneKey = "ArrBarr.demoSeedDone"

    /// First-time demo users get all three arrs flipped to `enabled` so the popover
    /// has something to show out of the box. After the seed runs once, we respect
    /// the user's toggles — disabling Lidarr in settings actually hides it.
    @MainActor
    public static func seedConfigsIfNeeded(_ store: ConfigStore) {
        guard isActive else { return }
        guard !UserDefaults.standard.bool(forKey: seedDoneKey) else { return }
        // Lidarr / Whisparr are intentionally NOT seeded — they're niche
        // and should stay off by default. The user opts in from Settings
        // when they actually use them.
        if store.radarr == .empty { store.radarr.enabled = true }
        if store.sonarr == .empty { store.sonarr.enabled = true }
        UserDefaults.standard.set(true, forKey: seedDoneKey)
    }
}

/// Public-domain / CC-licensed titles used as preview content.
/// Posters come from picsum.photos with deterministic seeds, no auth.
public enum DemoMocks {
    /// Real, stable Wikipedia-hosted poster art for the open-source / CC titles
    /// used in demo mode. Wikipedia's `Special:FilePath` endpoint resolves to the
    /// current canonical CDN location, so these URLs survive bucket rehashing.
    private static let realPosters: [String: String] = [
        "bigbuckbunny":      "Big_buck_bunny_poster_big.jpg",
        "sintel":            "Sintel_poster.jpg",
        "tearsofsteel":      "Tos-poster.png",
        "spring":            "Spring2019AlphaPosterBlender.jpg",
        "cosmoslaundromat":  "CosmosLaundromatPoster.jpg",
        "caminandes":        "Blender_Foundation_-_Caminandes_-_Episode_3_-_Llamigos_-_Cover_thumbnail.png",
        "pioneerone":        "Artwork_for_the_2010_Pioneer_One_series.jpg",
        "ninghosts":         "Nine_Inch_Nails_-_Ghosts_I-IV.png",
        "bradsucks":         "Brad_Sucks_Out_of_It.jpg",
        "coultonsomeguys":   "Jonathan_Coulton_-_Some_Guys.jpg",
    ]

    private static func poster(label: String, seed: String, w: Int = 200, h: Int = 300) -> URL? {
        // Whisparr demo: posters are kittens. seed is "kitten:<image_id>" — e.g.
        // "kitten:neo", "kitten:millie". placecats.com is a free, no-auth cat
        // placeholder service that takes a named image plus dimensions.
        if seed.hasPrefix("kitten:") {
            let id = String(seed.dropFirst("kitten:".count))
            // placecats.com format: https://placecats.com/<image_id>/<w>/<h>
            return URL(string: "https://placecats.com/\(id)/\(w)/\(h)")
        }

        if let filename = realPosters[seed] {
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            return URL(string: "https://en.wikipedia.org/wiki/Special:FilePath/\(encoded)?width=\(w * 2)")
        }
        let palette = ["3b1d52", "1c3859", "4a2c1d", "1d4a3a", "5c1f1f", "3a3a1f", "1f4a52", "4a1f4a"]
        let bg = palette[abs(seed.hashValue) % palette.count]
        let encoded = label
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            ?? label
        return URL(string: "https://placehold.co/\(w)x\(h)/\(bg)/ffffff/png?text=\(encoded)&font=lato")
    }

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
                entityId: 105
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
    private static var caminandesSeasonPack: [QueueItem] {
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
    private static var tearsOfSteelSeasonPack: [QueueItem] {
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
    private static var pioneerOneIndependentEpisodes: [QueueItem] {
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
    private static var springTalesIndependentEpisodes: [QueueItem] {
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

    // MARK: - History

    static func history(for source: QueueItem.Source) -> [HistoryItem] {
        switch source {
        case .radarr: return radarrHistory
        case .sonarr: return sonarrHistory
        case .lidarr: return lidarrHistory
        case .whisparr: return whisparrHistory
        }
    }

    private static var radarrHistory: [HistoryItem] {
        [
            historyItem(.radarr, id: "rh1", minutesAgo: 12, event: .grabbed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "Remux Tier 01"], score: 1850),
            historyItem(.radarr, id: "rh2", minutesAgo: 95, event: .imported,
                        title: "Sintel (2010)",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "x264"], score: 720),
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
                        title: "Pioneer One (2010)",
                        subtitle: "S01E03 · Endurance",
                        sourceTitle: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 50),
            historyItem(.sonarr, id: "sh2", minutesAgo: 60, event: .imported,
                        title: "Pioneer One",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 50),
            historyItem(.sonarr, id: "sh3", minutesAgo: 320, event: .imported,
                        title: "Northern Cascade (2023)",
                        subtitle: "S02E03 · Whiteout",
                        sourceTitle: "Northern.Cascade.S02E03.2160p.WEB-DL.DV.HDR10-DEMO",
                        quality: "WEB-DL 2160p", formats: ["AMZN", "DV", "HDR10", "Atmos"], score: 1240),
            historyItem(.sonarr, id: "sh4", minutesAgo: 2880, event: .failed,
                        title: "Cosmos Laundromat (2015)",
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

    private static var whisparrHistory: [HistoryItem] {
        [
            historyItem(.whisparr, id: "wh1", minutesAgo: 360, event: .imported,
                        title: "The Black Cat Chronicles (2023)",
                        subtitle: "Upgrade — Bluray-2160p HDR",
                        sourceTitle: "Black.Cat.Chronicles.2023.2160p.BluRay.HDR.x265.DV-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10", "DV", "x265"], score: 920),
            historyItem(.whisparr, id: "wh2", minutesAgo: 840, event: .grabbed,
                        title: "Kitten Cam: Backyard Drama (2024)",
                        sourceTitle: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["x264"], score: 280),
            historyItem(.whisparr, id: "wh3", minutesAgo: 1560, event: .failed,
                        title: "Nine Lives of Mittens (2022)",
                        sourceTitle: "Nine.Lives.of.Mittens.2022.720p.WEB-DL-DEMO",
                        quality: "WEB-DL 720p", formats: ["x264"], score: -120),
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
        seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil,
        releaseName: String? = nil,
        status: QueueItem.Status, progress: Double,
        quality: String?, formats: [String], score: Int,
        client: String = "qBittorrent", indexer: String? = nil,
        upgrade: Bool, existing: ExistingFile? = nil,
        posterSeed: String, aspect: Aspect,
        downloadId: String? = nil,
        releaseGroup: String? = nil,
        entityId: Int? = nil
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
            downloadId: downloadId ?? id, downloadProtocol: proto, downloadClient: client,
            indexer: indexer,
            title: title, subtitle: subtitle,
            seasonNumber: seasonNumber, episodeNumber: episodeNumber, episodeTitle: episodeTitle,
            releaseName: releaseName,
            status: status, progress: progress,
            sizeTotal: total, sizeLeft: left, timeLeft: timeLeft,
            customFormats: formats, customFormatScore: score,
            quality: quality, releaseGroup: releaseGroup, isUpgrade: upgrade,
            existingCustomFormats: existing?.formats ?? [],
            existingCustomFormatScore: existing?.score,
            existingQuality: existing?.quality,
            existingSize: existing?.size,
            existingFileName: existing?.fileName,
            contentSlug: posterSeed,
            entityId: entityId,
            posterURL: poster(label: posterLabel(title: title, subtitle: subtitle), seed: posterSeed, w: w, h: h),
            posterRequiresAuth: false
        )
    }

    private static func posterLabel(title: String, subtitle: String?) -> String {
        if let sub = subtitle, let ep = sub.split(separator: "·").first?.trimmingCharacters(in: .whitespaces) {
            return "\(title)\n\(ep)"
        }
        return title
    }

    private static func upcomingItem(
        source: UpcomingItem.Source, id: String,
        title: String, subtitle: String? = nil,
        daysAhead: Int = 0, hoursAhead: Int = 0,
        releaseType: String, hasFile: Bool,
        posterSeed: String, aspect: Aspect,
        entityId: Int? = nil
    ) -> UpcomingItem {
        let cal = Calendar.current
        let withDays = cal.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
        let date = cal.date(byAdding: .hour, value: hoursAhead, to: withDays) ?? withDays
        let (w, h) = (aspect == .square) ? (200, 200) : (200, 300)
        // Fake ratings + runtime per source so the demo upcoming list shows
        // the same metadata richness as real arr data. Deterministic from
        // the title hash so each row gets a stable score across launches.
        // Lidarr stays nil — album runtime isn't a single number.
        let hash = abs(title.hashValue)
        let imdb = (source == .lidarr) ? nil : Double(60 + hash % 35) / 10.0  // 6.0–9.5
        let runtime: Int? = {
            switch source {
            case .radarr, .whisparr: return 90 + hash % 60   // 90–149 min
            case .sonarr:            return 22 + hash % 40   // 22–61 min episode
            case .lidarr:            return nil
            }
        }()
        return UpcomingItem(
            id: id, source: source, title: title, subtitle: subtitle,
            airDate: date, releaseType: releaseType, hasFile: hasFile,
            overview: "Demo overview text. \(title) is part of the open-source / CC-licensed sample content used for ArrBarr previews.",
            posterURL: poster(label: posterLabel(title: title, subtitle: subtitle), seed: posterSeed, w: w, h: h),
            posterRequiresAuth: false,
            imdb: imdb,
            runtime: runtime,
            entityId: entityId
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

    // MARK: - Detail-view fixtures
    //
    // The detail panels (RadarrMovieDetail, SonarrSeriesDetail,
    // LidarrAlbumDetail) feed `MediaHeaderCard`, the season list, the
    // existing-file banner, etc. Each entry below corresponds to a
    // queue item's `entityId` so DetailView can look up rich metadata
    // when the user taps a row.

    /// Lookup helper used by RadarrClient.fetchMovieDetails when
    /// DemoMode is active.
    public static func radarrMovieDetail(id: Int) -> RadarrMovieDetail? {
        radarrDetails[id]
    }

    public static func sonarrSeriesDetail(id: Int) -> SonarrSeriesDetail? {
        sonarrDetails[id]
    }

    public static func sonarrEpisodes(seriesId: Int) -> [SonarrEpisodeDetail] {
        sonarrEpisodeData[seriesId] ?? []
    }

    public static func lidarrAlbumDetail(id: Int) -> LidarrAlbumDetail? {
        lidarrDetails[id]
    }

    public static func lidarrTracks(albumId: Int) -> [LidarrTrackDetail] {
        lidarrTrackData[albumId] ?? []
    }

    private static func image(seed: String, kind: String = "poster") -> ArrImage {
        let url = poster(label: "", seed: seed, w: 220, h: 330)?.absoluteString
        return ArrImage(coverType: kind, url: url, remoteUrl: url)
    }

    private static var radarrDetails: [Int: RadarrMovieDetail] {
        [
            201: RadarrMovieDetail(
                id: 201,
                title: "Big Buck Bunny",
                year: 2008,
                overview: "A large rabbit deals with three bullying rodents who terrorise the forest. Big Buck Bunny shows off the open-source Blender movie pipeline at peak whimsy — a benchmark short for compositing, fluid sims, and fur shading that tens of millions of streams later still works as a charming standalone.",
                runtime: 10,
                genres: ["Animation", "Comedy", "Family", "Short"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 6.5, votes: 24_000),
                    tmdb: RadarrRatingValue(value: 7.2, votes: 1_100),
                    metacritic: RadarrRatingValue(value: 78, votes: nil),
                    rottenTomatoes: RadarrRatingValue(value: 92, votes: nil)
                ),
                images: [image(seed: "bigbuckbunny")],
                studio: "Blender Foundation",
                certification: "G",
                titleSlug: "bigbuckbunny",
                movieFile: nil,
                inCinemas: nil,
                status: "released"
            ),
            202: RadarrMovieDetail(
                id: 202,
                title: "Sintel",
                year: 2010,
                overview: "A girl scours a hostile world for her lost dragon companion. Blender's third open-movie short, fronted by a lush hand-drawn opening cut to live-action plates and a haunting Jan Morgenstern score; widely cited as the moment Blender's renderer crossed the line into 'good enough for theatrical' for short-form work.",
                runtime: 14,
                genres: ["Animation", "Adventure", "Drama", "Fantasy"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 8.0, votes: 7_300),
                    tmdb: RadarrRatingValue(value: 7.9, votes: 480),
                    metacritic: nil,
                    rottenTomatoes: RadarrRatingValue(value: 88, votes: nil)
                ),
                images: [image(seed: "sintel")],
                studio: "Blender Foundation",
                certification: "PG",
                titleSlug: "sintel",
                movieFile: nil,
                inCinemas: nil,
                status: "released"
            ),
            203: RadarrMovieDetail(
                id: 203,
                title: "Tears of Steel",
                year: 2012,
                overview: "A small group of warriors and scientists gather at the foot of an Amsterdam landmark to make a desperate stand against a robot uprising. Blender's first big live-action / VFX hybrid — the project that pushed compositing, motion-capture cleanup, and node-based shading into Blender's main branch.",
                runtime: 12,
                genres: ["Action", "Sci-Fi", "Short"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 6.7, votes: 4_200),
                    tmdb: RadarrRatingValue(value: 6.9, votes: 320),
                    metacritic: nil,
                    rottenTomatoes: nil
                ),
                images: [image(seed: "tearsofsteel")],
                studio: "Blender Foundation",
                certification: "PG",
                titleSlug: "tearsofsteel",
                movieFile: nil,
                inCinemas: nil,
                status: "released"
            ),
        ]
    }

    private static var sonarrDetails: [Int: SonarrSeriesDetail] {
        [
            101: SonarrSeriesDetail(
                id: 101,
                title: "Pioneer One",
                year: 2010,
                overview: "A mysterious capsule re-enters the atmosphere over Montana. As the US government investigates, a deeper Cold War-era conspiracy starts to unravel. The first show ever crowdfunded on BitTorrent — released CC-BY-SA, episode by episode, while the world figured out how to pay creators directly.",
                genres: ["Drama", "Mystery", "Sci-Fi"],
                runtime: 35,
                ratings: SonarrDetailRatings(value: 7.4, votes: 1_840),
                network: "VODO",
                status: "ended",
                images: [image(seed: "pioneerone")],
                titleSlug: "pioneerone",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 4, episodeCount: 6, totalEpisodeCount: 6,
                        sizeOnDisk: 2_400_000_000, percentOfEpisodes: 66.6
                    )),
                    SonarrSeasonInfo(seasonNumber: 2, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2010-06-16"
            ),
            102: SonarrSeriesDetail(
                id: 102,
                title: "Caminandes",
                year: 2013,
                overview: "Koro, a wide-eyed Patagonian llama, just wants to live his life — but the trail keeps giving him reasons not to. Three short episodes of Blender Foundation slapstick that became a tutorial pipeline for character rigging, eye shading, and snow simulation.",
                genres: ["Animation", "Comedy", "Family"],
                runtime: 5,
                ratings: SonarrDetailRatings(value: 7.6, votes: 2_300),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "caminandes")],
                titleSlug: "caminandes",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 3, episodeCount: 5, totalEpisodeCount: 5,
                        sizeOnDisk: 1_400_000_000, percentOfEpisodes: 60
                    )),
                ],
                firstAired: "2013-04-13"
            ),
            103: SonarrSeriesDetail(
                id: 103,
                title: "Tears of Steel",
                year: 2012,
                overview: "A serialised continuation of the Blender short — the same Amsterdam crew, episode-by-episode, exploring the years between the robot uprising and the human resistance. Demo placeholder for a sci-fi season pack.",
                genres: ["Sci-Fi", "Action", "Drama"],
                runtime: 28,
                ratings: SonarrDetailRatings(value: 7.1, votes: 980),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "tearsofsteel")],
                titleSlug: "tearsofsteel-series",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 3, totalEpisodeCount: 3,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2012-09-26"
            ),
            104: SonarrSeriesDetail(
                id: 104,
                title: "Cosmos Laundromat",
                year: 2015,
                overview: "Franck the suicidal sheep meets a multiversal salesman who promises any life he can imagine — for a price. The Blender Foundation's experimental open-movie pilot; demo content for a half-hour adult-animation drama.",
                genres: ["Animation", "Drama", "Fantasy"],
                runtime: 12,
                ratings: SonarrDetailRatings(value: 7.5, votes: 1_400),
                network: "Blender Foundation",
                status: "ended",
                images: [image(seed: "cosmoslaundromat")],
                titleSlug: "cosmoslaundromat-series",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 1, totalEpisodeCount: 1,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2015-08-10"
            ),
            105: SonarrSeriesDetail(
                id: 105,
                title: "Northern Cascade",
                year: 2023,
                overview: "A team of glaciologists, climbers, and a reluctant journalist disappear in the Cascade range. Each season unwinds the timeline differently — what they took with them, what they left behind, and what was already there before they arrived. (Demo placeholder.)",
                genres: ["Drama", "Mystery", "Thriller"],
                runtime: 52,
                ratings: SonarrDetailRatings(value: 8.4, votes: 12_500),
                network: "Demo Streaming",
                status: "continuing",
                images: [image(seed: "northerncascade")],
                titleSlug: "northerncascade",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 8, episodeCount: 8, totalEpisodeCount: 8,
                        sizeOnDisk: 36_000_000_000, percentOfEpisodes: 100
                    )),
                    SonarrSeasonInfo(seasonNumber: 2, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 3, episodeCount: 8, totalEpisodeCount: 8,
                        sizeOnDisk: 14_500_000_000, percentOfEpisodes: 37.5
                    )),
                ],
                firstAired: "2023-02-09"
            ),
            106: SonarrSeriesDetail(
                id: 106,
                title: "Spring Tales",
                year: 2019,
                overview: "An animated anthology of folklore retold from the perspective of small things — a bee on a stalk, a frog in a puddle, a salamander under a stone. A spiritual descendant of Blender's `Spring` short, expanded into a season of slow-paced visual storytelling. (Demo placeholder.)",
                genres: ["Animation", "Family", "Drama"],
                runtime: 22,
                ratings: SonarrDetailRatings(value: 8.0, votes: 3_200),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "spring")],
                titleSlug: "springtales",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2019-04-04"
            ),
        ]
    }

    private static var sonarrEpisodeData: [Int: [SonarrEpisodeDetail]] {
        [
            101: [ // Pioneer One
                episode(101, 1, 1, "Earthfall", "A capsule re-enters over rural Montana.", daysAgo: 700, hasFile: true),
                episode(102, 1, 2, "Tomorrow Belongs to Us", "DHS gets involved.", daysAgo: 690, hasFile: true),
                episode(103, 1, 3, "Endurance", "A doctor risks her career.", daysAgo: 680, hasFile: false),
                episode(104, 1, 4, "Brave New Earth", "The signal travels.", daysAgo: 670, hasFile: false),
                episode(105, 1, 5, "Foothold", "An offer no one can refuse.", daysAgo: 660, hasFile: false),
                episode(106, 1, 6, "What Remains", "Things break, others mend.", daysAgo: 650, hasFile: true),
                episode(201, 2, 1, "Reentry", "Aftermath.", daysAhead: 1, hasFile: false),
                episode(202, 2, 2, "Witness", "An unexpected ally.", daysAhead: 8, hasFile: false),
                episode(203, 2, 3, "Cold War Echo", "An old enemy.", daysAhead: 15, hasFile: false),
                episode(204, 2, 4, "Diaspora", "The cosmonaut speaks.", daysAhead: 22, hasFile: false),
            ],
            102: [ // Caminandes
                episode(301, 1, 1, "Llama Drama", "Koro meets a fence.", daysAgo: 1100, hasFile: true),
                episode(302, 1, 2, "Gran Dillama", "Koro meets a llama-vending machine.", daysAgo: 950, hasFile: true),
                episode(303, 1, 3, "Llamigos", "Koro meets a penguin.", daysAgo: 800, hasFile: false),
                episode(304, 1, 4, "Mountain Pass", "Koro climbs.", daysAgo: 600, hasFile: true),
                episode(305, 1, 5, "Frozen Lake", "Koro slips.", daysAgo: 400, hasFile: false),
            ],
            105: [ // Northern Cascade
                episode(701, 2, 1, "First Tracks", "A return to the range.", daysAgo: 70, hasFile: true),
                episode(702, 2, 2, "Approach", "The team splits.", daysAgo: 63, hasFile: true),
                episode(703, 2, 3, "Whiteout", "Visibility drops to zero.", daysAgo: 56, hasFile: true),
                episode(704, 2, 4, "Cold Start", "Equipment fails.", daysAgo: 49, hasFile: false),
                episode(705, 2, 5, "Bivouac", "A long night.", daysAgo: 42, hasFile: false),
                episode(706, 2, 6, "Crevasse", "Someone goes down.", daysAhead: 0, hasFile: false),
                episode(707, 2, 7, "Recovery", "Helicopter on standby.", daysAhead: 7, hasFile: false),
                episode(708, 2, 8, "Aftermath", "Press conference.", daysAhead: 14, hasFile: false),
            ],
            106: sprintTalesEpisodes,
            103: tosSeriesEpisodes,
            104: [
                episode(901, 1, 1, "The Beginning", "Franck negotiates.", daysAhead: 0, hasFile: false),
            ],
        ]
    }

    private static var sprintTalesEpisodes: [SonarrEpisodeDetail] {
        [
            episode(801, 1, 1, "Bloom", "A flower opens.", daysAgo: 0, hasFile: false),
            episode(802, 1, 2, "Petals", "A breeze picks up.", daysAhead: 7, hasFile: false),
            episode(803, 1, 3, "Pollen", "A bee visits.", daysAhead: 14, hasFile: false),
            episode(804, 1, 4, "Wilt", "Autumn arrives.", daysAhead: 21, hasFile: false),
        ]
    }

    private static var tosSeriesEpisodes: [SonarrEpisodeDetail] {
        [
            episode(401, 1, 1, "First Light", "The team gathers.", daysAgo: 30, hasFile: false),
            episode(402, 1, 2, "Mecha", "An old enemy returns.", daysAgo: 23, hasFile: false),
            episode(403, 1, 3, "Reunion", "Decisions made.", daysAgo: 16, hasFile: false),
        ]
    }

    private static func episode(
        _ id: Int, _ season: Int, _ number: Int,
        _ title: String, _ overview: String,
        daysAgo: Int = -1, daysAhead: Int = -1,
        hasFile: Bool
    ) -> SonarrEpisodeDetail {
        let date: Date
        if daysAgo >= 0 {
            date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        } else if daysAhead >= 0 {
            date = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
        } else {
            date = Date()
        }
        let fmt = ISO8601DateFormatter()
        return SonarrEpisodeDetail(
            id: id, seasonNumber: season, episodeNumber: number,
            title: title, overview: overview,
            airDateUtc: fmt.string(from: date),
            hasFile: hasFile, monitored: true, runtime: 45,
            episodeFileId: hasFile ? id : nil
        )
    }

    private static var lidarrDetails: [Int: LidarrAlbumDetail] {
        [
            301: LidarrAlbumDetail(
                id: 301,
                title: "Ghosts I-IV",
                overview: "Trent Reznor and Atticus Ross's 36-track instrumental sprawl, released directly to fans on a tiered model that essentially invented the modern artist-direct download. Available freely under CC-BY-NC-SA — perfect demo content for a music tracker.",
                releaseDate: "2008-03-02",
                genres: ["Electronic", "Industrial", "Ambient", "Instrumental"],
                ratings: LidarrDetailRatings(value: 8.2, votes: 4_500),
                images: [image(seed: "ninghosts", kind: "cover")],
                artist: LidarrArtist(
                    id: 301, artistName: "Nine Inch Nails",
                    foreignArtistId: "b7ffd2af-418f-4be2-bdd1-22f8b48613da",
                    images: [image(seed: "ninghosts", kind: "poster")]
                ),
                foreignAlbumId: "ghosts-i-iv-2008",
                albumType: "Album",
                duration: 1_960_000, // ~33 min
                statistics: LidarrAlbumStats(
                    trackCount: 36, trackFileCount: 12, totalTrackCount: 36,
                    sizeOnDisk: 280_000_000
                )
            ),
            302: LidarrAlbumDetail(
                id: 302,
                title: "Out of It",
                overview: "Brad Sucks's third self-released album of cynical, hooky DIY rock. Made in his basement, released for free, distributed via direct downloads and CC licensing — a poster child for the open-music movement Lidarr was built to track.",
                releaseDate: "2017-04-04",
                genres: ["Indie Rock", "Alternative", "DIY"],
                ratings: LidarrDetailRatings(value: 7.6, votes: 320),
                images: [image(seed: "bradsucks", kind: "cover")],
                artist: LidarrArtist(
                    id: 302, artistName: "Brad Sucks",
                    foreignArtistId: "1ce18a52-ca5f-4f34-9bc6-5f2af0d33f5e",
                    images: [image(seed: "bradsucks", kind: "poster")]
                ),
                foreignAlbumId: "out-of-it-2017",
                albumType: "Album",
                duration: 2_280_000, // ~38 min
                statistics: LidarrAlbumStats(
                    trackCount: 11, trackFileCount: 11, totalTrackCount: 11,
                    sizeOnDisk: 95_000_000
                )
            ),
        ]
    }

    private static var lidarrTrackData: [Int: [LidarrTrackDetail]] {
        [
            301: [
                track(3001, "1", 1, "1 Ghosts I", duration_ms: 152_000, hasFile: true),
                track(3002, "2", 2, "2 Ghosts I", duration_ms: 218_000, hasFile: true),
                track(3003, "3", 3, "3 Ghosts I", duration_ms: 218_000, hasFile: true),
                track(3004, "4", 4, "4 Ghosts I", duration_ms: 137_000, hasFile: true),
                track(3005, "5", 5, "5 Ghosts I", duration_ms: 169_000, hasFile: true),
                track(3006, "6", 6, "6 Ghosts I", duration_ms: 240_000, hasFile: true),
                track(3007, "7", 7, "7 Ghosts I", duration_ms: 153_000, hasFile: true),
                track(3008, "8", 8, "8 Ghosts I", duration_ms: 178_000, hasFile: true),
                track(3009, "9", 9, "9 Ghosts I", duration_ms: 165_000, hasFile: true),
                track(3010, "10", 10, "10 Ghosts II", duration_ms: 180_000, hasFile: true),
                track(3011, "11", 11, "11 Ghosts II", duration_ms: 245_000, hasFile: true),
                track(3012, "12", 12, "12 Ghosts II", duration_ms: 225_000, hasFile: true),
                track(3013, "13", 13, "13 Ghosts II", duration_ms: 277_000, hasFile: false),
                track(3014, "14", 14, "14 Ghosts II", duration_ms: 113_000, hasFile: false),
                track(3015, "15", 15, "15 Ghosts II", duration_ms: 224_000, hasFile: false),
                track(3016, "16", 16, "16 Ghosts II", duration_ms: 196_000, hasFile: false),
                track(3017, "17", 17, "17 Ghosts II", duration_ms: 209_000, hasFile: false),
                track(3018, "18", 18, "18 Ghosts II", duration_ms: 162_000, hasFile: false),
            ],
            302: [
                track(4001, "1", 1, "Sleeping",         duration_ms: 198_000, hasFile: true),
                track(4002, "2", 2, "Wonder",           duration_ms: 207_000, hasFile: true),
                track(4003, "3", 3, "Out of It",        duration_ms: 184_000, hasFile: true),
                track(4004, "4", 4, "Maps",             duration_ms: 215_000, hasFile: true),
                track(4005, "5", 5, "Holding Pattern",  duration_ms: 226_000, hasFile: true),
                track(4006, "6", 6, "Try",              duration_ms: 233_000, hasFile: true),
                track(4007, "7", 7, "What You Wanted",  duration_ms: 198_000, hasFile: true),
                track(4008, "8", 8, "Out of Reach",     duration_ms: 203_000, hasFile: true),
                track(4009, "9", 9, "Underwater",       duration_ms: 234_000, hasFile: true),
                track(4010, "10", 10, "Dive Light",     duration_ms: 191_000, hasFile: true),
                track(4011, "11", 11, "Surfacing",      duration_ms: 195_000, hasFile: true),
            ],
        ]
    }

    private static func track(
        _ id: Int, _ trackNumber: String, _ absolute: Int,
        _ title: String, duration_ms: Int, hasFile: Bool
    ) -> LidarrTrackDetail {
        LidarrTrackDetail(
            id: id, trackNumber: trackNumber, absoluteTrackNumber: absolute,
            title: title, duration: duration_ms, mediumNumber: 1, hasFile: hasFile
        )
    }

    // MARK: - Search results

    public static func searchResults(for query: String, source: QueueItem.Source) -> [SearchResult] {
        let pool: [SearchResult]
        switch source {
        case .radarr:   pool = radarrSearchPool
        case .sonarr:   pool = sonarrSearchPool
        case .lidarr:   pool = lidarrSearchPool
        case .whisparr: pool = whisparrSearchPool
        }
        guard !query.isEmpty else { return Array(pool.prefix(6)) }
        let q = query.lowercased()
        return pool.filter { result in
            result.title.lowercased().contains(q)
                || (result.overview?.lowercased().contains(q) ?? false)
                || result.genres.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private static var radarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 10003, foreignId: "10003",
                title: "Elephants Dream", subtitle: nil,
                year: 2006,
                rating: 7.0,
                imdb: 6.8, rottenTomatoes: 79, metacritic: 71,
                overview: "Two characters argue about the nature of the strange world they inhabit. Blender's first ever open movie — short, surreal, and a watershed moment for free / open-source CGI in 2006.",
                runtime: 11,
                genres: ["Animation", "Short", "Sci-Fi"],
                network: "Blender Foundation",
                certification: "PG",
                posterURL: poster(label: "Elephants Dream", seed: "elephantsdream", w: 200, h: 300),
                source: .radarr
            ),
            SearchResult(
                id: 10004, foreignId: "10004",
                title: "Spring", subtitle: nil,
                year: 2019,
                rating: 7.8,
                imdb: 7.5, rottenTomatoes: 91, metacritic: 82,
                overview: "A young shepherd girl and her dog encounter ancient creatures during the spring melt. Blender's most painterly open-movie short — every frame deliberately staged like a watercolour.",
                runtime: 8,
                genres: ["Animation", "Family", "Adventure"],
                network: "Blender Foundation",
                certification: "G",
                posterURL: poster(label: "Spring", seed: "spring", w: 200, h: 300),
                source: .radarr
            ),
            SearchResult(
                id: 10005, foreignId: "10005",
                title: "Charge", subtitle: nil,
                year: 2018,
                rating: 7.0,
                imdb: 6.9, rottenTomatoes: nil, metacritic: nil,
                overview: "A short film about a robot who has to choose between his owner and his charging cable. Maker-built, shot on consumer-grade rigs, and released openly. Demo entry for a small indie sci-fi short.",
                runtime: 9,
                genres: ["Sci-Fi", "Short", "Drama"],
                network: nil,
                certification: "PG",
                posterURL: poster(label: "Charge", seed: "charge", w: 200, h: 300),
                source: .radarr
            ),
            SearchResult(
                id: 10006, foreignId: "10006",
                title: "Agent 327: Operation Barbershop", subtitle: nil,
                year: 2017,
                rating: 7.4,
                imdb: 7.2, rottenTomatoes: 88, metacritic: nil,
                overview: "A Dutch comic-book spy walks into a barbershop and out into a slapstick brawl. Blender Animation Studio's pilot for an Agent 327 feature — three minutes of bouncy character animation that doubles as a tech demo for the EEVEE realtime renderer.",
                runtime: 4,
                genres: ["Animation", "Action", "Comedy"],
                network: "Blender Animation Studio",
                certification: "PG",
                posterURL: poster(label: "Agent 327", seed: "agent327", w: 200, h: 300),
                source: .radarr
            ),
            SearchResult(
                id: 10007, foreignId: "10007",
                title: "Hero", subtitle: nil,
                year: 2018,
                rating: 7.2,
                imdb: 7.0, rottenTomatoes: nil, metacritic: nil,
                overview: "Grease-pencil 2D animation about a small dog with a big imagination. Blender's first major showcase of fully integrated 2D-in-3D pipeline work — a love letter to hand-drawn cartoons rendered inside a 3D scene.",
                runtime: 4,
                genres: ["Animation", "Family"],
                network: "Blender Animation Studio",
                certification: "G",
                posterURL: poster(label: "Hero", seed: "hero2018", w: 200, h: 300),
                source: .radarr
            ),
            SearchResult(
                id: 10008, foreignId: "10008",
                title: "Coffee Run", subtitle: nil,
                year: 2020,
                rating: 7.1,
                imdb: 6.9, rottenTomatoes: nil, metacritic: nil,
                overview: "A frantic cup of coffee dashes through a city of frantic adults. Pure stylised motion design, mostly built in grease pencil and used as a stress test for Blender's grease-pencil performance.",
                runtime: 4,
                genres: ["Animation", "Short", "Comedy"],
                network: "Blender Animation Studio",
                certification: "G",
                posterURL: poster(label: "Coffee Run", seed: "coffeerun", w: 200, h: 300),
                source: .radarr
            ),
        ]
    }

    private static var lidarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 30001, foreignId: "b7ffd2af-418f-4be2-bdd1-22f8b48613da",
                title: "Nine Inch Nails",
                subtitle: "Industrial rock",
                year: nil,
                rating: 8.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Trent Reznor's industrial-rock project. Released the four-volume instrumental 'Ghosts I-IV' under Creative Commons in 2008.",
                runtime: nil,
                genres: ["Industrial", "Rock", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "NIN", seed: "ninghosts", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30002, foreignId: "1ce18a52-ca5f-4f34-9bc6-5f2af0d33f5e",
                title: "Brad Sucks",
                subtitle: "One-man band",
                year: nil,
                rating: 7.2,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Ottawa one-man indie pop project. Every album he's released has been free / Creative Commons since 2003.",
                runtime: nil,
                genres: ["Indie", "Pop"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Brad Sucks", seed: "bradsucks", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30003, foreignId: "30c4c46c-2c4e-44a3-b9f2-c0ultonforeignid",
                title: "Jonathan Coulton",
                subtitle: "Geek folk",
                year: nil,
                rating: 7.8,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "American musician known for 'Code Monkey' and 'Still Alive' (Portal). Releases most work under CC-BY-NC.",
                runtime: nil,
                genres: ["Folk", "Comedy", "Indie"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Coulton", seed: "coultonsomeguys", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30004, foreignId: "kevinmacleod-incompetech",
                title: "Kevin MacLeod",
                subtitle: "Royalty-free composer",
                year: nil,
                rating: 7.0,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Prolific incompetech.com composer. Over 2000 royalty-free tracks under CC-BY 4.0 — every YouTube tutorial ever uses his work.",
                runtime: nil,
                genres: ["Soundtrack", "Ambient", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Kevin MacLeod", seed: "kevinmacleod", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30005, foreignId: "tobu-musicbrainz",
                title: "Tobu",
                subtitle: "Electronic / EDM",
                year: nil,
                rating: 7.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Latvian electronic producer who releases under No Copyright Sounds. Heavy presence on YouTube-creator playlists.",
                runtime: nil,
                genres: ["EDM", "Electronic", "House"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Tobu", seed: "tobu", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30006, foreignId: "komiku-fma",
                title: "Komiku",
                subtitle: "Chiptune / 8-bit",
                year: nil,
                rating: 7.1,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "French chiptune composer. Whole catalog on Free Music Archive under CC0 — game devs and podcasters love them.",
                runtime: nil,
                genres: ["Chiptune", "Soundtrack", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Komiku", seed: "komiku", w: 200, h: 200),
                source: .lidarr
            ),
        ]
    }

    private static var whisparrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 40001, foreignId: "40001",
                title: "Kitten Cam: Backyard Drama", subtitle: nil,
                year: 2024,
                rating: 8.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A long-running observational documentary about feline politics in a suburban garden. Episode count varies depending on neighbour cats.",
                runtime: 24,
                genres: ["Documentary", "Comedy"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Kitten Cam", seed: "kitten:neo", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40002, foreignId: "40002",
                title: "The Black Cat Chronicles", subtitle: nil,
                year: 2023,
                rating: 7.8,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Award-winning short film series following the social lives of three sibling cats sharing a Brooklyn apartment.",
                runtime: 18,
                genres: ["Short", "Drama"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Black Cat", seed: "kitten:millie", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40003, foreignId: "40003",
                title: "Nine Lives of Mittens", subtitle: nil,
                year: 2022,
                rating: 7.1,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "An anthology, one short per life. Tenth episode somehow exists.",
                runtime: 22,
                genres: ["Anthology", "Drama"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Mittens", seed: "kitten:poppy", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40004, foreignId: "40004",
                title: "Whiskers & Whispers", subtitle: nil,
                year: 2024,
                rating: 6.9,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "ASMR podcast hosted by three cats. Episodes are mostly purring with occasional commentary on the texture of cardboard boxes.",
                runtime: 32,
                genres: ["Podcast", "Lifestyle"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Whiskers", seed: "kitten:bella", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40005, foreignId: "40005",
                title: "Cat Burglar", subtitle: nil,
                year: 2021,
                rating: 7.3,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Mockumentary about a tabby who keeps stealing tools from the neighbour's workshop. Three seasons, no leads.",
                runtime: 26,
                genres: ["Mockumentary", "Crime", "Comedy"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Cat Burglar", seed: "kitten:g", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40006, foreignId: "40006",
                title: "Garage Cat Files", subtitle: nil,
                year: 2024,
                rating: 7.6,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Industrial-cinema treatment of a stray that adopted a mechanic's garage. Lots of slow pans and one bench grinder.",
                runtime: 41,
                genres: ["Documentary", "Drama"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Garage Cat", seed: "kitten:mu", w: 200, h: 300),
                source: .whisparr
            ),
        ]
    }

    private static var sonarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 20001, foreignId: "20001",
                title: "Pioneer One", subtitle: "1 season",
                year: 2010,
                rating: 7.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "BitTorrent-funded sci-fi thriller about a Soviet capsule that re-enters the atmosphere over Montana. Each episode was paid for by viewer donations after the previous one shipped.",
                runtime: 35,
                genres: ["Drama", "Mystery", "Sci-Fi"],
                network: "VODO",
                certification: nil,
                posterURL: poster(label: "Pioneer One", seed: "pioneerone", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20002, foreignId: "20002",
                title: "Caminandes", subtitle: "1 season",
                year: 2013,
                rating: 7.6,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A llama, a fence, and a steady supply of bad ideas. Blender Foundation's silent slapstick anthology.",
                runtime: 5,
                genres: ["Animation", "Comedy", "Family"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Caminandes", seed: "caminandes", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20003, foreignId: "20003",
                title: "Northern Cascade", subtitle: "2 seasons",
                year: 2023,
                rating: 8.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A team of glaciologists, climbers, and a reluctant journalist disappear in the Cascade range. Each season unwinds the timeline differently — what they took with them, what they left behind, and what was already there before they arrived.",
                runtime: 52,
                genres: ["Drama", "Mystery", "Thriller"],
                network: "Demo Streaming",
                certification: nil,
                posterURL: poster(label: "Northern Cascade", seed: "northerncascade", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20004, foreignId: "20004",
                title: "Spring Tales", subtitle: "1 season",
                year: 2019,
                rating: 8.0,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Animated anthology of folklore from the perspective of small things. Pollen-cam.",
                runtime: 22,
                genres: ["Animation", "Family", "Drama"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Spring Tales", seed: "spring", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20005, foreignId: "20005",
                title: "Cosmos Laundromat", subtitle: "Pilot",
                year: 2015,
                rating: 7.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A multiversal salesman makes a pitch to a suicidal sheep. Open-movie pilot.",
                runtime: 12,
                genres: ["Animation", "Drama", "Fantasy"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Cosmos Laundromat", seed: "cosmoslaundromat", w: 200, h: 300),
                source: .sonarr
            ),
        ]
    }
}
