import SwiftUI

// View components extracted from DetailView.swift. These are self-contained
// SwiftUI structs that take their dependencies via init.
//
// `MediaHeaderCard`, `RatingChip`, and `RatingPill` live in
// `MediaHeaderCard.swift` now.

struct GenreChips: View {
    let genres: [String]
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(genres, id: \.self) { g in
                Text(g)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.top, 2)
    }
}

/// Custom-format tag chips with optional score, wrapping to multiple lines
/// when needed. Used in the detail download section to mirror the chip strip
/// shown on listing rows.
struct CustomFormatChips: View {
    let formats: [String]
    let score: Int
    public var body: some View {
        TooltipFlowLayout(spacing: 4) {
            ForEach(formats, id: \.self) { TagChip(text: $0) }
            if score != 0 {
                let sign = score > 0 ? "+" : ""
                TagChip(text: "\(sign)\(score)", color: score > 0 ? .green : .red)
            }
        }
    }
}

public struct ExpandableOverview: View {
    let text: String
    @State private var expanded = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded && text.count > 220 {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { expanded = true }
                } label: {
                    // Disclosure now reads as a control — small
                    // chevron + medium weight + accent colour so it
                    // stops blending into the overview text it sits
                    // under. .secondary was too tonally similar.
                    HStack(spacing: 3) {
                        Text("Show more", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SeasonRow: View {
    let season: SonarrSeasonInfo
    let episodes: [SonarrEpisodeDetail]
    /// Map of episode-id → active queue item, when the user has
    /// in-flight downloads for this series. Lets each `EpisodeRow`
    /// surface a "downloading" indicator + hover action buttons
    /// without the parent needing a separate queue-list section.
    var queueByEpisodeId: [Int: QueueItem] = [:]
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

    @State private var expanded: Bool
    @State private var isHoveringHeader = false
    @State private var isSearchingSeason = false
    @State private var didSearchSeason = false
    @State private var showSearchConfirm = false

    init(season: SonarrSeasonInfo,
         episodes: [SonarrEpisodeDetail],
         queueByEpisodeId: [Int: QueueItem] = [:],
         onSearchSeason: (() async -> Void)? = nil,
         onSearchEpisode: ((Int) async -> Void)? = nil,
         onTapEpisode: ((SonarrEpisodeDetail) -> Void)? = nil,
         onPauseEpisode: ((QueueItem) -> Void)? = nil,
         onResumeEpisode: ((QueueItem) -> Void)? = nil,
         onDeleteEpisode: ((QueueItem) -> Void)? = nil,
         onSetMonitored: ((Bool) async -> Void)? = nil,
         initiallyExpanded: Bool = false,
         hideExpandChevron: Bool = false) {
        self.season = season
        self.episodes = episodes
        self.queueByEpisodeId = queueByEpisodeId
        self.onSearchSeason = onSearchSeason
        self.onSearchEpisode = onSearchEpisode
        self.onTapEpisode = onTapEpisode
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
        self.onSetMonitored = onSetMonitored
        self.initiallyExpanded = initiallyExpanded
        self.hideExpandChevron = hideExpandChevron
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
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Text(String(format: "Season %02d", season.seasonNumber))
                            .font(.system(size: 12, weight: .medium))
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
                        Text("\(have)/\(total)")
                            .font(.system(size: 10).monospacedDigit())
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
                            onSearch: onSearchEpisode,
                            onTap: onTapEpisode,
                            onPauseQueueItem: onPauseEpisode,
                            onResumeQueueItem: onResumeEpisode,
                            onDeleteQueueItem: onDeleteEpisode
                        )
                    }
                    seasonLegend
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
        // Destructive confirmation — searching a season hits every
        // indexer with however many episode searches, and on
        // already-complete seasons it can grab upgrades that replace
        // existing files. Red button signals "this triggers real
        // work" rather than reading like a no-op preview.
        .alert(Text("Search this season?", bundle: .module),
               isPresented: $showSearchConfirm) {
            Button(role: .destructive) { performSeasonSearch() } label: { Text("Search", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Will query your indexers for every episode in this season — including upgrades for episodes already on disk.", bundle: .module)
        }
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
                            .font(.system(size: 10))
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
        Button(action: fireSeasonSearch) {
            HStack(spacing: 3) {
                if isSearchingSeason {
                    ProgressView().controlSize(.mini)
                } else if didSearchSeason {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                    if missing > 0 {
                        Text("Search \(missing)", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                    } else {
                        Text("Search", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPill()
        .disabled(isSearchingSeason)
        .help(Text("Search", bundle: .module))
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

/// Compact full-popover episode detail. Pushed on top of `DetailView`
/// when the user taps an `EpisodeRow`. Shows episode metadata + a
/// destructive Search action when the episode is missing. Closes via
/// the leading back chevron, the trailing xmark, or Esc.
public struct EpisodeDetailOverlay: View {
    let episode: SonarrEpisodeDetail
    let seriesTitle: String
    /// Page title shown in the header — typically the tab the user
    /// came from ("Kolejka", "Nadchodzące", "Czat", …). Matches
    /// `DetailView`'s breadcrumb pattern so the user always knows
    /// where back will take them.
    let originLabel: LocalizedStringKey
    let posterURL: URL?
    let posterRequiresAuth: Bool
    let apiKey: String?
    /// Lazy-loaded file payload — `nil` until the parent fetches
    /// `/episodefile/{id}` for an on-disk episode. Drives the
    /// quality / size / customFormats chip strip.
    let episodeFile: ArrFile?
    /// Active queue item for this episode (when one's downloading).
    /// Powers the "new file" section that sits alongside the existing
    /// file — both can be present (upgrade in progress).
    let queueItem: QueueItem?
    /// Lightbox handler — fires when the user taps the poster.
    /// Parent (`DetailView`) raises its own poster lightbox in
    /// response.
    let onPosterTap: ((URL?) -> Void)?
    let onClose: () -> Void
    let onSearch: ((Int) async -> Void)?

    @State private var isSearching = false
    @State private var didSearch = false
    @State private var showSearchConfirm = false

    private var hasAired: Bool {
        guard let air = episode.airDateUtc.flatMap(parseArrDate) else { return true }
        return air <= Date()
    }

    private var episodeCode: String {
        String(format: "S%02dE%02d",
               episode.seasonNumber ?? 0,
               episode.episodeNumber ?? 0)
    }

    public init(
        episode: SonarrEpisodeDetail,
        seriesTitle: String,
        originLabel: LocalizedStringKey = "Details",
        posterURL: URL?,
        posterRequiresAuth: Bool,
        apiKey: String?,
        episodeFile: ArrFile? = nil,
        queueItem: QueueItem? = nil,
        onPosterTap: ((URL?) -> Void)? = nil,
        onClose: @escaping () -> Void,
        onSearch: ((Int) async -> Void)?
    ) {
        self.episode = episode
        self.seriesTitle = seriesTitle
        self.originLabel = originLabel
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.episodeFile = episodeFile
        self.queueItem = queueItem
        self.onPosterTap = onPosterTap
        self.onClose = onClose
        self.onSearch = onSearch
    }

    public var body: some View {
        // No solid scrim — would kill the popover's native
        // translucent chrome. Underlying series detail is opacity-
        // hidden in DetailView while this overlay is up, so we don't
        // need to mask it ourselves. The view fills the popover, lets
        // glass shine through.
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(Text("Search this episode?", bundle: .module),
               isPresented: $showSearchConfirm) {
            Button(role: .destructive) { performSearch() } label: { Text("Search", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Will query your indexers and start a download if a release matches.", bundle: .module)
        }
    }

    private var header: some View {
        // Variant A header — back chevron + origin breadcrumb. No
        // trailing xmark: a single dismiss affordance per view is the
        // Apple-HIG rule (back chevron + Esc keyboard shortcut cover
        // every dismiss path).
        HStack(spacing: 6) {
            FloatingBackButton(action: onClose)
                .keyboardShortcut(.cancelAction)
            Text(originLabel, bundle: .module)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "tv")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("Sonarr")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Poster + blur container match MediaHeaderCard's
                // chrome (110×165, 6pt corner, blur wrap) so episode
                // detail looks like every other detail surface in the
                // app instead of a custom one-off card.
                let poster = PosterBlurContainer(blurred: false, cornerRadius: 6) {
                    RemotePoster(
                        url: posterURL,
                        apiKey: posterRequiresAuth ? apiKey : nil,
                        size: CGSize(width: 110, height: 165),
                        cornerRadius: 6,
                        fallbackSymbol: "tv"
                    )
                }
                if let onPosterTap {
                    Button { onPosterTap(posterURL) } label: { poster }
                        .buttonStyle(.plain)
                        .help(Text("Show poster", bundle: .module))
                } else {
                    poster
                }
                VStack(alignment: .leading, spacing: 6) {
                    // Series title is the *context* (which show this
                    // episode belongs to), subordinate to the episode
                    // title below. 12pt medium .secondary — readable
                    // but stays under the 17pt episode title in
                    // hierarchy.
                    Text(seriesTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(episodeCode)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        // "On disk" badge dropped — was a custom
                        // status invented only for this surface. The
                        // EXISTING FILE section below + the file's
                        // metadata convey the same thing with the
                        // canonical chrome used everywhere else.
                        // "Unaired" stays because it's a real
                        // schedule state not implied by other UI.
                        if !hasAired {
                            Text("Unaired", bundle: .module)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(episode.title ?? "—")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(3)
                    if let air = episode.airDateUtc.flatMap(parseArrDate) {
                        Text(EpisodeDetailOverlay.airFormatter.string(from: air))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let runtime = episode.runtime, runtime > 0 {
                        Text(verbatim: "\(runtime) min")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let overview = episode.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            // Combined file view — three modes:
            //   1. New (downloading) + Existing (on disk) → diff
            //      style: new file prominent, existing as `└─` sub-
            //      line beneath, mirroring the movie-detail diff.
            //   2. Only downloading → new-file section (no diff).
            //   3. Only existing → ExistingFileBanner.
            // Replaces the two stacked sections that hid the user's
            // upgrade-vs-current comparison behind a `Divider`.
            if queueItem != nil || (episode.hasFile == true && episodeFile != nil) {
                Divider().opacity(0.4)
                fileSection
            }

            // Search action — only meaningful when the episode is
            // missing AND has aired. For unaired episodes the indexer
            // round-trip is wasted; for already-on-disk episodes the
            // search would just clutter history.
            if onSearch != nil, episode.hasFile != true, hasAired {
                Button(action: { showSearchConfirm = true }) {
                    HStack(spacing: 5) {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else if didSearch {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green)
                            Text("Search queued", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                            Text("Search this episode", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassPill()
                .disabled(isSearching)
            }
        }
    }

    /// Combined diff/file section. Chooses presentation by what's
    /// available:
    ///   - Both downloading + existing: diff (new file + `└─` old
    ///     line + CF chip diff).
    ///   - Downloading only: queue file section.
    ///   - Existing only: ExistingFileBanner.
    @ViewBuilder
    private var fileSection: some View {
        if let q = queueItem, let existing = episodeFile, episode.hasFile == true {
            queueFileWithDiff(new: q, existing: existing)
        } else if let q = queueItem {
            queueFileSection(q)
        } else if let existing = episodeFile {
            ExistingFileBanner(movieFile: existing)
        }
    }

    /// Diff variant — new file (downloading) up top with its full
    /// presentation, existing file rolled into a `└─` sub-line that
    /// carries quality/size/score + delta. CF chip diff (added /
    /// removed) follows the new chip strip if the sets differ.
    @ViewBuilder
    private func queueFileWithDiff(new q: QueueItem, existing: ArrFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Downloading", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let qn = q.quality, !qn.isEmpty {
                    Text(qn)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if q.sizeTotal > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: q.sizeTotal, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if q.customFormatScore != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    ScoreLabel(score: q.customFormatScore, size: 11)
                }
            }
            // `└─ <existing metadata> (delta)` — same tree-branch
            // pattern the movie/queue tooltip uses.
            ExistingFileDiffRow(
                existingQuality: existing.quality?.name,
                existingSize: existing.size,
                existingScore: existing.customFormatScore,
                newScore: q.customFormatScore
            )
            // Status icon + progress + client (same shape as
            // ProgressLine but inline).
            HStack(spacing: 6) {
                StatusIconLabel(status: q.status, iconSize: 10, labelSize: 11, labelWeight: .semibold)
                Text(verbatim: "\(Int((q.progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let client = q.downloadClient {
                    DownloadClientLabel(name: client, size: 10)
                }
            }
            ThinProgressBar(progress: q.progress)
            if let release = q.releaseName, !release.isEmpty {
                Text(release)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if !q.customFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(q.customFormats, id: \.self) { TagChip(text: $0) }
                }
            }
            // Chip diff under the strip — only renders when the sets
            // differ (same component the queue/tooltip diff uses).
            CustomFormatDiff(
                newFormats: q.customFormats,
                existingFormats: (existing.customFormats ?? []).map(\.name)
            )
        }
    }

    /// Section describing what's actively being downloaded for this
    /// episode. Same shape as the on-disk file section so the user
    /// reads both with a single mental model. Status pill + progress
    /// bar at the top give the "is this happening now" answer at a
    /// glance.
    @ViewBuilder
    private func queueFileSection(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Downloading", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let q = q.quality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if q.sizeTotal > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: q.sizeTotal, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if q.customFormatScore != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    ScoreLabel(score: q.customFormatScore, size: 11)
                }
            }
            // Status icon + progress bar — same pattern as
            // ProgressLine but inline here, no parent wrapper.
            HStack(spacing: 6) {
                StatusIconLabel(status: q.status, iconSize: 10, labelSize: 11, labelWeight: .semibold)
                Text(verbatim: "\(Int((q.progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let client = q.downloadClient {
                    DownloadClientLabel(name: client, size: 10)
                }
            }
            ThinProgressBar(progress: q.progress)
            if let release = q.releaseName, !release.isEmpty {
                Text(release)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if !q.customFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(q.customFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }

    private func performSearch() {
        guard let onSearch, let id = Optional(episode.id), !isSearching else { return }
        isSearching = true
        Task {
            await onSearch(id)
            await MainActor.run {
                isSearching = false
                didSearch = true
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { didSearch = false }
        }
    }

    static let airFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    /// Active queue item matched to this episode. Drives the
    /// "downloading" indicator + swaps hover-overlay icons from
    /// magnifyingglass (search) to pause/resume/trash.
    var queueItem: QueueItem? = nil
    /// Optional search trigger. Provided by DetailView (Sonarr), wired
    /// to `SonarrClient.searchEpisodes`. Only meaningful when the episode
    /// is missing — otherwise the indicator falls through to the file
    /// state (green check) and no action surface appears.
    var onSearch: ((Int) async -> Void)? = nil
    /// Tap the row body (not the state indicator) to drill into the
    /// episode detail surface. `nil` keeps the row passive (the
    /// legacy behaviour) for callers that don't want this drill-down.
    var onTap: ((SonarrEpisodeDetail) -> Void)? = nil
    /// Queue-item actions surfaced in the hover overlay when there's
    /// an active download for this episode.
    var onPauseQueueItem: ((QueueItem) -> Void)? = nil
    var onResumeQueueItem: ((QueueItem) -> Void)? = nil
    var onDeleteQueueItem: ((QueueItem) -> Void)? = nil

    @State private var isHovering = false
    @State private var isSearching = false
    /// Brief feedback after the command was accepted by Sonarr. The
    /// indexer search happens in the background; user just gets a quick
    /// "got it" pulse, then back to normal.
    @State private var didSearch = false
    /// Gates the .alert. Search is treated as a destructive action —
    /// it consumes indexer quota and can kick off a download — so we
    /// always confirm before firing, matching the season/series flows.
    @State private var showSearchConfirm = false
    @State private var showDeleteConfirm = false

    private var isMissing: Bool { episode.hasFile != true }
    /// Air date treated as past → episode has actually aired. nil airDate
    /// (extremely rare — usually a Sonarr metadata gap) is treated as
    /// "aired" so we don't accidentally hide search affordances for shows
    /// that didn't publish a date.
    private var hasAired: Bool {
        guard let air = episode.airDateUtc.flatMap(parseArrDate) else { return true }
        return air <= Date()
    }

    /// Title colour. Inverted from the previous "missing pops"
    /// scheme — on-disk episodes (the user's library, ready to
    /// watch) get the brightest treatment now, and every other
    /// state derives from there:
    ///   - on-disk           → `.primary`              (full white, "available")
    ///   - missing-aired     → `.primary.opacity(0.75)` (subtle dim, "not here yet")
    ///   - not-aired         → `.tertiary`             (most dim, scheduled future)
    ///   - active download   → `status.tint`           (status colour for live state)
    private var episodeTitleStyle: AnyShapeStyle {
        if !hasAired { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        if let q = queueItem { return AnyShapeStyle(q.status.tint) }
        if episode.hasFile == true { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color.primary.opacity(0.75))
    }

    public var body: some View {
        Button {
            onTap?(episode)
        } label: {
            HStack(spacing: 6) {
                Text(String(format: "%02d", episode.episodeNumber ?? 0))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)
                // Text-colour signals state — see `episodeTitleStyle`
                // for the rule table. Combined with `rowBackground`
                // (status-tint wash for active downloads), the user
                // reads "what's here / what's coming / what's done"
                // in a single glance.
                Text(episode.title ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(episodeTitleStyle)
                    .lineLimit(1)
                // Per-row Upgrade / New tag — same component the
                // queue rows use, sized .small so it stays subordinate
                // to the title. Only shown when there's an active
                // queue item (no point flagging "New" for an episode
                // that isn't being downloaded right now).
                if let q = queueItem {
                    // `.subtle` (no capsule background) because the row
                    // is already tinted with the status colour — a
                    // second filled chip on top read as noisy.
                    MediaBadgeCluster(isUpgrade: q.isUpgrade, size: .subtle)
                }
                Spacer()
                // Right-hand stat: airdate is the default, but for any
                // non-downloaded state where we actually have an
                // upgrade context (a queue item) we show the
                // custom-format score delta instead — much more useful
                // information when the row is "doing something" than
                // the air date the user already knows. Plain missing /
                // not-aired rows keep the date since there's no diff
                // to compute.
                if let q = queueItem {
                    ScoreLabel(score: q.customFormatScore, size: 10)
                } else if let air = episode.airDateUtc.flatMap(parseArrDate) {
                    Text(Self.formatter.string(from: air))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                stateIndicator
                    .frame(width: 14, height: 14, alignment: .center)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Row background doubles as a progress visualiser for
        // active downloads: a status-tinted bar that fills `progress`
        // % of the row's width, clipped to the same 4pt corner as
        // the row itself. The bar widens as the download advances —
        // no separate progress widget needed. Falls back to the
        // hover-tint for non-queue rows.
        .background(
            ZStack(alignment: .leading) {
                if let q = queueItem {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(q.status.tint.opacity(isHovering ? 0.22 : 0.16))
                            .frame(width: geo.size.width * max(0.02, min(1, q.progress)))
                    }
                } else if isHovering {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        )
        // Bare-icon hover overlay — same gradient + glyph pattern as
        // QueueRowView's action cluster. Provides a search affordance
        // for missing-aired episodes without re-purposing the right-
        // edge state indicator.
        #if os(macOS)
        // Hover overlay: queue-item actions when there's an active
        // download, otherwise a search icon for aired episodes.
        .overlay(alignment: .trailing) {
            let hasOverlay = (queueItem != nil) || (onSearch != nil && hasAired)
            if isHovering, hasOverlay {
                searchActionOverlay
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .alert(Text("Search this episode?", bundle: .module),
               isPresented: $showSearchConfirm) {
            Button(role: .destructive) { performSearch() } label: { Text("Search", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Will query your indexers and start a download if a release matches.", bundle: .module)
        }
        .alert(Text("Remove download?", bundle: .module), isPresented: $showDeleteConfirm) {
            Button(role: .destructive) {
                if let q = queueItem { onDeleteQueueItem?(q) }
            } label: { Text("Remove", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), queueItem?.title ?? episode.title ?? ""))
        }
    }

    /// Hover overlay on the trailing edge — same gradient + icon
    /// language as QueueRowView. Content depends on state: when an
    /// active queue item is present, surface pause/resume/trash;
    /// otherwise (no queue), surface a search icon.
    #if os(macOS)
    @ViewBuilder
    private var searchActionOverlay: some View {
        HStack(spacing: 6) {
            if let q = queueItem {
                queueActionIcons(for: q)
            } else {
                Button {
                    showSearchConfirm = true
                } label: {
                    Image(systemName: isSearching ? "ellipsis" : "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Search this episode", bundle: .module))
                .disabled(isSearching)
            }
        }
        .padding(.leading, 60)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.black.opacity(0.55), location: 0.55),
                    .init(color: Color.black.opacity(0.6), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    @ViewBuilder
    private func queueActionIcons(for q: QueueItem) -> some View {
        // Descriptive help keys (vs short verbs used on the queue
        // list) — in the season/episode list context the user needs
        // to know what the action targets, not just "Pause".
        if q.status == .downloading || q.status == .paused {
            if q.isPaused, let onResume = onResumeQueueItem {
                IconButton(symbol: "play.fill", helpKey: "Resume episode download",
                           accessibilityLabel: "Resume episode") { onResume(q) }
            } else if !q.isPaused, let onPause = onPauseQueueItem {
                IconButton(symbol: "pause.fill", helpKey: "Pause episode download",
                           accessibilityLabel: "Pause episode") { onPause(q) }
            }
        }
        if onDeleteQueueItem != nil {
            IconButton(symbol: "trash", helpKey: "Remove episode download",
                       accessibilityLabel: "Remove episode", tint: .red) {
                showDeleteConfirm = true
            }
        }
    }
    #endif

    @ViewBuilder
    private var stateIndicator: some View {
        if isSearching {
            ProgressView().controlSize(.mini)
        } else if didSearch {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
        } else if !hasAired {
            Image(systemName: "calendar")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(Text("Not aired yet", bundle: .module))
        } else if episode.hasFile != true && queueItem == nil {
            // Missing-aired with no active download — the only state
            // that still warrants an indicator glyph. Downloading
            // episodes are now signalled by the row's background
            // tint (see `rowBackground`), not an icon.
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
    }

    /// Surface the alert; actual work happens in `performSearch` after
    /// the user taps Search in the alert. Keeps "indexer search" from
    /// being a single careless tap on the magnifyingglass — the model
    /// you've configured may have rate-limited indexer pulls.
    private func fireSearch() {
        guard !isSearching else { return }
        showSearchConfirm = true
    }

    private func performSearch() {
        guard let onSearch, !isSearching else { return }
        isSearching = true
        Task {
            await onSearch(episode.id)
            await MainActor.run {
                isSearching = false
                didSearch = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { didSearch = false }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f
    }()
}

struct TrackRow: View {
    let track: LidarrTrackDetail

    @State private var isHovering = false

    /// Title colour. Flipped to match `EpisodeRow.episodeTitleStyle`
    /// post-redesign: on-disk tracks (your library, ready to play)
    /// take the brightest tone; missing tracks dim out from that
    /// baseline. Audio releases drop all at once so there's no
    /// "not aired" axis.
    private var trackTitleStyle: AnyShapeStyle {
        if track.hasFile == true { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color.primary.opacity(0.75))
    }

    private var rowBackground: Color {
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(track.trackNumber ?? String(track.absoluteTrackNumber ?? 0))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            // Text-colour signals state (matches EpisodeRow). No
            // status icons — audio releases either exist on disk or
            // they don't, the trailing duration + dim title carry
            // that bit without a green check / empty circle pair.
            Text(track.title ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(trackTitleStyle)
                .lineLimit(1)
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatDuration(ms: dur))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // Spacer between title and duration leaves a transparent gap;
        // without an explicit hit shape the right-hand half of the row
        // doesn't register hover, so the hover-tint flickers in and
        // out as the cursor crosses the Spacer. contentShape claims
        // the full row width as one hover region.
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
    }
}

/// "Option B" download section: minimalist, no card chrome.
///
/// - Single item: one progress line + thin bar; if upgrade, a NEW/OLD
///   two-line diff and a monospaced release-name footer.
/// - Multiple items (ungrouped episodes for the same series): a header line
///   summarising the queue, then a stacked list of compact rows. The
///   originally-clicked row gets an accent left border so the user keeps
///   their bearings.
struct DownloadSection: View {
    let items: [QueueItem]
    let focused: QueueItem
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var showListingBadges: Bool = false
    var rowHoverDetail: Bool = false
    var listCollapsible: Bool = false
    var listExpandedDefault: Bool = true
    /// Per-item drill-down for the multi-row variant — fires when the
    /// user taps an episode row in a season-pack download list.
    var onTapItem: ((QueueItem) -> Void)? = nil
    /// Per-item queue actions for the multi-row variant. Wired by
    /// DetailView to QueueViewModel.pause/resume/delete.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil

    @State private var listExpanded: Bool

    init(
        items: [QueueItem],
        focused: QueueItem,
        showInlineUpgrade: Bool = true,
        showCustomFormats: Bool = false,
        showListingBadges: Bool = false,
        rowHoverDetail: Bool = false,
        listCollapsible: Bool = false,
        listExpandedDefault: Bool = true,
        onTapItem: ((QueueItem) -> Void)? = nil,
        onPauseItem: ((QueueItem) -> Void)? = nil,
        onResumeItem: ((QueueItem) -> Void)? = nil,
        onDeleteItem: ((QueueItem) -> Void)? = nil
    ) {
        self.items = items
        self.focused = focused
        self.showInlineUpgrade = showInlineUpgrade
        self.showCustomFormats = showCustomFormats
        self.showListingBadges = showListingBadges
        self.rowHoverDetail = rowHoverDetail
        self.listCollapsible = listCollapsible
        self.listExpandedDefault = listExpandedDefault
        self.onTapItem = onTapItem
        self.onPauseItem = onPauseItem
        self.onResumeItem = onResumeItem
        self.onDeleteItem = onDeleteItem
        self._listExpanded = State(initialValue: listExpandedDefault)
    }

    private var sortedItems: [QueueItem] {
        items.sorted { ($0.subtitle ?? "") < ($1.subtitle ?? "") }
    }

    /// Mirrors QueueRowView.hasExistingFileMetadata — guards the
    /// inline "↳ old metadata" diff row from rendering empty when an
    /// upgrade item has no existing-file fields populated.
    private func hasExistingFileMetadata(_ item: QueueItem) -> Bool {
        (item.existingQuality.map { !$0.isEmpty } ?? false)
            || (item.existingSize ?? 0) > 0
            || (item.existingCustomFormatScore ?? 0) != 0
    }

    public var body: some View {
        if items.count <= 1 {
            singleItemBlock(focused)
        } else {
            multiItemBlock
        }
    }

    // MARK: Single item

    @ViewBuilder
    private func singleItemBlock(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showListingBadges {
                listingBadges(item)
            }
            ProgressLine(item: item, hideDownloadClient: showListingBadges)
            // Surface the arr's own statusMessages when it has flagged
            // a problem with the download. Up until now warnings were
            // invisible — the user saw a red status pill and had to
            // bounce to Sonarr/Radarr's UI to find out why. Sitting
            // right under ProgressLine ties the explanation to the
            // status that asked for it.
            if !item.statusMessages.isEmpty {
                QueueStatusMessagesBanner(messages: item.statusMessages, tint: item.status.tint)
            }
            // Inline upgrade diff — same `└─ <old metadata> (delta)`
            // pattern the tooltip uses. Sits directly under
            // ProgressLine so the eye reads "new file → old file" as
            // a vertical comparison.
            if item.isUpgrade, hasExistingFileMetadata(item) {
                ExistingFileDiffRow(
                    existingQuality: item.existingQuality,
                    existingSize: item.existingSize,
                    existingScore: item.existingCustomFormatScore,
                    newScore: item.customFormatScore
                )
            }
            ThinProgressBar(progress: item.progress, tint: item.status.tint)

            if showInlineUpgrade && item.isUpgrade {
                upgradeDiff(item)
                    .padding(.top, 4)
            }

            if showCustomFormats, !item.customFormats.isEmpty {
                // Score moved to `ProgressLine`'s status-row trailing
                // edge — same right gutter as the queue list row uses.
                // Strip carries format tags only.
                CustomFormatChips(formats: item.customFormats, score: 0)
                // Chip diff (added / removed) directly under the
                // strip — mirrors the tooltip's pattern.
                if item.isUpgrade {
                    CustomFormatDiff(
                        newFormats: item.customFormats,
                        existingFormats: item.existingCustomFormats
                    )
                }
            }

            // Filename block — bumped from 10pt tertiary to 11pt
            // secondary so the actual release name reads as content,
            // not a footnote. When the row is an upgrade, the existing
            // file's on-disk path follows on a `└─` sub-line, same
            // tree-branch nesting the metadata diff uses one row up.
            if let release = item.releaseName, !release.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(release)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if item.isUpgrade,
                       let existing = item.existingFileName, !existing.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: "└─")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(existing)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    /// Wrapper that defers to the public `ListingBadgesView`. Kept so the
    /// DownloadSection's existing `if showListingBadges` block doesn't need
    /// to reach into the public namespace.
    @ViewBuilder
    private func listingBadges(_ item: QueueItem) -> some View {
        ListingBadgesView(item: item)
    }

    @ViewBuilder
    private func upgradeDiff(_ item: QueueItem) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                DiffTag(text: "NEW", style: .new)
                qualityCells(
                    quality: item.quality,
                    size: item.sizeTotal,
                    score: item.customFormatScore,
                    tags: item.customFormats
                )
            }
            GridRow {
                DiffTag(text: "OLD", style: .old)
                qualityCells(
                    quality: item.existingQuality,
                    size: item.existingSize ?? 0,
                    score: item.existingCustomFormatScore ?? 0,
                    tags: item.existingCustomFormats
                )
            }
        }
    }

    @ViewBuilder
    private func qualityCells(quality: String?, size: Int64, score: Int, tags: [String]) -> some View {
        HStack(spacing: 4) {
            if let q = quality, !q.isEmpty {
                Text(q)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            if size > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if score != 0 {
                Text("·").foregroundStyle(.tertiary)
                let sign = score > 0 ? "+" : ""
                Text("\(sign)\(score)")
                    .foregroundStyle(score > 0 ? Color.green : Color.red)
                    .font(.system(size: 11, weight: .semibold))
            }
            ForEach(tags, id: \.self) { TagChip(text: $0) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Multi-item

    @ViewBuilder
    private var multiItemBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard listCollapsible else { return }
                withAnimation(.smooth(duration: 0.18)) { listExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if listCollapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                    }
                    Text("In queue", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: String(localized: "%lld downloads", bundle: .module), items.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: aggregateSizeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!listCollapsible)

            if !listCollapsible || listExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedItems) { it in
                        MultiRow(
                            item: it,
                            isFocused: it.id == focused.id,
                            showInlineUpgrade: showInlineUpgrade,
                            showCustomFormats: showCustomFormats,
                            hoverDetail: rowHoverDetail,
                            onTap: onTapItem.map { fn in { fn(it) } },
                            onPause: onPauseItem.map { fn in { fn(it) } },
                            onResume: onResumeItem.map { fn in { fn(it) } },
                            onDelete: onDeleteItem.map { fn in { fn(it) } }
                        )
                    }
                }
            }
        }
    }

    private var aggregateSizeText: String {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left = items.reduce(Int64(0)) { $0 + $1.sizeLeft }
        let done = max(0, total - left)
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let doneStr = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        return "\(doneStr) / \(totalStr)"
    }
}

struct ProgressLine: View {
    let item: QueueItem
    var hideDownloadClient: Bool = false

    public var body: some View {
        // One row was cramming status + percentage + quality + time left +
        // size + client all on a single line, which wrapped "Downloading" to
        // two lines on narrow popovers. Split: status / progress / client on
        // top (the "what's happening" line), technical details (quality ·
        // time · size) below.
        VStack(alignment: .leading, spacing: 2) {
            statusRow
            // detailsRow now always renders when there's meta OR a
            // client to surface — the client lives there post-refactor.
            if hasDetails || (!hideDownloadClient && item.downloadClient != nil) {
                detailsRow
            }
        }
    }

    // Right gutter for both rows mirrors QueueRowView's pattern: score
    // on the status line, download client on the details line — see
    // `QueueItemPrimitives` for the shared atoms.
    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 4) {
            StatusIconLabel(status: item.status,
                            iconSize: 10,
                            labelSize: 11,
                            labelWeight: .semibold)
            Text("·").foregroundStyle(.tertiary)
            Text(verbatim: "\(Int((item.progress * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            ScoreLabel(score: item.customFormatScore, size: 11)
        }
    }

    @ViewBuilder
    private var detailsRow: some View {
        HStack(spacing: 4) {
            let segments: [String] = [
                item.quality.flatMap { $0.isEmpty ? nil : $0 },
                formattedTimeLeft,
                item.sizeTotal > 0 ? sizeText : nil,
            ].compactMap { $0 }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(verbatim: segment)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if !hideDownloadClient, let client = item.downloadClient {
                DownloadClientLabel(name: client, size: 10)
            }
        }
    }

    /// `detailsRow` now always renders (it carries the download client
    /// even when no other meta exists), so the `if hasDetails` gate in
    /// the parent body has to broaden too. Kept the legacy helper for
    /// future readers — the body uses the broadened condition inline.

    private var hasDetails: Bool {
        (item.quality?.isEmpty == false) || formattedTimeLeft != nil || item.sizeTotal > 0
    }

    private var sizeText: String {
        let done = max(0, item.sizeTotal - item.sizeLeft)
        return "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file))"
    }

    private var formattedTimeLeft: String? {
        guard let raw = item.timeLeft, !raw.isEmpty else { return nil }
        let trimmed = String(raw.prefix { $0 != "." })
        return trimmed == "00:00:00" ? nil : trimmed
    }
}


struct DiffTag: View {
    enum Style { case new, old }
    let text: String
    let style: Style

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .tracking(0.5)
            .foregroundStyle(style == .new ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 14)
            .background(
                style == .new
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 3)
            )
    }
}

/// One row inside the multi-item list: status dot, episode/quality text,
/// and a thin progress bar. When `hoverDetail` is true and the item is an
/// upgrade, the row reveals existing-file detail on demand:
///   - macOS: hovering for ~350 ms opens a popover anchored to the row.
///   - iOS:   tapping the row toggles the same content inline below it.
struct MultiRow: View {
    let item: QueueItem
    let isFocused: Bool
    var showInlineUpgrade: Bool = true
    var showCustomFormats: Bool = false
    var hoverDetail: Bool = false
    /// Tap handler — drills the user into the episode detail
    /// overlay. Nil keeps the row passive.
    var onTap: (() -> Void)? = nil
    /// Per-item queue actions surfaced as a hover-only icon cluster
    /// on the trailing edge (same affordance pattern as queue list
    /// rows).
    var onPause: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var showHoverPopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false

    private var canPauseResume: Bool {
        item.status == .downloading || item.status == .paused
    }

    public var body: some View {
        Button {
            onTap?()
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        // Border on focus is gone — the user wanted the focused row
        // to read as part of the list, not stand out with a chrome
        // bar. Background tint stays (subtle hover/focus signal).
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        #if os(macOS)
        // Long-hover rich tooltip — same QueueItemTooltip the queue
        // list rows use, anchored to .leading so it floats out on
        // the *right* side of the row (per user feedback). One
        // tooltip component everywhere = one place to bump styling.
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled, isHovering { showHoverPopover = true }
                }
            } else {
                showHoverPopover = false
            }
        }
        .popover(isPresented: $showHoverPopover, arrowEdge: .leading) {
            QueueItemTooltip(item: item)
                .popoverBehavior(.applicationDefined)
        }
        // Bare-icon action cluster — same gradient + glyph language
        // as QueueRowView's hover overlay.
        .overlay(alignment: .trailing) {
            if isHovering, hasAnyAction {
                inlineActionIcons
                    .padding(.leading, 60)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.black.opacity(0.55), location: 0.55),
                                .init(color: Color.black.opacity(0.6), location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .transition(.opacity)
            }
        }
        #endif
        .alert(Text("Remove download?", bundle: .module), isPresented: $showDeleteConfirmation) {
            Button(role: .destructive) { onDelete?() } label: { Text("Remove", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), item.title))
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.status.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(item.status.tint)
                if let code = episodeCode {
                    Text(code)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(headlineText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isUpgrade {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.indigo)
                }
                Spacer(minLength: 4)
                Text(trailingText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                ScoreLabel(score: item.customFormatScore)
            }
            ThinProgressBar(progress: item.progress, tint: item.status.tint)
            if showCustomFormats, !item.customFormats.isEmpty {
                CustomFormatChips(formats: item.customFormats, score: 0)
                    .padding(.top, 1)
            }
            if !hoverDetail, showInlineUpgrade, isFocused, item.isUpgrade {
                Text(verbatim: upgradeHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }

    private var hasAnyAction: Bool {
        (canPauseResume && (onPause != nil || onResume != nil)) || onDelete != nil
    }

    #if os(macOS)
    @ViewBuilder
    private var inlineActionIcons: some View {
        HStack(spacing: 6) {
            if canPauseResume {
                if item.isPaused, let onResume {
                    IconButton(symbol: "play.fill", helpKey: "Resume",
                               accessibilityLabel: "Resume \(item.title)") { onResume() }
                } else if !item.isPaused, let onPause {
                    IconButton(symbol: "pause.fill", helpKey: "Pause",
                               accessibilityLabel: "Pause \(item.title)") { onPause() }
                }
            }
            if onDelete != nil {
                IconButton(symbol: "trash", helpKey: "Remove from client",
                           accessibilityLabel: "Remove \(item.title)", tint: .red) {
                    showDeleteConfirmation = true
                }
            }
        }
    }
    #endif

    private var rowBackground: Color {
        if isFocused { return Color.accentColor.opacity(0.06) }
        if isHovering { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var episodeCode: String? {
        guard let s = item.seasonNumber, let e = item.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    /// Episode title + quality, joined by a dot.
    private var headlineText: String {
        var bits: [String] = []
        if let t = item.episodeTitle, !t.isEmpty { bits.append(t) }
        if let q = item.quality, !q.isEmpty { bits.append(q) }
        if bits.isEmpty, let release = item.releaseName, !release.isEmpty { bits.append(release) }
        return bits.joined(separator: " · ")
    }

    private var trailingText: String {
        if item.status == .queued { return "Queued" }
        return "\(Int((item.progress * 100).rounded()))%"
    }

    private var upgradeHint: String {
        var bits: [String] = ["↑ replacing"]
        if let q = item.existingQuality, !q.isEmpty { bits.append(q) }
        if let s = item.existingCustomFormatScore, s != 0 {
            let sign = s > 0 ? "+" : ""
            bits.append("(\(sign)\(s))")
        }
        return bits.joined(separator: " ")
    }
}

/// Full-width existing-file banner for Radarr details. Sits between the
/// header card and the overview so the chips have room to breathe.
/// "Listing" badges mirroring the queue row's title chips: Upgrade/New
/// capsule + download-client capsule. Shown in the movie detail header
/// (under the ratings) so the user knows which client is grinding away
/// without having to scroll to the download section.
public struct ListingBadgesView: View {
    let item: QueueItem

    /// Only the Upgrade pill, and only when the row is actually an upgrade.
    /// "New" is implicit (no existing-file banner = brand new download), and
    /// the download client already shows up in `ProgressLine` below — both
    /// previously duplicated here.
    public var body: some View {
        if item.isUpgrade {
            HStack(spacing: 4) {
                Text("Upgrade", bundle: .module)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.indigo.opacity(0.15), in: Capsule())
                Spacer()
            }
        }
    }
}

/// Banner describing the file an arr already has on disk for this item.
/// Two callers:
///   - upgrade-in-progress (queue item) — fields come from the queue
///     row's `existing*` metadata
///   - already-in-library (no active queue) — fields come from
///     `RadarrMovieDetail.movieFile` / similar
/// The view body is the same; only the source of the fields differs.
struct ExistingFileBanner: View {
    let quality: String?
    let size: Int64?
    let customFormatScore: Int?
    let customFormats: [String]
    let fileName: String?

    init(quality: String?, size: Int64?, customFormatScore: Int?,
         customFormats: [String], fileName: String?) {
        self.quality = quality; self.size = size
        self.customFormatScore = customFormatScore
        self.customFormats = customFormats
        self.fileName = fileName
    }

    /// Build the banner from a queue row's `existing*` fields (upgrade-time
    /// metadata Radarr/Sonarr send when a download will replace something).
    init(item: QueueItem) {
        self.init(
            quality: item.existingQuality,
            size: item.existingSize,
            customFormatScore: item.existingCustomFormatScore,
            customFormats: item.existingCustomFormats,
            fileName: item.existingFileName
        )
    }

    /// Build the banner from an arr's library `movieFile` — the file the
    /// user already owns, no queue activity required.
    init(movieFile: ArrFile) {
        self.init(
            quality: movieFile.quality?.name,
            size: movieFile.size,
            customFormatScore: movieFile.customFormatScore,
            customFormats: (movieFile.customFormats ?? []).map(\.name),
            fileName: movieFile.relativePath
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Label leading, neutral secondary — matches the tooltip's
            // `existingFileSummary`. Quality/size/score follow on the
            // right edge.
            HStack(spacing: 6) {
                Text("Existing file", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let q = quality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                if let size, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = customFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    ScoreLabel(score: s, size: 11)
                }
            }
            // Filename now sits directly under the header (was last in
            // the stack — bumped up because "what file is on disk" is
            // the natural follow-up to "EXISTING FILE", more so than
            // its custom-format tags). Promoted from tertiary 10pt to
            // secondary 11pt so it reads as primary content, not a
            // footnote.
            if let name = fileName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !customFormats.isEmpty {
                TooltipFlowLayout(spacing: 4) {
                    ForEach(customFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No tinted card — the indigo "↑ EXISTING FILE" label on the
        // trailing edge already brands the section; an additional
        // indigo background dropped chip contrast and broke visual
        // consistency with the same section inside the tooltip.
    }
}

/// Compact one-line summary of the existing file an item would replace.
/// Used in Radarr's header card under the rating chips.
struct ExistingFileLine: View {
    let item: QueueItem

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("Existing", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                if let q = item.existingQuality, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let size = item.existingSize, size > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let s = item.existingCustomFormatScore, s != 0 {
                    Text("·").foregroundStyle(.tertiary)
                    let sign = s > 0 ? "+" : ""
                    Text("\(sign)\(s)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s > 0 ? Color.green : Color.red)
                }
            }
            if !item.existingCustomFormats.isEmpty {
                TooltipFlowLayout(spacing: 3) {
                    ForEach(item.existingCustomFormats, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }
}

func formatDuration(ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
