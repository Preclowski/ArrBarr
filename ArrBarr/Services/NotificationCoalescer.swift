import Foundation
import UserNotifications

extension QueueItem.Source {
    var serviceKind: ServiceKind {
        switch self {
        case .radarr: return .radarr
        case .sonarr: return .sonarr
        case .lidarr: return .lidarr
        }
    }
}

/// Coalesces queue-event notifications into one banner per arr per 60s window.
/// Without this, a Sonarr import of a 10-episode pack fires 10 banners in a burst.
@MainActor
final class NotificationCoalescer {
    /// Original category — used for multi-item batches and as a back-compat
    /// fallback. Has just the "Open in browser" action because one tap can't
    /// meaningfully pause/remove a batch of items.
    static let categoryIdentifier = "ARRBARR_QUEUE_EVENT"
    /// Single-item notifications use one of these two categories so the
    /// available action matches the item's current state.
    static let downloadingCategoryIdentifier = "ARRBARR_QUEUE_DOWNLOADING"
    static let pausedCategoryIdentifier = "ARRBARR_QUEUE_PAUSED"

    static let openActionIdentifier = "ARRBARR_OPEN"
    static let pauseActionIdentifier = "ARRBARR_PAUSE"
    static let resumeActionIdentifier = "ARRBARR_RESUME"
    static let removeActionIdentifier = "ARRBARR_REMOVE"

    static let userInfoBaseURLKey = "arrBaseURL"
    static let userInfoSourceKey = "arrSource"
    static let userInfoQueueIdKey = "arrQueueId"

    private let window: TimeInterval = 60
    private let configStore: ConfigStore
    private var pending: [QueueItem.Source: [QueueItem]] = [:]
    private var flushTimer: Timer?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func enqueue(_ item: QueueItem) {
        pending[item.source, default: []].append(item)
        scheduleFlush()
    }

    /// Fires a sequence of representative sample banners — wired to the "Send
    /// test notification" button in Settings. Covers each variant so the user
    /// can see how every kind of notification renders without waiting for
    /// real grab events:
    ///   1. New grab, downloading (Sonarr)
    ///   2. Upgrade with score delta (Radarr)
    ///   3. New grab, paused — actions show "Start downloading" (Lidarr)
    ///   4. Needs attention (failed Sonarr)
    ///   5. Multi-item batch (3 Radarr items, batch category, no per-item actions)
    /// They're staggered ~1.2s apart so macOS shows each one rather than
    /// collapsing them into a single grouped banner instantly. Same arr
    /// `threadIdentifier` means Notification Center will still group them
    /// under each arr afterwards.
    func postTest() {
        let stages: [(QueueItem.Source, [QueueItem])] = [
            (.sonarr, [Self.sampleNewGrabSonarr()]),
            (.radarr, [Self.sampleUpgradeRadarr()]),
            (.lidarr, [Self.samplePausedLidarr()]),
            (.sonarr, [Self.sampleFailedSonarr()]),
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
            title: "Pioneer One", subtitle: "S01E03 · Endurance",
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
            title: "Northern Cascade", subtitle: "S02E04 · Cold Start",
            releaseName: "Northern.Cascade.S02E04.2160p.WEB-DL.DV.HDR10-TEST",
            status: .failed, progress: 0.92,
            sizeTotal: 28_000_000_000, sizeLeft: 0, timeLeft: nil,
            customFormats: ["DV", "HDR10", "Atmos", "x265"], customFormatScore: 1240,
            quality: "WEB-DL 2160p", isUpgrade: false,
            contentSlug: "northern-cascade"
        )
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

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        flushTimer = nil
        let snapshot = pending
        pending.removeAll()
        for (source, items) in snapshot where !items.isEmpty {
            post(source: source, items: items)
        }
    }

    private func post(source: QueueItem.Source, items: [QueueItem]) {
        let cfg = configStore.config(for: source.serviceKind)
        let baseURL = cfg.baseURL

        let content: UNMutableNotificationContent
        let identifier: String
        if items.count == 1 {
            let item = items[0]
            content = makeSingleItemContent(item: item, baseURL: baseURL)
            identifier = "arrbarr.\(source.rawValue).\(item.id)"
        } else {
            content = makeMultiItemContent(source: source, items: items, baseURL: baseURL)
            identifier = "arrbarr.\(source.rawValue).\(UUID().uuidString)"
        }

        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Content builders

    private func makeSingleItemContent(item: QueueItem, baseURL: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = titleText(for: item)
        content.subtitle = subtitleText(for: item)
        content.body = bodyText(for: item)
        content.sound = .default
        content.categoryIdentifier = item.isPaused
            ? Self.pausedCategoryIdentifier
            : Self.downloadingCategoryIdentifier
        content.threadIdentifier = "arrbarr.\(item.source.rawValue)"

        if !baseURL.isEmpty {
            content.userInfo[Self.userInfoBaseURLKey] = baseURL
        }
        content.userInfo[Self.userInfoSourceKey] = item.source.rawValue
        content.userInfo[Self.userInfoQueueIdKey] = item.arrQueueId
        return content
    }

    private func makeMultiItemContent(
        source: QueueItem.Source, items: [QueueItem], baseURL: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = source.displayName
        let titles = items.prefix(3).map(\.title).joined(separator: ", ")
        let format = String(localized: "%lld items: %@")
        content.body = String(format: format, items.count, titles)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "arrbarr.\(source.rawValue)"
        if !baseURL.isEmpty {
            content.userInfo[Self.userInfoBaseURLKey] = baseURL
        }
        return content
    }

    // MARK: - Text formatting

    /// Title pulls the high-level "what kind of event" info onto the bold
    /// first line: `Sonarr · Upgrade · Downloading`. Status sits next to
    /// intent so users can tell whether the upgrade is in flight, paused, or
    /// already importing without expanding the banner.
    private func titleText(for item: QueueItem) -> String {
        [
            item.source.displayName,
            intentLabel(for: item),
            String(localized: String.LocalizationValue(item.status.displayName)),
        ].joined(separator: " · ")
    }

    /// Subtitle: release title plus episode subtitle for Sonarr.
    private func subtitleText(for item: QueueItem) -> String {
        if let sub = item.subtitle, !sub.isEmpty {
            return "\(item.title) · \(sub)"
        }
        return item.title
    }

    /// Two-line body:
    ///   Line 1: `<Quality> · <Size> · <Score>` — the headline numbers, with
    ///           the score showing `old → new` for upgrades.
    ///   Line 2: `[tag1][tag2][tag3]` — custom-format tags.
    /// Fields drop out of line 1 when missing rather than rendering empty
    /// separators. macOS only shows ~3 body lines before truncating.
    private func bodyText(for item: QueueItem) -> String {
        var lines: [String] = []

        var head: [String] = []
        if let q = item.quality, !q.isEmpty { head.append(q) }
        if let sizeStr = sizeText(item.sizeTotal) { head.append(sizeStr) }
        head.append(scoreText(for: item))
        if !head.isEmpty {
            lines.append(head.joined(separator: " · "))
        }

        if !item.customFormats.isEmpty {
            lines.append(item.customFormats.map { "[\($0)]" }.joined())
        }

        return lines.joined(separator: "\n")
    }

    /// Intent badge for the title: fresh grab vs upgrade vs failed/warning.
    private func intentLabel(for item: QueueItem) -> String {
        switch item.status {
        case .warning, .failed:
            return String(localized: "Needs attention")
        default:
            return item.isUpgrade
                ? String(localized: "Upgrade")
                : String(localized: "New")
        }
    }

    /// Score formatting:
    ///   - Upgrade: "+45 → +1850"
    ///   - Fresh:   "+1850" (or "0", "-200")
    /// Sign prefix makes the value scan as a quality delta, which is how
    /// arr communities talk about custom-format scores.
    private func scoreText(for item: QueueItem) -> String {
        let new = signedScore(item.customFormatScore)
        if item.isUpgrade, let old = item.existingCustomFormatScore {
            return "\(signedScore(old)) → \(new)"
        }
        return new
    }

    private func signedScore(_ n: Int) -> String {
        if n > 0 { return "+\(n)" }
        return "\(n)"
    }

    private func sizeText(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum ArrActivityURLBuilder {
    /// Constructs `<baseURL>/activity/queue` — the same path on Radarr, Sonarr and Lidarr web UIs.
    static func queueURL(forBase base: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/activity/queue")
    }
}
