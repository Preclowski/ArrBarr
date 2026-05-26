import SwiftUI

/// Detail view for a queue item — replaces the popover content while shown.
/// Fetches data from Radarr/Sonarr/Lidarr based on `item.entityId` and
/// `item.source`, then renders a service-specific layout.
public struct DetailView: View {
    let item: QueueItem
    let onBack: () -> Void
    /// Page title shown in the header — typically the name of the tab
    /// the user came from ("Kolejka", "Nadchodzące", "Czat", "Dodaj").
    /// Defaults to a generic "Details" if the caller doesn't pass one.
    /// Using a context label (where they came from) rather than the
    /// item title avoids title duplication with the hero card below.
    var originLabel: LocalizedStringKey = "Details"
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    public init(
        item: QueueItem,
        onBack: @escaping () -> Void,
        originLabel: LocalizedStringKey = "Details",
        viewModel: QueueViewModel
    ) {
        self.item = item
        self.onBack = onBack
        self.originLabel = originLabel
        self.viewModel = viewModel
    }

    /// All queue items belonging to the same arr entity (movie/series/album).
    /// One item → render the single-item form; multiple → stacked list with
    /// the originally-clicked row highlighted.
    private var siblings: [QueueItem] {
        let pool = viewModel.items(for: item.source)
        guard let id = item.entityId else { return [item] }
        let matched = pool.filter { $0.entityId == id }
        return matched.isEmpty ? [item] : matched
    }

    /// Fresh snapshot of `item` pulled from the live `viewModel.items`
    /// pool. The `item` passed into init is captured at open-time and
    /// stays static; `focused` re-reads on every view refresh so that
    /// status / progress / isPaused reflect the latest poll (and
    /// immediately after a Pause/Resume tap, the optimistic mutation
    /// the view model performs). CTA rendering must use this, not
    /// `item`, or the button label keeps saying "Pause download"
    /// after the user already paused.
    private var focused: QueueItem {
        viewModel.items(for: item.source)
            .first { $0.id == item.id || $0.arrQueueId == item.arrQueueId }
            ?? item
    }

    /// True when at least one sibling is a real queue row (non-zero arrQueueId).
    /// `false` means this view was opened from a synthetic lookup item (chat
    /// card / upcoming row tap) and there's nothing to download right now —
    /// rendering a 0%/Unknown progress bar would be misleading.
    private var hasActiveDownloads: Bool {
        siblings.contains { $0.arrQueueId != 0 }
    }

    @State private var radarrDetail: RadarrMovieDetail?
    /// Separately-fetched movie file. Radarr's `/movie/{id}` returns a
    /// stripped `movieFile` payload (no customFormats), so we hit
    /// `/moviefile?movieId={id}` afterwards to get the chip-bearing
    /// version for the ExistingFileBanner.
    @State private var radarrMovieFile: ArrFile?
    @State private var sonarrDetail: SonarrSeriesDetail?
    @State private var sonarrEpisodes: [SonarrEpisodeDetail] = []
    /// `episodeFileId → file` map for the whole series. Fetched alongside
    /// `sonarrEpisodes` so downloaded `EpisodeRow`s can render their
    /// custom-format score in the right gutter instead of falling back to
    /// the air date — the score is the actionable info once an episode is
    /// on disk.
    @State private var sonarrEpisodeFiles: [Int: SonarrEpisodeFile] = [:]
    @State private var lidarrAlbum: LidarrAlbumDetail?
    @State private var lidarrTracks: [LidarrTrackDetail] = []
    @State private var loading = true
    @State private var loadError: String?

    /// Poster lightbox — set to a URL when the user taps the header
    /// card's poster, cleared by the xmark button. Renders as an
    /// overlay on top of the detail surface so it dismisses without
    /// leaving the popover.
    @State private var enlargedPoster: URL?
    /// Episode drill-down — set when the user taps a row in a season's
    /// expanded list. Renders `EpisodeDetailOverlay` on top of the
    /// series detail.
    @State private var selectedEpisode: SonarrEpisodeDetail?
    /// Lazily-fetched episode-file payload. Driven off
    /// Currently-shown season number for Sonarr detail. Drives the
    /// pill bar — only one season's episode list is rendered at a
    /// time. `nil` means "no explicit pick yet", which the view
    /// resolves to the latest season (or the first with unaired
    /// missing episodes — that's where the user usually wants to
    /// land).
    @State private var selectedSeasonNumber: Int?

    /// Currently-shown disc number for Lidarr multi-disc albums.
    /// Mirrors `selectedSeasonNumber` — drives the disc pill bar,
    /// only one disc's track list is rendered at a time. `nil` =
    /// pick the first disc with missing tracks (or the lowest disc
    /// number if everything's on disk).
    @State private var selectedDiscNumber: Int?

    // MARK: - Download action gating
    //
    // Mirrors QueueRowView.canControl / canPauseResume so the detail
    // view's action buttons appear under the exact same conditions as
    // the tooltip's: only when there's a configured download client for
    // the item's protocol, and only Pause/Resume when the focused item
    // is actually in a download-or-paused state.
    private var canControl: Bool {
        switch item.downloadProtocol {
        case .usenet:
            return (configStore.sabnzbd.isConfigured && !configStore.sabnzbd.apiKey.isEmpty)
                || configStore.nzbget.isConfigured
        case .torrent:
            return configStore.qbittorrent.isConfigured
                || configStore.transmission.isConfigured
                || configStore.rtorrent.isConfigured
                || configStore.deluge.isConfigured
        case .unknown:
            return false
        }
    }

    private var canPauseResume: Bool {
        let s = focused.status
        return s == .downloading || s == .paused
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    content
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                // Sticky CTA strip pinned at the bottom of the detail
                // surface. `safeAreaInset` is Apple's canonical pattern
                // for "bar that doesn't overlap scroll content" — the
                // ScrollView gets padded automatically so nothing's
                // hidden behind. Only renders when there's a
                // controllable active download (see `downloadCTAStrip`).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    let hasCTA = (hasActiveDownloads && canControl)
                        || arrWebURL(for: item, in: configStore) != nil
                    if hasCTA {
                        downloadCTAStrip
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                Rectangle()
                                    .fill(.thinMaterial)
                                    .overlay(alignment: .top) {
                                        Divider().opacity(0.4)
                                    }
                                    .ignoresSafeArea(edges: .bottom)
                            )
                    }
                }
            }
            // Hide the series detail when an overlay is active so we
            // don't need a solid scrim on top — the popover's
            // translucent chrome stays visible (Apple "Liquid Glass"
            // feel), the user just sees the focused view.
            .opacity((selectedEpisode != nil || enlargedPoster != nil) ? 0 : 1)
            .allowsHitTesting(selectedEpisode == nil && enlargedPoster == nil)
            .onAppear {
                // Seed the pill bar with the *clicked* queue item's
                // season when the user drilled in from a season-3
                // episode in queue — opening to a different season
                // would leave them hunting for the one they just
                // clicked.
                if selectedSeasonNumber == nil, let sn = item.seasonNumber, sn > 0 {
                    selectedSeasonNumber = sn
                }
            }

            // Episode drill-down. Layered above the series detail so
            // it covers the back chevron / source pill / overview —
            // the user sees a focused episode surface, dismisses with
            // its own back button to return to the series.
            if let ep = selectedEpisode {
                let activeQueueItem = siblings.first {
                    $0.seasonNumber == ep.seasonNumber
                        && $0.episodeNumber == ep.episodeNumber
                        && $0.arrQueueId != 0
                }
                EpisodeDetailOverlay(
                    episode: ep,
                    seriesTitle: sonarrDetail?.title ?? item.title,
                    originLabel: originLabel,
                    posterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth,
                    apiKey: configStore.sonarr.apiKey,
                    episodeFile: ep.episodeFileId.flatMap { sonarrEpisodeFiles[$0] },
                    queueItem: activeQueueItem,
                    onPosterTap: { url in
                        withAnimation(.smooth(duration: 0.22)) {
                            enlargedPoster = url ?? item.posterURL
                        }
                    },
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) {
                            selectedEpisode = nil
                        }
                    },
                    onSearch: searchEpisodeClosure,
                    warningActionURL: activeQueueItem.flatMap { arrWebURL(for: $0, in: configStore) },
                    onPauseEpisode: { q in Task { await viewModel.pause(q) } },
                    onResumeEpisode: { q in Task { await viewModel.resume(q) } },
                    onDeleteEpisode: { q in Task { await viewModel.delete(q) } }
                )
                .transition(.opacity)
            }

            // Poster lightbox — rendered LAST in the ZStack so it
            // sits on top of every other overlay (series detail AND
            // episode overlay). User can tap an episode-detail
            // poster and the lightbox covers the episode view.
            if let url = enlargedPoster {
                posterLightbox(url: url)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
    }

    /// Content-type title — "Movie details" / "Series details" /
    /// "Album details". Replaces the prior origin-tab label because
    /// the user already knows which tab they came from; the question
    /// answered here is "what *is* this surface". Whisparr piggybacks
    /// on the Radarr layout so it shares the movie copy. Pause /
    /// Resume / Remove are NOT folded into this title anymore —
    /// post-review they live inline next to `ProgressLine` (Music
    /// "now playing" pattern, see `DownloadSection.inlineActions`).
    private var detailTitleKey: LocalizedStringKey {
        switch item.source {
        case .radarr, .whisparr: return "Movie details"
        case .sonarr:            return "Series details"
        case .lidarr:            return "Album details"
        }
    }

    // MARK: - Header (floating glass back + source info)

    private var header: some View {
        // Title is now the *content type* (Movie / Series / Album
        // details) rather than the origin tab — the user already knows
        // which tab they came from, what they don't yet know is what
        // this surface *is*. When there's an actionable download, the
        // title doubles as the overflow menu (▾ indicator + Apple
        // dropdown-title pattern from Finder / Safari): one tap opens
        // Pause/Resume/Remove. No actionable download → plain text.
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)

            Text(detailTitleKey, bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Image(systemName: item.source.symbol)
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
            Text(item.source.displayName)
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)

            // Header is plain — back + title + source tag. Every
            // action (Safari, Pause/Resume, Cancel) lives in the
            // sticky bottom CTA strip (`downloadCTAStrip`), so the
            // toolbar reads as one coherent surface instead of
            // splitting affordances across two ends of the popover.
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Download CTA strip
    //
    // Prominent action row rendered under `DownloadSection` for the
    // focused queue item. Music/App-Store album-detail pattern: one
    // big primary CTA (Pause/Resume — the toggle 90% of clicks hit),
    // a small destructive secondary (Cancel — bordered, red-tinted
    // glyph, native `.confirmationDialog`), and an external link
    // (Open in browser) for the long-tail "let me deal with this in
    // the arr's own UI" case. Only renders when there's something to
    // control AND a configured download client.
    @State private var ctaPendingDelete = false
    /// Flips on while a Pause/Resume tap is in flight. The button
    /// shows a spinner + disables itself until the request returns
    /// AND `viewModel.refresh()` pulls the fresh status — only then
    /// does the CTA flip colour/label, so users don't see a stale
    /// "Pause" sitting on a paused item.
    @State private var ctaInFlight = false

    @ViewBuilder
    private var downloadCTAStrip: some View {
        let hasDownloadControls = hasActiveDownloads && canControl
        let url = arrWebURL(for: item, in: configStore)
        if hasDownloadControls || url != nil {
            // Strip always promotes exactly one action to the prominent
            // full-width slot. Destructive actions never lead — Cancel
            // is always a secondary, since promoting "remove" to the
            // primary CTA reads as "the page wants you to delete this".
            // Priority: pause/resume → safari → cancel (last resort,
            // only when no pause/resume AND no URL, otherwise the
            // strip would have no leader at all).
            HStack(spacing: 8) {
                if hasDownloadControls, canPauseResume {
                    pauseResumeProminent
                    cancelSecondary
                    if let url { safariSecondary(url: url) }
                } else if let url {
                    safariProminent(url: url)
                    if hasDownloadControls { cancelSecondary }
                } else if hasDownloadControls {
                    // No URL AND no pause/resume — Cancel is the only
                    // affordance left, so it has to lead. Edge case.
                    cancelProminent
                }
            }
            .confirmationDialog(
                Text("Cancel this download?", bundle: .module),
                isPresented: $ctaPendingDelete,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    Task {
                        await viewModel.delete(item)
                        await MainActor.run { onBack() }
                    }
                } label: { Text("Cancel download", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Keep download", bundle: .module) }
            } message: {
                Text(String(format: String(localized: "This will remove \"%@\" from the download client.", bundle: .module), item.title))
            }
        }
    }

    // MARK: - CTA strip sub-views
    //
    // Two flavours per action: `*Prominent` for the leading full-width
    // CTA, `*Secondary` for the small bordered square that sits next
    // to a prominent sibling. Same chat-add shape (GlassProminent,
    // .padding(.vertical, 7), maxWidth infinity) for every prominent
    // variant — the strip stays visually consistent no matter which
    // action got promoted.

    @ViewBuilder
    private var pauseResumeProminent: some View {
        let f = focused
        Button {
            guard !ctaInFlight else { return }
            Task {
                ctaInFlight = true
                if f.isPaused {
                    await viewModel.resume(f)
                } else {
                    await viewModel.pause(f)
                }
                // Force a queue poll so the status flip lands in
                // `viewModel.items` before we release the spinner —
                // otherwise the button reverts to the old label for
                // a couple seconds until the next scheduled refresh.
                await viewModel.refresh()
                ctaInFlight = false
            }
        } label: {
            HStack(spacing: 6) {
                if ctaInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: f.isPaused ? "play.fill" : "pause.fill")
                        .scaledFont(size: 11, weight: .semibold)
                    Text(f.isPaused
                            ? String(localized: "Resume download", bundle: .module)
                            : String(localized: "Pause download", bundle: .module))
                        .scaledFont(size: 12, weight: .semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .disabled(ctaInFlight)
        .tint(f.status.tint)
        .progressFillCTA(
            progress: f.source == .sonarr ? 1 : f.progress,
            tint: f.status.tint
        )
        .modifier(GlassProminentButtonStyle())
    }

    @ViewBuilder
    private var cancelProminent: some View {
        Button {
            ctaPendingDelete = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Cancel download", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
    }

    @ViewBuilder
    private var cancelSecondary: some View {
        Button {
            ctaPendingDelete = true
        } label: {
            Image(systemName: "trash")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .help(Text("Cancel download", bundle: .module))
    }

    @ViewBuilder
    private func safariProminent(url: URL) -> some View {
        Button {
            PlatformURLOpener.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Open in browser", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .help(Text("Open in browser", bundle: .module))
    }

    @ViewBuilder
    private func safariSecondary(url: URL) -> some View {
        Button {
            PlatformURLOpener.open(url)
        } label: {
            Image(systemName: "safari")
                .scaledFont(size: 13, weight: .medium)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .help(Text("Open in browser", bundle: .module))
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 60)
        } else {
            switch item.source {
            case .radarr, .whisparr:
                let movieHeader = AnyView(
                    headerCard(
                        title: radarrDetail?.title ?? item.title,
                        year: radarrDetail?.year,
                        runtime: radarrDetail?.runtime,
                        genres: radarrDetail?.genres ?? [],
                        certification: radarrDetail?.certification,
                        ratings: movieRatingChipsFor(radarrDetail),
                        // Upgrade badge now lives inline next to the title (via
                        // `titleBadge`). Trailing slot is empty for movies; the
                        // download client / score have their own gutter inside
                        // the download section.
                        existingTrailer: nil,
                        posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore),
                        fallbackSymbol: "film",
                        posterAspect: 2.0/3.0
                    )
                )
                RadarrDetailPanel(
                    item: item,
                    viewModel: viewModel,
                    radarrDetail: radarrDetail,
                    radarrMovieFile: radarrMovieFile,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    header: movieHeader,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) }
                )
            case .sonarr:            sonarrContent
            case .lidarr:
                LidarrDetailPanel(
                    item: item,
                    viewModel: viewModel,
                    lidarrAlbum: lidarrAlbum,
                    lidarrTracks: lidarrTracks,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    enlargedPoster: $enlargedPoster,
                    selectedDiscNumber: $selectedDiscNumber,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) }
                )
            }
        }
    }

    private func movieRatingChipsFor(_ detail: RadarrMovieDetail?) -> [RatingChip] {
        guard let r = detail?.ratings else { return [] }
        var chips: [RatingChip] = []
        if let v = r.imdb?.value { chips.append(RatingChip(label: "IMDb", value: String(format: "%.1f", v), color: .yellow)) }
        if let v = r.tmdb?.value { chips.append(RatingChip(label: "TMDB", value: String(format: "%.1f", v), color: .teal)) }
        if let v = r.rottenTomatoes?.value { chips.append(RatingChip(label: "RT", value: "\(Int(v))%", color: .red)) }
        if let v = r.metacritic?.value { chips.append(RatingChip(label: "MC", value: "\(Int(v))", color: .green)) }
        return chips
    }

    // MARK: - Sonarr

    @ViewBuilder
    private var sonarrContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard(
                title: sonarrDetail?.title ?? item.title,
                year: sonarrDetail?.year,
                runtime: sonarrDetail?.runtime,
                genres: sonarrDetail?.genres ?? [],
                certification: sonarrDetail?.network,
                ratings: sonarrRatingChips,
                existingTrailer: nil,
                posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore),
                fallbackSymbol: "tv",
                posterAspect: 2.0/3.0
            )

            if let overview = sonarrDetail?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            if let seasons = sonarrDetail?.seasons {
                let visibleSeasons = seasons.filter { $0.seasonNumber > 0 }
                if !visibleSeasons.isEmpty {
                    seasonsHeader(seasons: visibleSeasons)
                    seasonPillBar(visibleSeasons)
                    if let active = visibleSeasons.first(where: { $0.seasonNumber == effectiveSeasonNumber(in: visibleSeasons) }) {
                        SeasonRow(
                            season: active,
                            episodes: sonarrEpisodes.filter { $0.seasonNumber == active.seasonNumber },
                            queueByEpisodeId: queueByEpisodeId,
                            fileByEpisodeFileId: sonarrEpisodeFiles,
                            onSearchSeason: searchSeasonClosure(seasonNumber: active.seasonNumber),
                            onSearchEpisode: searchEpisodeClosure,
                            onTapEpisode: { ep in
                                withAnimation(.smooth(duration: 0.22)) { selectedEpisode = ep }
                            },
                            onPauseEpisode: { q in
                                Task { await viewModel.pause(q) }
                            },
                            onResumeEpisode: { q in
                                Task { await viewModel.resume(q) }
                            },
                            onDeleteEpisode: { q in
                                Task { await viewModel.delete(q) }
                            },
                            onSetMonitored: setSeasonMonitoredClosure(seasonNumber: active.seasonNumber),
                            initiallyExpanded: true,
                            hideExpandChevron: true,
                            seriesTitle: sonarrDetail?.title ?? item.title,
                            seriesPosterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
                            seriesPosterRequiresAuth: item.posterRequiresAuth,
                            seriesPosterAPIKey: configStore.sonarr.apiKey
                        )
                    }
                }
            }
            // DownloadSection used to live here for series — the
            // separate "w kolejce" list with all active episode
            // downloads. Removed: each in-progress episode is now
            // marked inline (status dot on the row + hover actions
            // for pause/resume/remove), and the season pill carries
            // a "currently downloading" indicator so the user can
            // jump to the right season without scrolling a parallel
            // list. One source of truth per episode = fewer surfaces
            // for the action buttons to land out of reach.

            if let err = loadError {
                Text(err)
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Resolves the `SonarrEpisodeDetail` that matches a queue item's
    /// season/episode and pushes the episode overlay. Called from
    /// EpisodeRow's hover-icon click → drill into the episode view.
    /// If no matching episode is in `sonarrEpisodes` yet (timing
    /// window — series detail finished loading before episodes), we
    /// just no-op rather than open a half-populated view.
    private func openEpisodeFromQueueItem(_ q: QueueItem) {
        guard let sn = q.seasonNumber, let en = q.episodeNumber else { return }
        guard let ep = sonarrEpisodes.first(where: {
            $0.seasonNumber == sn && $0.episodeNumber == en
        }) else { return }
        withAnimation(.smooth(duration: 0.22)) { selectedEpisode = ep }
    }

    /// Map episode-id → active queue item, built from `siblings`
    /// (queue items for this series) joined to the loaded
    /// `sonarrEpisodes`. Powers the per-episode in-progress
    /// indicator + hover action icons that replaced the standalone
    /// "in queue" list.
    private var queueByEpisodeId: [Int: QueueItem] {
        var map: [Int: QueueItem] = [:]
        for q in siblings where q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let ep = sonarrEpisodes.first(where: {
                $0.seasonNumber == sn && $0.episodeNumber == en
            }) {
                map[ep.id] = q
            }
        }
        return map
    }

    /// Dominant queue status across all in-flight episodes for a
    /// season. Priority: downloading > paused > other. Drives the
    /// season-pill colour dot so it matches the actual state of the
    /// episodes inside (blue dot on a season full of paused episodes
    /// used to be a UX lie).
    private func dominantQueueStatus(forSeason sn: Int) -> QueueItem.Status? {
        let inSeason = siblings.filter {
            $0.seasonNumber == sn && $0.arrQueueId != 0
        }
        guard !inSeason.isEmpty else { return nil }
        if inSeason.contains(where: { $0.status == .downloading }) { return .downloading }
        if inSeason.contains(where: { $0.status == .paused }) { return .paused }
        return inSeason.first?.status
    }

    /// Wrapping pill-row of season selectors. Replaces the legacy
    /// vertical list of expandable SeasonRows — only one season's
    /// content is visible at a time, the pill bar is the navigation.
    @ViewBuilder
    private func seasonPillBar(_ seasons: [SonarrSeasonInfo]) -> some View {
        let activeNumber = effectiveSeasonNumber(in: seasons)
        TooltipFlowLayout(spacing: 6) {
            ForEach(seasons, id: \.seasonNumber) { season in
                seasonPill(season, isActive: season.seasonNumber == activeNumber)
            }
        }
    }

    @ViewBuilder
    private func seasonPill(_ season: SonarrSeasonInfo, isActive: Bool) -> some View {
        let have = season.statistics?.episodeFileCount ?? 0
        let total = season.statistics?.totalEpisodeCount ?? season.statistics?.episodeCount ?? 0
        let complete = total > 0 && have >= total
        let queueStatus = dominantQueueStatus(forSeason: season.seasonNumber)
        Button {
            withAnimation(.smooth(duration: 0.2)) {
                selectedSeasonNumber = season.seasonNumber
            }
        } label: {
            HStack(spacing: 4) {
                Text(String(format: String(localized: "Season pill %lld", bundle: .module), season.seasonNumber))
                    .scaledFont(size: 10, weight: isActive ? .semibold : .medium)
                    .foregroundStyle(isActive ? .primary : .secondary)
                // Dot colour reflects what the user will see when
                // they open the season: blue if anything's actively
                // downloading, orange if everything's paused, green
                // when the season is complete and idle. No dot when
                // partial + nothing in queue (still missing).
                if let s = queueStatus {
                    Circle()
                        .fill(isActive ? s.tint : s.tint.opacity(0.75))
                        .frame(width: 4, height: 4)
                } else if complete {
                    Circle()
                        .fill(isActive ? Color.green : Color.green.opacity(0.7))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.primary.opacity(isActive ? 0 : 0.18),
                        lineWidth: 0.6
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Resolves which season's content to show. User explicit pick
    /// wins; otherwise default to the first season with aired
    /// missing episodes (where the user is most likely heading);
    /// fall back to the latest season.
    private func effectiveSeasonNumber(in seasons: [SonarrSeasonInfo]) -> Int? {
        if let picked = selectedSeasonNumber,
           seasons.contains(where: { $0.seasonNumber == picked }) {
            return picked
        }
        // First season with at least one aired-but-missing episode.
        let now = Date()
        if let firstMissing = seasons.first(where: { season in
            sonarrEpisodes.contains { ep in
                guard ep.seasonNumber == season.seasonNumber else { return false }
                let aired = ep.airDateUtc.flatMap(parseArrDate).map { $0 <= now } ?? true
                return aired && ep.hasFile != true
            }
        }) {
            return firstMissing.seasonNumber
        }
        // Otherwise the latest season — most users want "what's
        // happening now" rather than the back catalogue.
        return seasons.max(by: { $0.seasonNumber < $1.seasonNumber })?.seasonNumber
    }

    // MARK: - Sonarr search-missing affordances

    /// Total *aired* missing episodes across non-special seasons. Drives
    /// the "Search all N missing" pill visibility. We use episode-level
    /// Section header for the seasons list. Series-wide "search whole
    /// series" affordance lived here briefly; pulled per UX feedback
    /// because per-season searches already let the user pick exactly
    /// which season to grab and the rollup added an ambiguous count.
    @ViewBuilder
    private func seasonsHeader(seasons: [SonarrSeasonInfo]) -> some View {
        HStack(spacing: 8) {
            Text("Seasons", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

    private func searchSeasonClosure(seasonNumber: Int) -> (() async -> Void)? {
        guard let seriesId = item.entityId else { return nil }
        return {
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
        }
    }

    private var searchEpisodeClosure: ((Int) async -> Void)? {
        // Series itself doesn't gate this — episode rows already only
        // show their button when an episode is missing.
        { episodeId in
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.searchEpisodes(episodeIds: [episodeId])
        }
    }

    /// Closure that flips season monitoring via Sonarr's `/seasonpass`
    /// endpoint. The SeasonRow drives optimistic UI locally; on server
    /// success we refresh `sonarrDetail` so the next read reconciles
    /// state (also brings in any side-effects, e.g. Sonarr's
    /// monitorNewItems policy auto-monitoring siblings).
    private func setSeasonMonitoredClosure(seasonNumber: Int) -> ((Bool) async -> Void)? {
        guard let seriesId = item.entityId else { return nil }
        return { state in
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.setSeasonMonitored(
                seriesId: seriesId,
                seasonNumber: seasonNumber,
                monitored: state
            )
            // Refresh series detail so future paints see the true state
            // from the server (covers any auto-mark policies Sonarr ran).
            if let refreshed = try? await client.fetchSeriesDetails(id: seriesId) {
                await MainActor.run { self.sonarrDetail = refreshed }
            }
        }
    }

    private var sonarrRatingChips: [RatingChip] {
        guard let r = sonarrDetail?.ratings, let v = r.value else { return [] }
        return [RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow)]
    }

    // MARK: - Shared header card

    @ViewBuilder
    private func headerCard(
        title: String,
        year: Int?,
        runtime: Int?,
        genres: [String],
        certification: String?,
        ratings: [RatingChip],
        /// Anything that should sit in the header's right column under the
        /// rating chips. Used for the listing badges (Upgrade/New + download
        /// client) on movie rows. `nil` leaves the area empty.
        existingTrailer: AnyView?,
        posterUrl: URL?,
        fallbackSymbol: String,
        posterAspect: CGFloat
    ) -> some View {
        MediaHeaderCard(
            title: title,
            year: year,
            runtime: runtime,
            network: nil,
            certification: certification,
            genres: genres,
            ratings: ratings,
            posterURL: posterUrl ?? item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: arrAPIKey(for: item, in: configStore),
            fallbackSymbol: fallbackSymbol,
            posterAspect: posterAspect,
            blurred: configStore.shouldBlurPoster(for: item.source),
            trailing: existingTrailer,
            titleBadge: hasActiveDownloads ? AnyView(titleBadges) : nil,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = url ?? item.posterURL
                }
            }
        )
    }

    /// Full-popover poster preview — delegates to the shared
    /// `PosterLightbox` so DetailView and SearchAddPanel render the
    /// same chrome (frosted scrim + Apple xmark + tap-anywhere
    /// dismiss).
    @ViewBuilder
    private func posterLightbox(url: URL) -> some View {
        PosterLightbox(
            url: url,
            apiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil,
            aspectRatio: item.source == .lidarr ? 1.0 : 2.0 / 3.0,
            onDismiss: { dismissPoster() }
        )
    }

    private func dismissPoster() {
        withAnimation(.smooth(duration: 0.22)) {
            enlargedPoster = nil
        }
    }

    /// Title-adjacent badge cluster. See `MediaBadgeCluster`.
    @ViewBuilder
    private var titleBadges: some View {
        MediaBadgeCluster(isUpgrade: item.isUpgrade, size: .medium)
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        guard let entityId = item.entityId else {
            loadError = "No entity id"
            return
        }
        do {
            switch item.source {
            case .radarr:
                let client = RadarrClient(config: configStore.radarr)
                async let detail = client.fetchMovieDetails(id: entityId)
                // Movie-file is fetched separately because /movie/{id}
                // doesn't include customFormats on the inline movieFile
                // payload — only /moviefile?movieId={id} does. Run it
                // in parallel with the main detail call; if it fails
                // (older Radarr, network blip), the inline movieFile
                // from the detail still backs the banner.
                async let file = (try? client.fetchMovieFile(movieId: entityId)) ?? nil
                radarrDetail = try await detail
                radarrMovieFile = await file
            case .sonarr:
                let client = SonarrClient(config: configStore.sonarr)
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                async let files = (try? client.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                sonarrDetail = try await d
                sonarrEpisodes = try await eps
                sonarrEpisodeFiles = await files
                // Auto-drill straight to the episode overlay when
                // the incoming queue item identifies a specific
                // episode. Clicking "Foo S02E04" in queue should
                // land on that episode's detail, not the series
                // splash — the user already picked a specific row.
                if selectedEpisode == nil,
                   let sn = item.seasonNumber, sn > 0,
                   let en = item.episodeNumber,
                   let ep = sonarrEpisodes.first(where: {
                       $0.seasonNumber == sn && $0.episodeNumber == en
                   }) {
                    selectedEpisode = ep
                }
            case .lidarr:
                let client = LidarrClient(config: configStore.lidarr)
                async let a = client.fetchAlbumDetails(id: entityId)
                async let ts = client.fetchTracks(albumId: entityId)
                lidarrAlbum = try await a
                lidarrTracks = try await ts
            case .whisparr:
                let client = WhisparrClient(config: configStore.whisparr)
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
            }
        } catch {
            loadError = "Couldn't load details: \(error.localizedDescription)"
        }
    }
}
