import Foundation

/// A status-first, *raw* view of the app's current state, built on the main
/// actor from the live `QueueViewModel` and handed to the (off-main) start-page
/// HTTP host.
///
/// Deliberately holds **normalized data, not presentation**: byte counts as
/// `Int64`, air dates as `Date`, statuses/sources as their raw enums. All
/// English formatting happens later, once, in `StartPageRenderer` (the display
/// layer). Keeping formatting out of the model is what stops the OS locale from
/// leaking into the page, and it makes `/status.json` a clean machine-readable
/// API (raw ints + ISO dates) rather than pre-baked "1.48 GB left" strings.
public struct StartPageSnapshot: Sendable, Codable {
    /// At-a-glance download tallies — the "main dish" for download activity on a
    /// status page, in place of a full row-by-row list.
    public struct Stats: Sendable, Codable {
        public let downloading: Int
        public let queued: Int
        public let paused: Int
        public let importing: Int
        /// Every queue row across all arrs.
        public let total: Int
        /// Bytes still to fetch across active (downloading/queued) rows.
        public let bytesLeft: Int64

        public init(downloading: Int, queued: Int, paused: Int, importing: Int,
                    total: Int, bytesLeft: Int64) {
            self.downloading = downloading; self.queued = queued; self.paused = paused
            self.importing = importing; self.total = total; self.bytesLeft = bytesLeft
        }
    }

    public struct Download: Sendable, Codable {
        public let title: String
        public let subtitle: String?
        public let source: QueueItem.Source
        public let status: QueueItem.Status
        /// 0…1.
        public let progress: Double
        /// Bytes still to fetch (raw — renderer formats).
        public let bytesLeft: Int64
        /// Total download size (raw). 0 when the arr didn't report it.
        public let sizeTotal: Int64
        /// Arr-provided, culture-neutral "HH:MM:SS" — passed through as-is.
        public let timeLeft: String?
        public let quality: String?
        public let downloadProtocol: QueueItem.DownloadProtocol
        public let indexer: String?
        public let downloadClient: String?
        public let releaseName: String?
        public let customFormats: [String]
        public let customFormatScore: Int
        /// True when this grab replaces an existing (lower-scoring) file.
        public let isUpgrade: Bool
        // The file being replaced, for the upgrade "old → new" comparison.
        public let existingQuality: String?
        public let existingSize: Int64?
        public let existingCustomFormats: [String]
        public let existingCustomFormatScore: Int?
        public let existingFileName: String?
        public let posterURL: URL?

        public init(title: String, subtitle: String?, source: QueueItem.Source,
                    status: QueueItem.Status, progress: Double, bytesLeft: Int64,
                    sizeTotal: Int64, timeLeft: String?, quality: String?,
                    downloadProtocol: QueueItem.DownloadProtocol, indexer: String?,
                    downloadClient: String?, releaseName: String?, customFormats: [String],
                    customFormatScore: Int, isUpgrade: Bool, existingQuality: String?,
                    existingSize: Int64?, existingCustomFormats: [String],
                    existingCustomFormatScore: Int?, existingFileName: String?, posterURL: URL?) {
            self.title = title; self.subtitle = subtitle; self.source = source
            self.status = status; self.progress = progress; self.bytesLeft = bytesLeft
            self.sizeTotal = sizeTotal; self.timeLeft = timeLeft; self.quality = quality
            self.downloadProtocol = downloadProtocol; self.indexer = indexer
            self.downloadClient = downloadClient; self.releaseName = releaseName
            self.customFormats = customFormats; self.customFormatScore = customFormatScore
            self.isUpgrade = isUpgrade; self.existingQuality = existingQuality
            self.existingSize = existingSize; self.existingCustomFormats = existingCustomFormats
            self.existingCustomFormatScore = existingCustomFormatScore
            self.existingFileName = existingFileName; self.posterURL = posterURL
        }
    }

    /// One configured service (arr, download client, or AI) with its live
    /// connection health — the "is my homelab OK?" glance, mirrored from
    /// Settings → Status.
    public struct Service: Sendable, Codable {
        public enum Health: String, Sendable, Codable { case ok, down, unknown }
        public let name: String
        public let health: Health
        /// Version string when up, error message when down.
        public let detail: String?
        /// Actionable arr `/health` warnings + errors (0 for non-arr services).
        public let warnings: Int
        /// The service's web UI base URL, so the chip can link to it. nil for
        /// services without a browsable UI (e.g. TMDB).
        public let url: String?
        /// Brand-icon asset name (`ServiceIcons.xcassets`), or nil for a plain dot.
        public let iconName: String?

        public init(name: String, health: Health, detail: String?, warnings: Int,
                    url: String?, iconName: String?) {
            self.name = name; self.health = health; self.detail = detail
            self.warnings = warnings; self.url = url; self.iconName = iconName
        }
    }

    public struct Upcoming: Sendable, Codable {
        public let title: String
        public let subtitle: String?
        public let source: QueueItem.Source
        /// Raw air date — renderer turns it into "Today"/"Tomorrow"/"Jul 30".
        public let airDate: Date
        /// Synopsis for the hover popover.
        public let overview: String?
        /// IMDb rating (same units as the app's poster metadata row).
        public let imdb: Double?
        /// Runtime in minutes.
        public let runtime: Int?
        public let posterURL: URL?

        public init(title: String, subtitle: String?, source: QueueItem.Source,
                    airDate: Date, overview: String?, imdb: Double?, runtime: Int?,
                    posterURL: URL?) {
            self.title = title; self.subtitle = subtitle; self.source = source
            self.airDate = airDate; self.overview = overview; self.imdb = imdb
            self.runtime = runtime; self.posterURL = posterURL
        }
    }

    public let generatedAt: Date
    /// True when every configured arr is unreachable (away from the home LAN).
    public let offline: Bool
    /// Per-arr error summaries, already prefixed with the source name.
    public let errors: [String]
    /// Configured services and their live connection health.
    public let services: [Service]
    public let stats: Stats
    /// A short list of the currently-active downloads for the compact strip —
    /// NOT the full queue. `stats` carries the totals.
    public let downloads: [Download]
    /// Capped at the display limit; `upcomingTotal` is the true count so the
    /// renderer can show a "+N more" tail.
    public let upcoming: [Upcoming]
    public let upcomingTotal: Int
    /// The running app's icon as a `data:` URI, for the header. nil → wordmark.
    public let appIcon: String?

    public init(generatedAt: Date, offline: Bool, errors: [String], services: [Service],
                stats: Stats, downloads: [Download], upcoming: [Upcoming], upcomingTotal: Int,
                appIcon: String? = nil) {
        self.generatedAt = generatedAt; self.offline = offline; self.errors = errors
        self.services = services; self.stats = stats; self.downloads = downloads
        self.upcoming = upcoming; self.upcomingTotal = upcomingTotal; self.appIcon = appIcon
    }

    /// Empty placeholder — served before the first successful refresh.
    public static let empty = StartPageSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0), offline: false, errors: [], services: [],
        stats: Stats(downloading: 0, queued: 0, paused: 0, importing: 0, total: 0, bytesLeft: 0),
        downloads: [], upcoming: [], upcomingTotal: 0)
}

// MARK: - Building from live state

public extension StartPageSnapshot {
    /// Active downloads shown in the compact strip. A status page is a glance —
    /// the tallies live in `stats`, so the strip only needs the top few.
    private static let downloadStripLimit = 4
    /// Upcoming poster cards in the horizontal shelf before the "+N more" tail
    /// kicks in. The shelf scrolls, so this can be generous — it never wraps.
    private static let upcomingLimit = 12

    /// Build the snapshot from the live `QueueViewModel`. Main-actor isolated
    /// because that's where the queue lives; the returned value is `Sendable`.
    @MainActor
    static func current(queue: QueueViewModel, appIcon: String? = nil) -> StartPageSnapshot {
        let all = queue.queues.flatMap { $0.value }

        func count(_ status: QueueItem.Status) -> Int { all.filter { $0.status == status }.count }
        let bytesLeft = all
            .filter { $0.status == .downloading || $0.status == .queued }
            .reduce(Int64(0)) { $0 + max(0, $1.sizeLeft) }
        let stats = Stats(
            downloading: count(.downloading), queued: count(.queued),
            paused: count(.paused), importing: count(.importing),
            total: all.count, bytesLeft: bytesLeft)

        let downloads = all
            .sorted(by: downloadOrder)
            .prefix(downloadStripLimit)
            .map(makeDownload)

        let upcoming = queue.upcoming
            .sorted { $0.airDate < $1.airDate }
            .prefix(upcomingLimit)
            .map(makeUpcoming)

        let errors = QueueItem.Source.allCases.compactMap { source -> String? in
            guard let message = queue.error(for: source), !message.isEmpty else { return nil }
            return "\(source.displayName): \(message)"
        }

        return StartPageSnapshot(
            generatedAt: Date(), offline: queue.isFullyOffline, errors: errors,
            services: services(queue: queue), stats: stats,
            downloads: Array(downloads), upcoming: Array(upcoming),
            upcomingTotal: queue.upcoming.count, appIcon: appIcon)
    }

    /// Every configured service with its live connection health — the same roll-up
    /// Settings → Status shows, read from the shared `ConnectionHealth` singleton.
    @MainActor
    private static func services(queue: QueueViewModel) -> [Service] {
        // Demo has no real base URLs, so the roster would be empty. Synthesize one
        // (healthy + a warning + one down) so the feature — and its web-UI links —
        // is visible out of the box, the same way demo turns the AI chat on.
        if DemoMode.isActive { return demoServices }
        return MonitoredService.allCases
            .filter { $0.isConfigured(in: .shared) }
            .map { service in
                let (health, detail): (Service.Health, String?)
                switch ConnectionHealth.shared.state(for: service) {
                case .ok(let d):      (health, detail) = (.ok, d)
                case .down(let m):    (health, detail) = (.down, m)
                case .unknown:        (health, detail) = (.unknown, nil)
                }
                let kind = service.serviceKind
                let warnings: Int
                if let kind,
                   let source = QueueItem.Source.allCases.first(where: { $0.serviceKind == kind }) {
                    warnings = queue.health.records(for: source).filter { isActionable($0.type) }.count
                } else {
                    warnings = 0
                }
                // Link to the service's own web UI (its configured base URL).
                let base = kind.map { ConfigStore.shared.config(for: $0).baseURL } ?? ""
                return Service(name: service.displayName, health: health, detail: detail,
                               warnings: warnings, url: base.isEmpty ? nil : base,
                               iconName: kind?.brandIconName)
            }
    }

    private static func isActionable(_ type: String?) -> Bool {
        switch type?.lowercased() {
        case "warning", "error": return true
        default: return false
        }
    }

    /// Demo-only server roster — ports are the arrs' real defaults, so the links
    /// even tend to work on a homelab box.
    private static let demoServices: [Service] = [
        Service(name: "Radarr", health: .ok, detail: "5.14.0", warnings: 0, url: "http://localhost:7878", iconName: "radarr"),
        Service(name: "Sonarr", health: .ok, detail: "4.0.10", warnings: 1, url: "http://localhost:8989", iconName: "sonarr"),
        Service(name: "Lidarr", health: .ok, detail: "2.6.4", warnings: 0, url: "http://localhost:8686", iconName: "lidarr"),
        Service(name: "qBittorrent", health: .ok, detail: "4.6.5", warnings: 0, url: "http://localhost:8080", iconName: "qbittorrent"),
        Service(name: "SABnzbd", health: .down, detail: "Connection refused", warnings: 0, url: "http://localhost:8081", iconName: "sabnzbd"),
    ]

    /// Active work first (downloading/importing), then most-complete first.
    private static func downloadOrder(_ a: QueueItem, _ b: QueueItem) -> Bool {
        func rank(_ s: QueueItem.Status) -> Int {
            switch s {
            case .downloading, .importing: return 0
            case .queued, .warning:        return 1
            case .paused:                  return 2
            case .completed, .failed, .unknown: return 3
            }
        }
        let (ra, rb) = (rank(a.status), rank(b.status))
        if ra != rb { return ra < rb }
        if a.progress != b.progress { return a.progress > b.progress }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    private static func makeDownload(_ item: QueueItem) -> Download {
        Download(
            title: item.title, subtitle: item.subtitle, source: item.source,
            status: item.status, progress: max(0, min(1, item.progress)),
            bytesLeft: max(0, item.sizeLeft), sizeTotal: max(0, item.sizeTotal),
            timeLeft: item.timeLeft, quality: item.quality,
            downloadProtocol: item.downloadProtocol, indexer: item.indexer,
            downloadClient: item.downloadClient, releaseName: item.releaseName,
            customFormats: item.customFormats, customFormatScore: item.customFormatScore,
            isUpgrade: item.isUpgrade, existingQuality: item.existingQuality,
            existingSize: item.existingSize, existingCustomFormats: item.existingCustomFormats,
            existingCustomFormatScore: item.existingCustomFormatScore,
            existingFileName: item.existingFileName, posterURL: item.posterURL)
    }

    private static func makeUpcoming(_ item: UpcomingItem) -> Upcoming {
        Upcoming(title: item.title, subtitle: item.subtitle, source: item.source,
                 airDate: item.airDate, overview: item.overview, imdb: item.imdb,
                 runtime: item.runtime, posterURL: item.posterURL)
    }
}
