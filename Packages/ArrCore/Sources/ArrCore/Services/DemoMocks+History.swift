import Foundation

// Per-source history fixtures (curated entities only; grabbed/imported with CF
// scores and upgrade replacements, no failures).

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

    static var radarrHistory: [HistoryItem] {
        [
            historyItem(.radarr, id: "rh1", minutesAgo: 12, event: .grabbed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "Remux Tier 01"], score: 1850),
            historyItem(.radarr, id: "rh2", minutesAgo: 95, event: .imported,
                        title: "Tears of Steel (2012)",
                        subtitle: "Upgrade — Bluray-2160p",
                        sourceTitle: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "x265"], score: 1720),
            historyItem(.radarr, id: "rh3", minutesAgo: 240, event: .imported,
                        title: "Sintel (2010)",
                        subtitle: "Upgrade — WEB-DL 1080p",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "AV1"], score: 720),
        ]
    }

    /// Per-episode rows of one imported Caminandes season pack — the view
    /// model folds them into a single "Season 1 · N episodes" history row.
    private static var sonarrSeasonPackImports: [HistoryItem] {
        let episodes = ["E01 · Llama Drama", "E02 · Gran Dillama", "E03 · Llamigos"]
        let hint = HistoryItem.GroupHint(
            key: "demo-caminandes-s01|s1",
            collapsedSubtitle: String(format: String(localized: "detail.seasonLld.label", bundle: .module), 1)
        )
        return episodes.enumerated().map { idx, title in
            historyItem(.sonarr, id: "sh-pack-\(idx)", minutesAgo: 180 + idx, event: .imported,
                        title: "Caminandes (2013)",
                        subtitle: "S01\(title)",
                        sourceTitle: "Caminandes.S01.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264"], score: 640,
                        hint: hint)
        }
    }

    static var sonarrHistory: [HistoryItem] {
        [
            historyItem(.sonarr, id: "sh1", minutesAgo: 5, event: .grabbed,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E03 · Endurance",
                        sourceTitle: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264", "HQ Source Group"], score: 380),
            historyItem(.sonarr, id: "sh2", minutesAgo: 60, event: .imported,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 180),
        ] + sonarrSeasonPackImports + [
            historyItem(.sonarr, id: "sh3", minutesAgo: 320, event: .imported,
                        title: "Caminandes (2013)",
                        subtitle: "S01E01 · Llama Drama",
                        sourceTitle: "Caminandes.S01E01.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264", "HQ Source Group"], score: 720),
        ]
    }

    static var lidarrHistory: [HistoryItem] {
        [
            historyItem(.lidarr, id: "lh1", minutesAgo: 30, event: .grabbed,
                        title: "Nine Inch Nails",
                        subtitle: "Ghosts I-IV · Upgrade — FLAC",
                        sourceTitle: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                        quality: "FLAC", formats: ["Lossless", "24bit"], score: 320),
        ] + bradSucksAlbumImports
    }

    /// Per-track rows of one imported album — folded into a single
    /// "Out of It · N tracks" history row by the view model.
    private static var bradSucksAlbumImports: [HistoryItem] {
        let hint = HistoryItem.GroupHint(key: "demo-brad-sucks-out-of-it|album-1")
        return (0..<11).map { idx in
            historyItem(.lidarr, id: "lh-track-\(idx)", minutesAgo: 600 + idx, event: .imported,
                        title: "Brad Sucks",
                        subtitle: "Out of It",
                        sourceTitle: "Brad.Sucks-Out.of.It-MP3-DEMO",
                        quality: "MP3-320", formats: [], score: 0,
                        hint: hint)
        }
    }

    static var whisparrHistory: [HistoryItem] {
        [
            historyItem(.whisparr, id: "wh1", minutesAgo: 360, event: .imported,
                        title: "The Black Cat Chronicles (2023)",
                        subtitle: "Upgrade — WEB-DL 2160p HDR",
                        sourceTitle: "The.Black.Cat.Chronicles.2023.2160p.WEB-DL.HDR-DEMO",
                        quality: "WEB-DL 2160p", formats: ["HDR10", "AV1"], score: 690),
            historyItem(.whisparr, id: "wh2", minutesAgo: 840, event: .grabbed,
                        title: "Kitten Cam: Backyard Drama (2024)",
                        sourceTitle: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["x264"], score: 280),
        ]
    }
}
