import SwiftUI

struct EpisodeRow: View {
    let episode: SonarrEpisodeDetail
    /// Active queue item matched to this episode. Drives the
    /// "downloading" indicator + swaps hover-overlay icons from
    /// magnifyingglass (search) to pause/resume/trash.
    var queueItem: QueueItem? = nil
    /// Episode-file payload when this episode is on disk. Used to render
    /// the file's custom-format score in the right gutter — same
    /// `ScoreLabel` treatment as an in-progress download — so the
    /// "available" rows surface their points instead of the air date the
    /// user already knows.
    var episodeFile: SonarrEpisodeFile? = nil
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
    /// Series identity for the long-hover tooltip — lets it render
    /// the queue-tooltip chrome (poster + series title + season /
    /// episode subtitle) instead of an episode-only slim card.
    var seriesTitle: String? = nil
    var seriesPosterURL: URL? = nil
    var seriesPosterRequiresAuth: Bool = false
    var seriesPosterAPIKey: String? = nil

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
    /// Long-hover popover (same 600 ms gate as queue rows). Shows
    /// quality / size / score + upgrade diff when there's something
    /// useful to surface; suppressed for missing-aired rows where
    /// the tooltip would just repeat the row text.
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var isMissing: Bool { episode.hasFile != true }

    /// Gate for the long-hover popover. We only surface a tooltip
    /// when there's actually something to show — either an active
    /// download (with optional upgrade diff context) or an on-disk
    /// file (quality / score / size). Missing-aired or not-aired
    /// rows have nothing the row text doesn't already say.
    private var hasTooltipContent: Bool {
        queueItem != nil || episodeFile != nil
    }

    /// `S02E04`-style episode identifier rendered on the trailing
    /// edge. Same format the tooltip header uses.
    private var episodeCode: String {
        String(format: "S%02dE%02d",
               episode.seasonNumber ?? 0,
               episode.episodeNumber ?? 0)
    }
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
                // Title leads, full-width. Episode code moved to the
                // right gutter — used to sit in a fixed 18pt slot
                // ahead of the title which crammed against long
                // titles and broke awkwardly when font-scale bumped
                // wrapped them to a second line. Right-gutter
                // placement matches Mail/Music idiom: identifier on
                // the trailing edge, content fills the row.
                Text(episode.title ?? "—")
                    .scaledFont(size: 11)
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
                    // Diff against the existing file when this download
                    // is an upgrade — "are we gaining or losing points?"
                    // is the actionable bit. Plain raw score for fresh
                    // downloads with no replacement target.
                    ScoreLabel(delta: q.customFormatScore, from: q.existingCustomFormatScore, size: 10)
                } else if let file = episodeFile, let score = file.customFormatScore {
                    // On-disk episode — show its custom-format score
                    // (more useful than the air date the user already
                    // knows). Falls back to the date below when the file
                    // didn't carry a score.
                    ScoreLabel(score: score, size: 10)
                } else if let air = episode.airDateUtc.flatMap(parseArrDate) {
                    Text(Self.formatter.string(from: air))
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                }
                // Episode code on the trailing edge — `S02E04`
                // (full season + episode for unambiguous reference,
                // matches the tooltip header and other rows that
                // surface episode identity).
                Text(episodeCode)
                    .scaledFont(size: 9, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
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
        // download, otherwise a search icon for aired episodes. No
        // gradient backdrop — bare icons sit over the row's natural
        // tint (status fill for in-progress, transparent otherwise),
        // matching Mail / Music row-hover treatment.
        .overlay(alignment: .trailing) {
            let hasOverlay = (queueItem != nil) || (onSearch != nil && hasAired)
            if isHovering, hasOverlay {
                searchActionOverlay
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            hoverTask?.cancel()
            if hovering, hasTooltipContent {
                hoverTask = Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if !Task.isCancelled, self.isHovering { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .popover(isPresented: $showTooltip, arrowEdge: .leading) {
            EpisodeRowTooltip(
                episode: episode,
                queueItem: queueItem,
                episodeFile: episodeFile,
                seriesTitle: seriesTitle,
                seriesPosterURL: seriesPosterURL,
                seriesPosterRequiresAuth: seriesPosterRequiresAuth,
                seriesPosterAPIKey: seriesPosterAPIKey
            )
            .popoverBehavior(.applicationDefined)
        }
        #endif
        // Native macOS confirm sheet for destructive actions — same
        // pattern Apple uses across Finder / Mail / Photos. Replaces
        // the bespoke `InlineConfirmCard` popovers we had on the row.
        .confirmationDialog(
            Text("Search this episode?", bundle: .module),
            isPresented: $showSearchConfirm,
            titleVisibility: .visible
        ) {
            Button { performSearch() } label: { Text("Search", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Will query your indexers and start a download if a release matches.", bundle: .module)
        }
        .confirmationDialog(
            Text("Cancel this download?", bundle: .module),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let q = queueItem { onDeleteQueueItem?(q) }
            } label: { Text("Cancel download", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Keep download", bundle: .module) }
        } message: {
            Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), queueItem?.title ?? episode.title ?? ""))
        }
    }

    /// Hover overlay on the trailing edge — same gradient + icon
    /// language as QueueRowView. Content depends on state: when an
    /// active queue item is present, surface pause/resume/trash;
    /// otherwise (no queue), surface a search icon.
    #if os(macOS)
    /// Unified action cluster: primary icon (state-dependent) +
    /// optional ⋯ menu for secondary actions. No gradient, no pill, no
    /// inline label — same shape across queue rows, episode rows, and
    /// the detail surface. Destructive confirms use the native
    /// `.confirmationDialog` attached at the row level (see body).
    @ViewBuilder
    private var searchActionOverlay: some View {
        HStack(spacing: 2) {
            if let q = queueItem {
                queueActionIcons(for: q)
            } else if isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22, height: 22)
            } else {
                IconButton(symbol: "magnifyingglass", helpKey: "Search episode") {
                    showSearchConfirm = true
                }
            }
        }
        .rowActionBackdrop()
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func queueActionIcons(for q: QueueItem) -> some View {
        // Music/Podcasts pattern: primary action visible (pause/resume
        // — the toggle most-clicked), Remove tucked into `⋯` menu.
        // Single secondary action still gets the menu shell so the row
        // grammar stays consistent across surfaces.
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
            IconOverflowMenu(accessibilityLabel: "More actions") {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(String(localized: "Cancel download", bundle: .module),
                          systemImage: "trash")
                }
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
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.green)
        } else if !hasAired {
            Image(systemName: "calendar")
                .scaledFont(size: 10)
                .foregroundStyle(.tertiary)
                .help(Text("Not aired yet", bundle: .module))
        } else if episode.hasFile != true && queueItem == nil {
            // Missing-aired with no active download — the only state
            // that still warrants an indicator glyph. Downloading
            // episodes are now signalled by the row's background
            // tint (see `rowBackground`), not an icon.
            Image(systemName: "circle")
                .scaledFont(size: 10)
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
