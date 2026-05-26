import Foundation

// Per-source history fixtures plus the public lookup.

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

    static var sonarrHistory: [HistoryItem] {
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

    static var lidarrHistory: [HistoryItem] {
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

    static var whisparrHistory: [HistoryItem] {
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

}
