import Foundation
import os
import UserNotifications

nonisolated public extension QueueItem.Source {
    var serviceKind: ServiceKind {
        switch self {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        case .whisparr: return .whisparr
        }
    }
}

/// A one-shot timer that has been handed to a `CoalescerScheduler`.
struct ScheduledTimer {
    let cancel: @MainActor () -> Void
}

/// The clock `NotificationCoalescer` schedules against, so tests can drive the
/// grouping policy on a virtual clock instead of racing the run loop.
protocol CoalescerScheduler {
    /// Must share a timeline with `schedule`, or the cap drifts from the timers.
    var now: Date { get }

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping @MainActor @Sendable () -> Void
    ) -> ScheduledTimer
}

/// `.common` run loop mode so timers still fire while the menu-bar panel tracks events.
struct RunLoopCoalescerScheduler: CoalescerScheduler {
    /// `nonisolated` so it can be a default argument, which Swift evaluates
    /// outside the actor; there's no stored state to isolate.
    nonisolated init() {}

    var now: Date { Date() }

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping @MainActor @Sendable () -> Void
    ) -> ScheduledTimer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return ScheduledTimer { timer.invalidate() }
    }
}

/// Groups queue-event notifications. Movies/music fire the first grab at once and
/// batch the tail; series hold the first grab so a season search's per-episode grabs join it.
public final class NotificationCoalescer {
    nonisolated private static let log = Logger(category: "Notifications")
    /// Multi-item batches: only "Open in browser", since one tap can't
    /// meaningfully pause/remove a batch.
    public static let categoryIdentifier = "ARRBARR_QUEUE_EVENT"
    /// Single-item categories, so the action matches the item's current state.
    public static let downloadingCategoryIdentifier = "ARRBARR_QUEUE_DOWNLOADING"
    public static let pausedCategoryIdentifier = "ARRBARR_QUEUE_PAUSED"

    public static let openActionIdentifier = "ARRBARR_OPEN"
    public static let pauseActionIdentifier = "ARRBARR_PAUSE"
    public static let resumeActionIdentifier = "ARRBARR_RESUME"
    public static let removeActionIdentifier = "ARRBARR_REMOVE"

    public static let userInfoBaseURLKey = "arrBaseURL"
    public static let userInfoSourceKey = "arrSource"
    public static let userInfoQueueIdKey = "arrQueueId"

    /// Short: it only collapses a burst's tail, not the headline banner.
    private let burstWindow: TimeInterval

    /// Sonarr grabs a season one release per episode, seconds apart; 5 s lets
    /// siblings join (each slides the window) while the banner still reads as "just now".
    private let seriesGroupingDelay: TimeInterval
    /// Caps how long the sliding window can defer delivery.
    private let seriesGroupingCap: TimeInterval

    /// `nil` ⇒ the real `UNUserNotificationCenter` banner; tests substitute a recorder.
    private let deliver: (@MainActor (QueueItem.Source, [QueueItem]) -> Void)?

    private let configStore: ConfigStore
    private let scheduler: any CoalescerScheduler
    /// Episodic sources hold the whole group; leading-edge sources hold only
    /// the tail, the first grab having already been posted.
    private var pending: [QueueItem.Source: [QueueItem]] = [:]
    private var burstTimers: [QueueItem.Source: ScheduledTimer] = [:]
    private var groupStartedAt: [QueueItem.Source: Date] = [:]

    /// `nil` ⇒ post the first grab immediately and batch the tail.
    private func groupingDelay(for source: QueueItem.Source) -> TimeInterval? {
        switch source {
        case .sonarr, .whisparr: return seriesGroupingDelay
        case .radarr, .lidarr:   return nil
        }
    }

    init(
        configStore: ConfigStore,
        burstWindow: TimeInterval = 8,
        seriesGroupingDelay: TimeInterval = 5,
        seriesGroupingCap: TimeInterval = 60,
        scheduler: any CoalescerScheduler = RunLoopCoalescerScheduler(),
        deliver: (@MainActor (QueueItem.Source, [QueueItem]) -> Void)? = nil
    ) {
        self.configStore = configStore
        self.burstWindow = burstWindow
        self.seriesGroupingDelay = seriesGroupingDelay
        self.seriesGroupingCap = seriesGroupingCap
        self.scheduler = scheduler
        self.deliver = deliver
    }

    private func emit(source: QueueItem.Source, items: [QueueItem]) {
        if let deliver {
            deliver(source, items)
        } else {
            post(source: source, items: items)
        }
    }

    func enqueue(_ item: QueueItem) {
        let source = item.source
        // Prefetch now: for an episodic arr that's a whole window before `post`
        // asks for the artwork.
        NotificationArtwork.prefetch(item, apiKey: posterAPIKey(for: item))

        guard let delay = groupingDelay(for: source) else {
            if burstTimers[source] == nil {
                emit(source: source, items: [item])
                startBurstTimer(for: source, after: burstWindow)
            } else {
                pending[source, default: []].append(item)
            }
            return
        }

        pending[source, default: []].append(item)
        let startedAt = groupStartedAt[source] ?? scheduler.now
        groupStartedAt[source] = startedAt
        let elapsed = scheduler.now.timeIntervalSince(startedAt)
        let remainingCap = max(0, seriesGroupingCap - elapsed)
        startBurstTimer(for: source, after: min(delay, remainingCap))
    }

    /// Sample banners for the Settings test button. Staggered ~1.2s so macOS
    /// shows each rather than collapsing them into one grouped banner.
    func postTest() {
        let stages: [(QueueItem.Source, [QueueItem])] = [
            (.sonarr, [Self.sampleNewGrabSonarr()]),
            (.radarr, [Self.sampleUpgradeRadarr()]),
            (.lidarr, [Self.samplePausedLidarr()]),
            (.sonarr, [Self.sampleFailedSonarr()]),
            (.sonarr, Self.sampleSeasonBatchSonarr()),
            (.radarr, Self.sampleBatchRadarr()),
        ]
        Task { @MainActor [weak self] in
            for (source, items) in stages {
                self?.post(source: source, items: items)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    // MARK: - Sample items for the test button

    private static func sampleNewGrabSonarr() -> QueueItem {
        QueueItem(
            id: "arrbarr.test.\(UUID().uuidString)",
            source: .sonarr, arrQueueId: -1,
            downloadId: nil, downloadProtocol: .torrent,
            downloadClient: "qBittorrent", indexer: "Test Tracker",
            title: "Pioneer One (2010)", subtitle: "S01E03 · Endurance",
            seasonNumber: 1, episodeNumber: 3, episodeTitle: "Endurance",
            releaseName: "Pioneer.One.S01E03.720p.HDTV.x264-TEST",
            status: .downloading, progress: 0.42,
            sizeTotal: 1_200_000_000, sizeLeft: 700_000_000, timeLeft: nil,
            customFormats: ["x264", "AAC 2.0", "Internal"], customFormatScore: 380,
            quality: "HDTV-720p", isUpgrade: false,
            contentSlug: "pioneer-one"
        )
    }

    private static func sampleUpgradeRadarr() -> QueueItem {
        QueueItem(
            id: "arrbarr.test.\(UUID().uuidString)",
            source: .radarr, arrQueueId: -2,
            downloadId: nil, downloadProtocol: .usenet,
            downloadClient: "SABnzbd", indexer: "Test Usenet",
            title: "Sintel (2010)", subtitle: nil,
            releaseName: "Sintel.2010.1080p.WEB-DL.AV1-TEST",
            status: .downloading, progress: 0.42,
            sizeTotal: 4_500_000_000, sizeLeft: 2_700_000_000, timeLeft: nil,
            customFormats: ["AMZN", "Atmos", "DDP 5.1", "x264"], customFormatScore: 720,
            quality: "WEB-DL 1080p", isUpgrade: true,
            existingCustomFormats: ["x264", "AAC 2.0"], existingCustomFormatScore: 60,
            existingQuality: "HDTV-720p",
            contentSlug: "sintel"
        )
    }

    private static func samplePausedLidarr() -> QueueItem {
        QueueItem(
            id: "arrbarr.test.\(UUID().uuidString)",
            source: .lidarr, arrQueueId: -3,
            downloadId: nil, downloadProtocol: .torrent,
            downloadClient: "qBittorrent", indexer: "Test Tracker",
            title: "Nine Inch Nails — Ghosts I-IV", subtitle: nil,
            releaseName: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-TEST",
            status: .paused, progress: 0.0,
            sizeTotal: 220_000_000, sizeLeft: 220_000_000, timeLeft: nil,
            customFormats: ["Lossless", "24bit", "Original Source"], customFormatScore: 320,
            quality: "FLAC", isUpgrade: false,
            contentSlug: "ghosts-i-iv"
        )
    }

    private static func sampleFailedSonarr() -> QueueItem {
        QueueItem(
            id: "arrbarr.test.\(UUID().uuidString)",
            source: .sonarr, arrQueueId: -4,
            downloadId: nil, downloadProtocol: .torrent,
            downloadClient: "qBittorrent", indexer: "Test Tracker",
            title: "Northern Cascade (2019)", subtitle: "S02E04 · Cold Start",
            seasonNumber: 2, episodeNumber: 4, episodeTitle: "Cold Start",
            releaseName: "Northern.Cascade.S02E04.2160p.WEB-DL.DV.HDR10-TEST",
            status: .failed, progress: 0.92,
            sizeTotal: 28_000_000_000, sizeLeft: 0, timeLeft: nil,
            customFormats: ["DV", "HDR10", "Atmos", "x265"], customFormatScore: 1240,
            quality: "WEB-DL 2160p", isUpgrade: false,
            contentSlug: "northern-cascade"
        )
    }

    private static func sampleSeasonBatchSonarr() -> [QueueItem] {
        (1...3).map { episode in
            QueueItem(
                id: "arrbarr.test.\(UUID().uuidString)",
                source: .sonarr, arrQueueId: -(20 + episode),
                downloadId: nil, downloadProtocol: .usenet,
                downloadClient: "SABnzbd", indexer: "Test Usenet",
                title: "Pioneer One (2010)", subtitle: String(format: "S02E%02d", episode),
                seasonNumber: 2, episodeNumber: episode,
                releaseName: String(format: "Pioneer.One.S02E%02d.1080p.WEB-DL-TEST", episode),
                status: .downloading, progress: 0.05,
                sizeTotal: 2_100_000_000, sizeLeft: 2_000_000_000, timeLeft: nil,
                customFormats: ["AMZN", "x264"], customFormatScore: 240,
                quality: "WEB-DL 1080p", isUpgrade: false,
                contentSlug: "pioneer-one"
            )
        }
    }

    private static func sampleBatchRadarr() -> [QueueItem] {
        [
            QueueItem(
                id: "arrbarr.test.\(UUID().uuidString)",
                source: .radarr, arrQueueId: -5,
                downloadId: nil, downloadProtocol: .usenet,
                downloadClient: "SABnzbd", indexer: "Test Usenet",
                title: "Big Buck Bunny (2008)", subtitle: nil,
                releaseName: "Big.Buck.Bunny.2008.2160p.BluRay-TEST",
                status: .downloading, progress: 0.10,
                sizeTotal: 22_000_000_000, sizeLeft: 19_800_000_000, timeLeft: nil,
                customFormats: ["HDR10+", "Atmos"], customFormatScore: 1850,
                quality: "Bluray-2160p", isUpgrade: false,
                contentSlug: "big-buck-bunny"
            ),
            QueueItem(
                id: "arrbarr.test.\(UUID().uuidString)",
                source: .radarr, arrQueueId: -6,
                downloadId: nil, downloadProtocol: .torrent,
                downloadClient: "qBittorrent", indexer: "Test Tracker",
                title: "Tears of Steel (2012)", subtitle: nil,
                releaseName: "Tears.of.Steel.2012.720p.WEB-DL-TEST",
                status: .queued, progress: 0,
                sizeTotal: 1_400_000_000, sizeLeft: 1_400_000_000, timeLeft: nil,
                customFormats: ["x264"], customFormatScore: 60,
                quality: "WEB-DL 720p", isUpgrade: false,
                contentSlug: "tears-of-steel"
            ),
            QueueItem(
                id: "arrbarr.test.\(UUID().uuidString)",
                source: .radarr, arrQueueId: -7,
                downloadId: nil, downloadProtocol: .torrent,
                downloadClient: "qBittorrent", indexer: "Test Tracker",
                title: "Charge (2018)", subtitle: nil,
                releaseName: "Charge.2018.1080p.WEB-DL-TEST",
                status: .downloading, progress: 0.05,
                sizeTotal: 3_800_000_000, sizeLeft: 3_600_000_000, timeLeft: nil,
                customFormats: ["AMZN", "x264"], customFormatScore: 240,
                quality: "WEB-DL 1080p", isUpgrade: false,
                contentSlug: "charge"
            ),
        ]
    }

    private func startBurstTimer(for source: QueueItem.Source, after delay: TimeInterval) {
        burstTimers[source]?.cancel()
        burstTimers[source] = scheduler.schedule(after: delay) { [weak self] in
            self?.flush(source)
        }
    }

    /// Empty means a leading-edge source whose first grab was the whole burst.
    private func flush(_ source: QueueItem.Source) {
        burstTimers[source]?.cancel()
        burstTimers[source] = nil
        groupStartedAt[source] = nil
        let items = pending[source] ?? []
        pending[source] = nil
        guard !items.isEmpty else { return }
        emit(source: source, items: items)
    }

    /// Not coalesced: health errors are rare and each names a different fix. The
    /// identifier comes from the message so a repeat replaces rather than stacks.
    func postHealthIssue(source: QueueItem.Source, message: String) {
        let content = UNMutableNotificationContent()
        // The one notification about the arr rather than a title, so its name stays.
        content.title = source.displayName
        content.body = message
        content.sound = configuredSound
        content.relevanceScore = Self.relevance(for: .failed)
        if let art = NotificationArtwork.attachment(for: source) {
            content.attachments = [art]
        }
        let digest = String(message.hashValue, radix: 16)
        let req = UNNotificationRequest(
            identifier: "arrbarr.health.\(source.rawValue).\(digest)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Async only because the artwork may still be downloading;
    /// `NotificationArtwork.attachment` bounds that wait.
    private func post(source: QueueItem.Source, items: [QueueItem]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cfg = self.configStore.config(for: source.serviceKind)
            let baseURL = cfg.baseURL

            let content: UNMutableNotificationContent
            let identifier: String
            if items.count == 1 {
                let item = items[0]
                content = await self.makeSingleItemContent(item: item, baseURL: baseURL)
                identifier = "arrbarr.\(source.rawValue).\(item.id)"
            } else {
                content = await self.makeMultiItemContent(
                    source: source, items: items, baseURL: baseURL)
                identifier = "arrbarr.\(source.rawValue).\(UUID().uuidString)"
            }

            let req = UNNotificationRequest(
                identifier: identifier, content: content, trigger: nil)
            _ = await Self.log.attempt("posting a notification", level: .error) { try await UNUserNotificationCenter.current().add(req) }
        }
    }

    /// Only for artwork the arr itself serves: a key on a TMDB/TheTVDB URL would
    /// change the cache key for a poster the app already holds.
    private func posterAPIKey(for item: QueueItem) -> String? {
        guard item.posterRequiresAuth else { return nil }
        return configStore.config(for: item.source).apiKey
    }

    /// `""` → system default, `silentSoundName` → no sound. macOS resolves bare
    /// names against `/System/Library/Sounds` when suffixed with `.aiff`.
    private var configuredSound: UNNotificationSound? {
        let name = configStore.notificationSoundName
        switch name {
        case "": return .default
        case ConfigStore.silentSoundName: return nil
        default: return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }

    // MARK: - Content builders

    private func makeSingleItemContent(
        item: QueueItem, baseURL: String
    ) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = Self.subtitleText(for: item)
        content.body = Self.bodyText(for: item)
        content.sound = configuredSound
        content.categoryIdentifier = item.isPaused
            ? Self.pausedCategoryIdentifier
            : Self.downloadingCategoryIdentifier
        content.threadIdentifier = "arrbarr.\(item.source.rawValue)"
        content.relevanceScore = Self.relevance(for: item.status)
        if let art = await NotificationArtwork.attachment(
            for: item, apiKey: posterAPIKey(for: item)) {
            content.attachments = [art]
        }

        if !baseURL.isEmpty {
            content.userInfo[Self.userInfoBaseURLKey] = baseURL
        }
        content.userInfo[Self.userInfoSourceKey] = item.source.rawValue
        content.userInfo[Self.userInfoQueueIdKey] = item.arrQueueId
        return content
    }

    /// A single-title batch keeps the single-item shape with the count in the
    /// middle line; only a mixed batch uses the count as the headline.
    private func makeMultiItemContent(
        source: QueueItem.Source, items: [QueueItem], baseURL: String
    ) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let sharedTitle = Set(items.map(\.title)).count == 1 ? items[0].title : nil

        if let sharedTitle {
            content.title = sharedTitle
            content.subtitle = Self.countText(source: source, count: items.count)
            content.body = Self.batchBodyText(items)
        } else {
            let format = NSLocalizedString("unit.downloads", bundle: .module, comment: "")
            content.title = String.localizedStringWithFormat(format, items.count)
            content.subtitle = items.prefix(3).map(\.title).joined(separator: ", ")
            content.body = Self.batchBodyText(items)
        }

        content.sound = configuredSound
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "arrbarr.\(source.rawValue)"
        content.relevanceScore = Self.relevance(for: .downloading)
        let art = sharedTitle == nil
            ? NotificationArtwork.attachment(for: source)
            : await NotificationArtwork.attachment(
                for: items[0], apiKey: posterAPIKey(for: items[0]))
        if let art { content.attachments = [art] }
        if !baseURL.isEmpty {
            content.userInfo[Self.userInfoBaseURLKey] = baseURL
        }
        return content
    }

    // MARK: - Text formatting

    /// Title / subtitle (event + episode code) / body (release). The arr's name
    /// is carried by the attachment, not the text.
    static func subtitleText(for item: QueueItem) -> String {
        var parts = [intentLabel(for: item)]
        if let code = episodeCode(for: item) { parts.append(code) }
        return parts.joined(separator: " · ")
    }

    /// `<Quality> · <Score> · <Size>`; an upgrade shows its score move instead.
    static func bodyText(for item: QueueItem) -> String {
        var parts: [String] = []
        if let q = item.quality, !q.isEmpty { parts.append(q) }
        parts.append(scoreMoveText(for: item) ?? signedScore(item.customFormatScore))
        if let sizeStr = sizeText(item.sizeTotal) { parts.append(sizeStr) }
        return parts.joined(separator: " · ")
    }

    static func batchBodyText(_ items: [QueueItem]) -> String {
        sizeText(items.reduce(Int64(0)) { $0 + $1.sizeTotal }) ?? ""
    }

    static func countText(source: QueueItem.Source, count: Int) -> String {
        let key = switch source {
        case .sonarr, .whisparr: "unit.episodes"
        case .lidarr:            "unit.tracks"
        case .radarr:            "unit.downloads"
        }
        let format = NSLocalizedString(key, bundle: .module, comment: "")
        return String.localizedStringWithFormat(format, count)
    }

    static func episodeCode(for item: QueueItem) -> String? {
        item.seasonNumber.map { EpisodeCode.string(season: $0, episode: item.episodeNumber) }
    }

    /// nil for a non-upgrade or an unknown old score, which makes `bodyText`
    /// print the plain score.
    static func scoreMoveText(for item: QueueItem) -> String? {
        guard item.isUpgrade, let old = item.existingCustomFormatScore else { return nil }
        return "\(signedScore(old)) → \(signedScore(item.customFormatScore))"
    }

    /// Not paired with `interruptionLevel = .timeSensitive`: that needs an
    /// entitlement that changes provisioning for both DMG and App Store builds.
    static func relevance(for status: QueueItem.Status) -> Double {
        switch status {
        case .warning, .failed: return 1.0
        case .paused:           return 0.7
        default:                return 0.4
        }
    }

    static func intentLabel(for item: QueueItem) -> String {
        switch item.status {
        case .warning, .failed:
            return String(localized: "queue.needsAttention.button", bundle: .module)
        default:
            return item.isUpgrade
                ? String(localized: "detail.upgrade.button", bundle: .module)
                : String(localized: "detail.new.button", bundle: .module)
        }
    }

    static func signedScore(_ n: Int) -> String {
        if n > 0 { return "+\(n)" }
        return "\(n)"
    }

    static func sizeText(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

public enum ArrActivityURLBuilder {
    public static func queueURL(forBase base: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/activity/queue")
    }
}
