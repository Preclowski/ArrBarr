import SwiftUI

struct SeasonRow: View {
    let season: SonarrSeasonInfo
    let episodes: [SonarrEpisodeDetail]
    /// Map of episode-id → active queue item, when the user has
    /// in-flight downloads for this series. Lets each `EpisodeRow`
    /// surface a "downloading" indicator + hover action buttons
    /// without the parent needing a separate queue-list section.
    var queueByEpisodeId: [Int: QueueItem] = [:]
    /// Map of episode-file id → file payload (quality / size /
    /// customFormatScore) for every downloaded episode in this series.
    /// Lets each `EpisodeRow` show the score in its right gutter for
    /// downloaded-but-not-in-queue rows.
    var fileByEpisodeFileId: [Int: SonarrEpisodeFile] = [:]
    /// Per-season search trigger. DetailView passes the closure (which
    /// wraps `SonarrClient.searchSeason`); nil disables the affordance.
    var onSearchSeason: (() async -> Void)? = nil
    /// Per-episode search forwarded to `EpisodeRow`.
    var onSearchEpisode: ((Int) async -> Void)? = nil
    /// Per-episode tap forwarded to `EpisodeRow` — drills into the
    /// episode detail overlay.
    var onTapEpisode: ((SonarrEpisodeDetail) -> Void)? = nil
    /// Per-episode queue actions — wired into EpisodeRow's hover
    /// overlay so the user can pause/resume/remove a download from
    /// the season list directly.
    var onPauseEpisode: ((QueueItem) -> Void)? = nil
    var onResumeEpisode: ((QueueItem) -> Void)? = nil
    var onDeleteEpisode: ((QueueItem) -> Void)? = nil
    /// Legacy parameter — earlier iterations exposed a monitor toggle
    /// (eye / eye.slash) here. Pulled per user feedback: the affordance
    /// they actually want in this spot is "search season", not "stop
    /// monitoring". Kept for source compat; nothing reads it.
    var onSetMonitored: ((Bool) async -> Void)? = nil
    /// Initial expanded state — the pill-bar navigation pushes
    /// `true` so the active season's episodes show immediately.
    var initiallyExpanded: Bool = false
    /// Hides the leading chevron + makes the header non-tappable.
    /// Used when an outer surface (e.g. the season pill bar) owns the
    /// "which season is open" question and the row shouldn't be
    /// individually collapsible.
    var hideExpandChevron: Bool = false
    /// Series identity passed to each `EpisodeRow` so the long-hover
    /// tooltip can render the same poster + title + subtitle chrome
    /// as the queue tooltip. nil falls back to a slim tooltip with
    /// just episode info.
    var seriesTitle: String? = nil
    var seriesPosterURL: URL? = nil
    var seriesPosterRequiresAuth: Bool = false
    var seriesPosterAPIKey: String? = nil

    @State private var expanded: Bool
    @State private var isHoveringHeader = false
    @State private var isSearchingSeason = false
    @State private var didSearchSeason = false
    @State private var showSearchConfirm = false

    init(season: SonarrSeasonInfo,
         episodes: [SonarrEpisodeDetail],
         queueByEpisodeId: [Int: QueueItem] = [:],
         fileByEpisodeFileId: [Int: SonarrEpisodeFile] = [:],
         onSearchSeason: (() async -> Void)? = nil,
         onSearchEpisode: ((Int) async -> Void)? = nil,
         onTapEpisode: ((SonarrEpisodeDetail) -> Void)? = nil,
         onPauseEpisode: ((QueueItem) -> Void)? = nil,
         onResumeEpisode: ((QueueItem) -> Void)? = nil,
         onDeleteEpisode: ((QueueItem) -> Void)? = nil,
         onSetMonitored: ((Bool) async -> Void)? = nil,
         initiallyExpanded: Bool = false,
         hideExpandChevron: Bool = false,
         seriesTitle: String? = nil,
         seriesPosterURL: URL? = nil,
         seriesPosterRequiresAuth: Bool = false,
         seriesPosterAPIKey: String? = nil) {
        self.season = season
        self.episodes = episodes
        self.queueByEpisodeId = queueByEpisodeId
        self.fileByEpisodeFileId = fileByEpisodeFileId
        self.onSearchSeason = onSearchSeason
        self.onSearchEpisode = onSearchEpisode
        self.onTapEpisode = onTapEpisode
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
        self.onSetMonitored = onSetMonitored
        self.initiallyExpanded = initiallyExpanded
        self.hideExpandChevron = hideExpandChevron
        self.seriesTitle = seriesTitle
        self.seriesPosterURL = seriesPosterURL
        self.seriesPosterRequiresAuth = seriesPosterRequiresAuth
        self.seriesPosterAPIKey = seriesPosterAPIKey
        self._expanded = State(initialValue: initiallyExpanded)
    }

    private var stats: SonarrSeasonStats? { season.statistics }
    private var have: Int { stats?.episodeFileCount ?? 0 }
    private var total: Int { stats?.totalEpisodeCount ?? stats?.episodeCount ?? 0 }
    /// Number of aired-but-missing episodes — drives the search pill's
    /// visibility. When the per-episode list has loaded we filter
    /// precisely (exclude unaired); when it hasn't yet (DetailView
    /// fetches series detail and episodes in parallel — series finishes
    /// first), fall back to the season-level `total - have` count so the
    /// pill still shows immediately. Once episodes arrive the count
    /// updates and any unaired-only "missing" drops to 0.
    private var missing: Int {
        if episodes.isEmpty {
            return max(0, total - have)
        }
        let now = Date()
        return episodes.filter { ep in
            let aired = ep.airDateUtc.flatMap(parseArrDate).map { $0 <= now } ?? true
            return aired && ep.hasFile != true
        }.count
    }
    private var pct: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(have) / Double(total))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ZStack-level onHover, not Button-level. The pill is its own
            // Button — if hover-tracking lived on the header Button below,
            // the pill's hit area would steal it the moment the cursor
            // crossed the pill, dropping isHoveringHeader to false, fading
            // the pill back out, ping-ponging into the visible "blink" the
            // user reported. Tracking on the ZStack keeps both children
            // inside one hover region.
            ZStack(alignment: .trailing) {
                Button {
                    guard !hideExpandChevron else { return }
                    withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        if !hideExpandChevron {
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Text(String(format: "Season %02d", season.seasonNumber))
                            .scaledFont(size: 12, weight: .medium)
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.primary.opacity(0.10))
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(have == total && total > 0 ? Color.green : Color.accentColor)
                                    .frame(width: geo.size.width * pct)
                            }
                        }
                        .frame(width: 60, height: 3)
                        Text(verbatim: "\(have)/\(total)")
                            .scaledFont(size: 10, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hideExpandChevron)

                // Trailing pill — search season. Monitor toggle was
                // removed (see `onSetMonitored` docs); the user
                // workflow here is "find missing episodes", not
                // "stop watching this season". Pill stays available
                // even when nothing's currently missing — a re-search
                // can still pick up upgrades.
                let pillsVisible = isHoveringHeader || isSearchingSeason || didSearchSeason
                HStack(spacing: 4) {
                    if onSearchSeason != nil {
                        searchSeasonButton
                    }
                }
                .opacity(pillsVisible ? 1 : 0)
                .allowsHitTesting(pillsVisible)
                .animation(.easeOut(duration: 0.12), value: isHoveringHeader)
                .animation(.easeOut(duration: 0.12), value: didSearchSeason)
                .offset(x: -2)
            }
            #if os(macOS)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHoveringHeader = hovering }
            }
            #endif

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(episodes.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) })) { ep in
                        EpisodeRow(
                            episode: ep,
                            queueItem: queueByEpisodeId[ep.id],
                            episodeFile: ep.episodeFileId.flatMap { fileByEpisodeFileId[$0] },
                            onSearch: onSearchEpisode,
                            onTap: onTapEpisode,
                            onPauseQueueItem: onPauseEpisode,
                            onResumeQueueItem: onResumeEpisode,
                            onDeleteQueueItem: onDeleteEpisode,
                            seriesTitle: seriesTitle,
                            seriesPosterURL: seriesPosterURL,
                            seriesPosterRequiresAuth: seriesPosterRequiresAuth,
                            seriesPosterAPIKey: seriesPosterAPIKey
                        )
                    }
                    seasonLegend
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }

    /// Single-line legend rendered beneath the expanded episode list.
    /// Shows only the states actually present in this season so the
    /// strip stays compact — a fully-downloaded season collapses to
    /// just "Available", a paused-only season hides the blue dot, etc.
    @ViewBuilder
    private var seasonLegend: some View {
        let entries = legendEntries
        if !entries.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        // Small filled rectangle matches the row's
                        // progress-fill swatch — circles read as bullet
                        // points, the row treatment is a tinted bar, so
                        // the legend should rhyme with that visual.
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(entry.0)
                            .frame(width: 10, height: 6)
                        // Label takes the swatch colour so the eye
                        // pairs them as one unit — Apple's standard
                        // legend treatment (Stocks, Health, Fitness).
                        Text(entry.1, bundle: .module)
                            .scaledFont(size: 10)
                            .foregroundStyle(entry.0)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .padding(.horizontal, 6)
        }
    }

    private var legendEntries: [(Color, LocalizedStringKey)] {
        var hasOnDisk = false
        // "Missing" now covers both aired-but-absent and not-aired-yet
        // episodes — the user's mental model is "not in my library",
        // and the previous Not-aired swatch (very-low-alpha white) was
        // unreadable next to .secondary anyway. One bucket, one
        // readable colour.
        var hasMissing = false
        var queueColors: Set<LegendKey> = []
        for ep in episodes {
            if let q = queueByEpisodeId[ep.id] {
                queueColors.insert(LegendKey(status: q.status))
                continue
            }
            if ep.hasFile == true { hasOnDisk = true } else { hasMissing = true }
        }
        var out: [(Color, LocalizedStringKey)] = []
        if hasOnDisk { out.append((.primary, "Available")) }
        if hasMissing { out.append((.secondary, "Missing")) }
        let sortedQueue = queueColors.sorted { $0.order < $1.order }
        for key in sortedQueue {
            out.append((key.status.tint, key.label))
        }
        return out
    }

    /// Stable identity for queue statuses in the legend — multiple
    /// statuses share a tint (`.failed` / `.warning` are both red,
    /// `.downloading` / `.queued` / `.importing` all blue), so we
    /// collapse them by display group to avoid two identical dots.
    private struct LegendKey: Hashable {
        let group: Int
        let label: LocalizedStringKey
        let order: Int
        let status: QueueItem.Status

        init(status: QueueItem.Status) {
            self.status = status
            switch status {
            case .downloading, .queued:
                self.group = 0; self.label = "Downloading"; self.order = 0
            case .importing:
                self.group = 1; self.label = "Importing"; self.order = 1
            case .completed:
                self.group = 2; self.label = "Completed"; self.order = 2
            case .paused:
                self.group = 3; self.label = "Paused"; self.order = 3
            case .failed, .warning:
                self.group = 4; self.label = "Warning"; self.order = 4
            case .unknown:
                self.group = 5; self.label = "Unknown"; self.order = 5
            }
        }

        func hash(into hasher: inout Hasher) { hasher.combine(group) }
        static func == (lhs: LegendKey, rhs: LegendKey) -> Bool { lhs.group == rhs.group }
    }

    private var searchSeasonButton: some View {
        // macOS bordered button — same toolbar idiom as Mail's "Reply"
        // or Music's "Add to Playlist". Label has meaning (the count
        // of missing episodes), so this stays labeled rather than
        // collapsing to a bare icon.
        Button(action: fireSeasonSearch) {
            HStack(spacing: 4) {
                if isSearchingSeason {
                    ProgressView().controlSize(.mini)
                } else if didSearchSeason {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 10, weight: .medium)
                    if missing > 0 {
                        Text(String(format: String(localized: "search.searchLld.label", bundle: .module), missing))
                            .scaledFont(size: 11, weight: .medium)
                    } else {
                        Text("search.search.button", bundle: .module)
                            .scaledFont(size: 11, weight: .medium)
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isSearchingSeason)
        .help(Text("search.search.button", bundle: .module))
        .confirmationDialog(
            Text("detail.searchThisSeason.tooltip", bundle: .module),
            isPresented: $showSearchConfirm,
            titleVisibility: .visible
        ) {
            Button { performSeasonSearch() } label: { Text("search.search.button", bundle: .module) }
            Button(role: .cancel) {} label: { Text("common.cancel.button", bundle: .module) }
        } message: {
            Text("detail.willQueryYourIndexers2.tooltip", bundle: .module)
        }
    }

    private func fireSeasonSearch() {
        guard !isSearchingSeason else { return }
        showSearchConfirm = true
    }

    private func performSeasonSearch() {
        guard let onSearchSeason, !isSearchingSeason else { return }
        isSearchingSeason = true
        Task {
            await onSearchSeason()
            await MainActor.run {
                isSearchingSeason = false
                didSearchSeason = true
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { didSearchSeason = false }
        }
    }

}
