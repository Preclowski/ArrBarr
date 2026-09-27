import Foundation
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

/// The clock `NotificationCoalescer` schedules against.
///
/// Every deadline in this file is expressed through this seam so tests can drive
/// the grouping policy on a virtual clock. Grouping is defined entirely by *when*
/// things happen relative to each other, and asserting on that with real timers
/// means racing the run loop: a machine under load can drift a "second episode
/// arrives before the first one's deadline" setup right past the deadline and
/// fail a test that has nothing wrong with it.
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
///    within `burstWindow` folds into one batch. Nothing waits on a *maybe* —
///    the one thing a banner will wait for is artwork already being downloaded,
///    and only up to `NotificationArtwork`'s budget.
///  - **Series (grouped).** A Sonarr season search grabs one release *per
///    episode*, seconds apart, so the first grab is held for
///    `seriesGroupingDelay` and each sibling slides the window. One episode →
///    one banner, ten episodes → one batch banner. Bounded by
///    `seriesGroupingCap` so a slow season search still gets delivered.
///
/// Either way there's no fixed 60 s floor — the old trailing-only design made
/// *every* notification, even a lone movie grab, wait a full minute.
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
    /// fragmentation this class exists to prevent. 5 s: long enough for back-to-
    /// back episode grabs to catch up (each one slides the window), short enough
    /// that the banner still reads as "just now".
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
    /// instead of waiting out a real 5 s hold and 60 s cap.
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
        // Start the poster download at the earliest moment we know a banner is
        // coming. For an episodic arr that is a whole grouping window before
        // the banner is due, so the artwork is usually already on disk by the
        // time `post` asks for it.
        NotificationArtwork.prefetch(item, apiKey: posterAPIKey(for: item))

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
    ///   5. Season batch — one title, count in the subtitle (3 Sonarr episodes)
    ///   6. Mixed batch — no shared title, count as the headline (3 Radarr items)
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

    /// The batch shape that actually happens in the wild: one season search,
    /// N episodes of one series.
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

    /// Announce one arr health problem.
    ///
    /// Posted straight through rather than queued: the coalescer's windows exist
    /// because grabs arrive in bursts (a season pack is 24 of them), and health
    /// errors do not — they are rare, individually meaningful, and each names a
    /// different thing to go and fix. Grouping them would only hide detail.
    ///
    /// The identifier is derived from the message so the system replaces rather
    /// than stacks if the same problem is somehow announced twice.
    func postHealthIssue(source: QueueItem.Source, message: String) {
        let content = UNMutableNotificationContent()
        // The one notification that really is *about* the arr rather than
        // about a title, so its name stays in the text.
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

    /// Builds and delivers the banner. Asynchronous only because the artwork
    /// may still be downloading — see `NotificationArtwork.attachment`, which
    /// bounds that wait so a slow poster can delay a banner but never lose it.
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
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    /// The arr's key, but only for artwork the arr itself serves. A TMDB or
    /// TheTVDB URL takes no key, and appending one would change the cache key
    /// for a poster the rest of the app already holds.
    private func posterAPIKey(for item: QueueItem) -> String? {
        guard item.posterRequiresAuth else { return nil }
        return configStore.config(for: item.source).apiKey
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

    /// A batch keeps the same three-line shape as a single item wherever it can.
    /// When every grab in the group belongs to one title — a season search, an
    /// album's tracks, which is what a batch nearly always is — the title line
    /// stays the title and the count moves into the middle line, so the banner
    /// reads identically to the single-item case. Only a genuinely mixed batch
    /// falls back to a count as the headline, because there is no one title to
    /// put there.
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
        // A shared title has a poster worth showing; a mixed batch does not,
        // so it gets the arr's mark.
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

    /// Three lines, thinnest to thickest information:
    ///
    /// ```
    /// Pioneer One (2010)                  ← title:    the thing
    /// Upgrade · S01E03                    ← subtitle: what happened to it
    /// HDTV-720p · +60 → +720 · 1,2 GB     ← body:     the release
    /// ```
    ///
    /// The arr's name is gone from the text entirely — the attachment carries
    /// it now (`NotificationArtwork`) — and so are the custom-format tags,
    /// which never fit and whose whole content is summarised by the score they
    /// add up to.
    ///
    /// Middle line: the event, then the finer coordinate if the item has one
    /// (an episode does, a movie doesn't). Both pieces drop out silently when
    /// they don't apply.
    static func subtitleText(for item: QueueItem) -> String {
        var parts = [intentLabel(for: item)]
        if let code = episodeCode(for: item) { parts.append(code) }
        return parts.joined(separator: " · ")
    }

    /// Bottom line: `<Quality> · <Score> · <Size>`, fields dropping out when
    /// missing rather than rendering empty separators.
    ///
    /// The score sits between the other two rather than after them because all
    /// three describe the same thing — how good this release is — and quality
    /// and score are the pair you read together. An upgrade spends that one
    /// slot on the move it makes (`+60 → +720`) instead of the bare new value.
    static func bodyText(for item: QueueItem) -> String {
        var parts: [String] = []
        if let q = item.quality, !q.isEmpty { parts.append(q) }
        parts.append(scoreMoveText(for: item) ?? signedScore(item.customFormatScore))
        if let sizeStr = sizeText(item.sizeTotal) { parts.append(sizeStr) }
        return parts.joined(separator: " · ")
    }

    /// Bottom line of a batch: total size of the group. There is no one
    /// quality or score to report across N releases, and the sum is the one
    /// number that is meaningfully different from a single grab's.
    static func batchBodyText(_ items: [QueueItem]) -> String {
        sizeText(items.reduce(Int64(0)) { $0 + $1.sizeTotal }) ?? ""
    }

    /// "6 episodes" / "6 tracks" / "6 downloads" — the unit the arr deals in,
    /// so a Sonarr batch doesn't call episodes "items".
    static func countText(source: QueueItem.Source, count: Int) -> String {
        let key = switch source {
        case .sonarr, .whisparr: "unit.episodes"
        case .lidarr:            "unit.tracks"
        case .radarr:            "unit.downloads"
        }
        let format = NSLocalizedString(key, bundle: .module, comment: "")
        return String.localizedStringWithFormat(format, count)
    }

    /// `S01E03`, or `S01` for a whole-season grab. nil when the item has no
    /// episode coordinates at all — a movie or an album, where the title line
    /// already names the thing completely.
    static func episodeCode(for item: QueueItem) -> String? {
        item.seasonNumber.map { EpisodeCode.string(season: $0, episode: item.episodeNumber) }
    }

    /// `+60 → +720`, and only for an upgrade that actually knows what it is
    /// replacing. nil otherwise, which is what tells `bodyText` to print the
    /// plain score instead.
    static func scoreMoveText(for item: QueueItem) -> String? {
        guard item.isUpgrade, let old = item.existingCustomFormatScore else { return nil }
        return "\(signedScore(old)) → \(signedScore(item.customFormatScore))"
    }

    /// How high this sits in a notification summary. Failures outrank grabs:
    /// one needs the user, the other is a receipt.
    ///
    /// Deliberately not paired with `interruptionLevel = .timeSensitive`, which
    /// would be the matching lever — that one needs the Time Sensitive
    /// Notifications entitlement, and asking for it changes provisioning for
    /// both the DMG and the App Store build.
    static func relevance(for status: QueueItem.Status) -> Double {
        switch status {
        case .warning, .failed: return 1.0
        case .paused:           return 0.7
        default:                return 0.4
        }
    }

    /// Intent badge for the subtitle: fresh grab vs upgrade vs failed/warning.
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

    /// Sign prefix makes the value scan as a quality delta, which is how
    /// arr communities talk about custom-format scores.
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
    /// Constructs `<baseURL>/activity/queue` — the same path on Radarr, Sonarr and Lidarr web UIs.
    public static func queueURL(forBase base: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/activity/queue")
    }
}
