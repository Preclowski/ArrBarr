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
    static let realPosters: [String: String] = [
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

    static func poster(label: String, seed: String, w: Int = 200, h: Int = 300) -> URL? {
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

    // MARK: - Builders

    enum Aspect { case portrait, square }

    struct ExistingFile {
        let quality: String?
        let formats: [String]
        let score: Int
        let size: Int64
        let fileName: String
    }

    static func queueItem(
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
        entityId: Int? = nil,
        statusMessages: [String] = []
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
            posterRequiresAuth: false,
            statusMessages: statusMessages
        )
    }

    static func posterLabel(title: String, subtitle: String?) -> String {
        if let sub = subtitle, let ep = sub.split(separator: "·").first?.trimmingCharacters(in: .whitespaces) {
            return "\(title)\n\(ep)"
        }
        return title
    }

    static func upcomingItem(
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

    static func historyItem(
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
