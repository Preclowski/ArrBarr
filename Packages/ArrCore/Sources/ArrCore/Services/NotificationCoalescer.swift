import Foundation
import UserNotifications

public extension QueueItem.Source {
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

/// The clock `NotificationCoalescer` schedules against.
///
/// Every deadline in this file is expressed through this seam so tests can drive
/// the grouping policy on a virtual clock. Grouping is defined entirely by *when*
/// things happen relative to each other, and asserting on that with real timers
/// means racing the run loop: a machine under load can drift a "second episode
/// arrives before the first one's deadline" setup right past the deadline and
/// fail a test that has nothing wrong with it.
@MainActor
protocol CoalescerScheduler {
    /// Now, for the `seriesGroupingCap` bookkeeping. Must share a timeline with
    /// `schedule` — a cap measured on a different clock than the timers would
    /// drift apart.
    var now: Date { get }

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping @MainActor @Sendable () -> Void
    ) -> ScheduledTimer
}

/// Production scheduler: real `RunLoop.main` timers.
///
/// Added in `.common` run loop mode so they still fire while the menu-bar panel
/// is tracking events — a plain `.default` timer pauses during scroll/interaction.
@MainActor
struct RunLoopCoalescerScheduler: CoalescerScheduler {
    /// `nonisolated` so it can be spelled as a default argument, which Swift
    /// evaluates outside the actor. Safe — there's no stored state to isolate.
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

/// Groups queue-event notifications so a burst of grabs doesn't become a burst of
/// banners. Two policies, because the arrs don't grab alike:
///
///  - **Movies / music (leading edge).** A grab is a single self-contained event,
///    so the first one fires its banner immediately and any tail that follows
///    within `burstWindow` folds into one batch. Nothing waits on a maybe.
///  - **Series (grouped).** A Sonarr season search grabs one release *per
///    episode*, seconds apart, so the first grab is held for
///    `seriesGroupingDelay` and each sibling slides the window. One episode →
///    one banner, ten episodes → one batch banner. Bounded by
///    `seriesGroupingCap` so a slow season search still gets delivered.
///
/// Either way there's no fixed 60 s floor — the old trailing-only design made
/// *every* notification, even a lone movie grab, wait a full minute.
@MainActor
public final class NotificationCoalescer {
    /// Original category — used for multi-item batches and as a back-compat
    /// fallback. Has just the "Open in browser" action because one tap can't
    /// meaningfully pause/remove a batch of items.
    public static let categoryIdentifier = "ARRBARR_QUEUE_EVENT"
    /// Single-item notifications use one of these two categories so the
    /// available action matches the item's current state.
    public static let downloadingCategoryIdentifier = "ARRBARR_QUEUE_DOWNLOADING"
    public static let pausedCategoryIdentifier = "ARRBARR_QUEUE_PAUSED"

    public static let openActionIdentifier = "ARRBARR_OPEN"
    public static let pauseActionIdentifier = "ARRBARR_PAUSE"
    public static let resumeActionIdentifier = "ARRBARR_RESUME"
    public static let removeActionIdentifier = "ARRBARR_REMOVE"

    public static let userInfoBaseURLKey = "arrBaseURL"
    public static let userInfoSourceKey = "arrSource"
    public static let userInfoQueueIdKey = "arrQueueId"

    /// How long after the first grab of a burst we keep folding further grabs
    /// for the same arr into one trailing batch. Short on purpose: it only exists
    /// to collapse a season import's tail, not to delay the headline banner.
    private let burstWindow: TimeInterval

    /// Episodic arrs hold their first grab this long so siblings can join the
    /// group. A Sonarr season search grabs one release *per episode* — separate
    /// indexer query, separate download-client add — so they land seconds apart.
    /// Firing the first one instantly (the movie/music rule) would split one
    /// logical event into a headline banner plus a batch, which is exactly the
    /// fragmentation this class exists to prevent. 10 s rather than 5 s because
    /// the costs are asymmetric: too short re-fragments the group, too long just
    /// delays a purely informational "download started" banner nobody acts on.
    private let seriesGroupingDelay: TimeInterval
    /// The grouping window *slides* — each new episode restarts it — so a slow
    /// season search still collapses into one banner. This caps how long that
    /// sliding can defer delivery, so a very drawn-out grab can't postpone the
    /// notification indefinitely.
    private let seriesGroupingCap: TimeInterval

    /// Where a finished group goes. `nil` ⇒ the real `UNUserNotificationCenter`
    /// banner. Tests substitute a recorder: `post` talks straight to the system
    /// notification centre, so without this seam the grouping decisions — which
    /// are the whole point of this class — can't be observed at all.
    private let deliver: (@MainActor (QueueItem.Source, [QueueItem]) -> Void)?

    private let configStore: ConfigStore
    private let scheduler: any CoalescerScheduler
    /// Grabs waiting to be posted, per source. For an *episodic* source this
    /// holds the whole group (nothing has been shown yet). For the leading-edge
    /// sources it holds only the tail — the first grab was already posted.
    private var pending: [QueueItem.Source: [QueueItem]] = [:]
    /// Per-source burst timer. Non-nil ⇒ a group is already forming for that arr,
    /// so a new grab joins it instead of firing its own banner.
    private var burstTimers: [QueueItem.Source: ScheduledTimer] = [:]
    /// When the current group for a source began — drives `seriesGroupingCap`.
    private var groupStartedAt: [QueueItem.Source: Date] = [:]

    /// How long a source holds a grab before posting, or `nil` for "post the
    /// first one immediately and batch the tail". Only episodic arrs wait: a
    /// movie or album grab is a single self-contained event with no siblings
    /// coming, so making it wait would be pure latency for no grouping benefit.
    private func groupingDelay(for source: QueueItem.Source) -> TimeInterval? {
        switch source {
        case .sonarr, .whisparr: return seriesGroupingDelay
        case .radarr, .lidarr:   return nil
        }
    }

    /// The timings default to the production policy. They're injectable, along
    /// with the `scheduler`, so tests can run this exact logic on a virtual clock
    /// instead of waiting out a real 10 s hold and 60 s cap.
    init(
        configStore: ConfigStore,
        burstWindow: TimeInterval = 8,
        seriesGroupingDelay: TimeInterval = 10,
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

    /// Route a finished group through the seam, falling back to a real banner.
    private func emit(source: QueueItem.Source, items: [QueueItem]) {
        if let deliver {
            deliver(source, items)
        } else {
            post(source: source, items: items)
        }
    }

    func enqueue(_ item: QueueItem) {
        let source = item.source

        guard let delay = groupingDelay(for: source) else {
            // Movies / music — leading edge: show the first grab now, fold any
            // tail that follows into one trailing batch.
            if burstTimers[source] == nil {
                emit(source: source, items: [item])
                startBurstTimer(for: source, after: burstWindow)
            } else {
                pending[source, default: []].append(item)
            }
            return
        }

        // Series — hold everything and let siblings catch up. Each new episode
        // slides the window, bounded by how long this group has already waited.
        pending[source, default: []].append(item)
        let startedAt = groupStartedAt[source] ?? scheduler.now
        groupStartedAt[source] = startedAt
        let elapsed = scheduler.now.timeIntervalSince(startedAt)
        let remainingCap = max(0, seriesGroupingCap - elapsed)
        startBurstTimer(for: source, after: min(delay, remainingCap))
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

    /// Open (or restart) the grouping window for `source`. Restarting is what
    /// makes the episodic window *slide*: each new episode pushes delivery out
    /// by another `delay`.
    private func startBurstTimer(for source: QueueItem.Source, after delay: TimeInterval) {
        burstTimers[source]?.cancel()
        burstTimers[source] = scheduler.schedule(after: delay) { [weak self] in
            self?.flush(source)
        }
    }

    /// Post whatever accumulated for `source` and close the group — one banner
    /// for a lone grab, one batch banner for several. Empty means a leading-edge
    /// source whose first grab was the whole burst: already shown, nothing left.
    private func flush(_ source: QueueItem.Source) {
        burstTimers[source]?.cancel()
        burstTimers[source] = nil
        groupStartedAt[source] = nil
        let items = pending[source] ?? []
        pending[source] = nil
        guard !items.isEmpty else { return }
        emit(source: source, items: items)
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

    /// Maps the user's `notificationSoundName` preference onto a
    /// `UNNotificationSound`:
    ///   - `""`            → system default
    ///   - `silentSoundName` → no sound (`nil`)
    ///   - otherwise        → the named sound. macOS resolves bare names
    ///     against `/System/Library/Sounds` when suffixed with `.aiff`.
    private var configuredSound: UNNotificationSound? {
        let name = configStore.notificationSoundName
        switch name {
        case "": return .default
        case ConfigStore.silentSoundName: return nil
        default: return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }

    // MARK: - Content builders

    private func makeSingleItemContent(item: QueueItem, baseURL: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = titleText(for: item)
        content.subtitle = subtitleText(for: item)
        content.body = bodyText(for: item)
        content.sound = configuredSound
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
        let format = NSLocalizedString("unit.itemsNamed", bundle: .module, comment: "")
        content.body = String.localizedStringWithFormat(format, items.count, titles)
        content.sound = configuredSound
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
            String(localized: String.LocalizationValue(item.status.displayName), bundle: .module),
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
            return String(localized: "queue.needsAttention.button", bundle: .module)
        default:
            return item.isUpgrade
                ? String(localized: "detail.upgrade.button", bundle: .module)
                : String(localized: "detail.new.button", bundle: .module)
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

public enum ArrActivityURLBuilder {
    /// Constructs `<baseURL>/activity/queue` — the same path on Radarr, Sonarr and Lidarr web UIs.
    public static func queueURL(forBase base: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/activity/queue")
    }
}
