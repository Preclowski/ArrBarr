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
    /// When `true` (default — legacy behaviour) and the item carries an
    /// episodeNumber, `load()` auto-pushes the matching episode via
    /// `selectedEpisode`. The new EpisodeQuickDetail flow disables this
    /// when DetailView is pushed from the episode hero's series-tap
    /// (user already saw the episode and explicitly asked for the
    /// series), otherwise we'd bounce them right back to the episode.
    var autoDrillToEpisode: Bool = true
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    public init(
        item: QueueItem,
        onBack: @escaping () -> Void,
        originLabel: LocalizedStringKey = "Details",
        autoDrillToEpisode: Bool = true,
        viewModel: QueueViewModel
    ) {
        self.item = item
        self.onBack = onBack
        self.originLabel = originLabel
        self.autoDrillToEpisode = autoDrillToEpisode
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
    /// Cast strip. Movies pull from Radarr's `/credit` (no key needed);
    /// series from TMDB (Sonarr has no cast endpoint) and only when a TMDB
    /// key is set. Empty = unavailable; the row just doesn't render.
    @State private var cast: [CastMember] = []
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
    /// Auto-drill fires exactly once per detail instance. Without this,
    /// popping back from the episode re-runs the drill (selectedEpisode is
    /// nil again) and the episode immediately re-pushes — trapping the user
    /// so they can never reach the series view / queue.
    @State private var didAutoDrill = false
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
                    // Strip only renders when pause/resume is actionable —
                    // Trash and Safari live in the toolbar now, so the
                    // bar would otherwise be empty.
                    let hasCTA = hasActiveDownloads && canControl && canPauseResume
                    if hasCTA {
                        // Floating CTA — no material backdrop / divider
                        // so the glass pill reads as an island on top of
                        // the content (chat-input pattern).
                        downloadCTAStrip
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // Lightbox still gets the overlay treatment — it's a transient
            // zoom-in, not a navigation level. Episode drill-down moved
            // to a NavigationStack push (see `.navigationDestination`
            // below) so the system renders `<` + series title for free.
            .opacity(enlargedPoster != nil ? 0 : 1)
            .allowsHitTesting(enlargedPoster == nil)
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

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Full-screen poster: iOS covers all chrome (no header/back, tap to
        // close); macOS overlays inside the popover.
        .posterLightbox(
            url: $enlargedPoster,
            apiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil,
            aspectRatio: item.source == .lidarr ? 1.0 : 2.0 / 3.0
        )
        .task(id: item.id) { await load() }
        // Secondary actions live in the system toolbar — destructive
        // cancel + open-in-browser. Primary action (pause/resume) stays
        // on the sticky bottom CTA so the main verb sits under the
        // thumb / cursor where users expect it.
        // Trash + Safari go in the trailing toolbar cluster. Upgrade/New
        // badge stays in the hero (see headerCard's titleBadge param)
        // because macOS NavigationStack toolbar refuses to render non-
        // interactive views — we ran the experiment three times.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = arrWebURL(for: item, in: configStore) {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help(Text("Open in browser", bundle: .module))
                }
                // iOS keeps delete in the toolbar (to the RIGHT of Safari).
                // macOS surfaces it next to the Resume CTA instead.
                #if os(iOS)
                if hasActiveDownloads && canControl {
                    Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                    .help(Text("Cancel download", bundle: .module))
                }
                #endif
            }
        }
        // Toolbar title carries the *item* identity — title + year —
        // instead of the generic source name, so the user always sees
        // what they're looking at in the chevron header. The hero card
        // below drops its own title/year duplication to stay clean.
        .navigationTitle(navTitleString)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Episode drill-down — push EpisodeDetailOverlay as another
        // NavigationStack level so the user gets a native `< Sonarr`
        // back chevron and the series view is visibly waiting below.
        .navigationDestination(item: $selectedEpisode) { ep in
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
                onClose: { selectedEpisode = nil },
                onSearch: { episodeId in
                    let client = SonarrClient(config: configStore.sonarr)
                    try? await client.searchEpisodes(episodeIds: [episodeId])
                },
                warningActionURL: activeQueueItem.flatMap { arrWebURL(for: $0, in: configStore) },
                // Gate pause/resume/delete on a configured download client —
                // same rule the movie CTA uses. Without it the episode would
                // show a Resume button that can't actually do anything.
                onPauseEpisode: canControl ? { q in Task { await viewModel.pause(q) } } : nil,
                onResumeEpisode: canControl ? { q in Task { await viewModel.resume(q) } } : nil,
                onDeleteEpisode: canControl ? { q in Task { await viewModel.delete(q) } } : nil,
                seriesYear: sonarrDetail?.year ?? splitTitleAndYear(item.title).year
            )
        }
        // Inline confirmation — replaces `.confirmationDialog` because
        // the system dialog steals focus from MenuBarExtra(.window),
        // which auto-dismisses the panel. The inline overlay renders
        // inside the panel so the panel keeps focus.
        .inlineConfirm(
            isPresented: $ctaPendingDelete,
            title: "Cancel this download?",
            message: LocalizedStringKey("This will remove the download from the client."),
            confirmLabel: "Cancel download",
            cancelLabel: "Keep download",
            isDestructive: true,
            onConfirm: {
                Task {
                    await viewModel.delete(item)
                    await MainActor.run { onBack() }
                }
            }
        )
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

    /// Item-level title for the system toolbar — "{title} ({year})" when
    /// year is known, otherwise just title. Falls back to the queue-row
    /// title (which already includes "(YYYY)" most of the time) until
    /// the arr fetch lands.
    private var navTitleString: String {
        let fallback = splitTitleAndYear(item.title)
        let title: String
        let year: Int?
        switch item.source {
        case .radarr, .whisparr:
            title = radarrDetail?.title ?? fallback.title
            year = radarrDetail?.year ?? fallback.year
        case .sonarr:
            title = sonarrDetail?.title ?? fallback.title
            year = sonarrDetail?.year ?? fallback.year
        case .lidarr:
            title = lidarrAlbum?.title ?? fallback.title
            year = fallback.year
        }
        if let year { return "\(title) (\(year))" }
        return title
    }

    // MARK: - Header (floating glass back + source info)

    private var header: some View {
        // Inline header removed in the MenuBarExtra(.window) migration —
        // both macOS popover (now window-backed) and iOS push DetailView
        // into a NavigationStack, so the system renders `<` + title for
        // us. Source identity lives in `.navigationTitle(...)` on body.
        // Kept as `EmptyView` rather than deleted so the call site in
        // body's VStack doesn't have to be touched.
        EmptyView()
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

    @ViewBuilder
    private var downloadCTAStrip: some View {
        let hasDownloadControls = hasActiveDownloads && canControl
        // Bottom strip is now reserved for the single primary action
        // (pause/resume). Trash + Safari moved to the toolbar so this
        // bar reads as "the verb" rather than a strip of competing
        // affordances. When there's no pause/resume to surface, the
        // strip collapses and the toolbar carries the whole load.
        if hasDownloadControls, canPauseResume {
            HStack(spacing: 8) {
                pauseResumeProminent
                #if os(macOS)
                // macOS: delete sits next to Resume as a matching glass
                // capsule. iOS keeps delete in the nav toolbar instead.
                cancelGlassCompact
                #endif
            }
            // Inline-confirm attached to body instead of here so the
            // overlay fires regardless of whether the bottom CTA strip
            // is visible — toolbar trash button uses the same
            // `ctaPendingDelete` state.
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
        PauseResumeButton(
            isPaused: f.isPaused,
            progress: f.source == .sonarr ? 1 : f.progress,
            tint: f.status.tint
        ) {
            if f.isPaused {
                await viewModel.resume(f)
            } else {
                await viewModel.pause(f)
            }
            // Force a queue poll so the status flip lands in
            // `viewModel.items` before the button releases its spinner —
            // otherwise the label reverts to the old state for a couple
            // seconds until the next scheduled refresh.
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private var cancelProminent: some View {
        Button {
            PanelActivation.bringForward(); ctaPendingDelete = true
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

    #if os(macOS)
    /// Compact glass-capsule trash that matches the Resume/Pause CTA shape
    /// (same height + capsule + glass), so the two read as a pair instead of
    /// a round button next to a square one.
    @ViewBuilder
    private var cancelGlassCompact: some View {
        Button {
            PanelActivation.bringForward(); ctaPendingDelete = true
        } label: {
            Image(systemName: "trash")
                .scaledFont(size: 12, weight: .semibold)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .liquidGlassProgressCTA(progress: 0, tint: .red)
        .help(Text("Cancel download", bundle: .module))
        .accessibilityLabel(Text("Cancel download", bundle: .module))
    }
    #endif

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
        .accessibilityLabel(Text("Open in browser", bundle: .module))
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
                let titleFallback = splitTitleAndYear(item.title)
                let movieHeader = headerCard(
                    title: radarrDetail?.title ?? titleFallback.title,
                    year: radarrDetail?.year ?? titleFallback.year,
                    runtime: radarrDetail?.runtime,
                    genres: radarrDetail?.genres ?? [],
                    certification: radarrDetail?.certification,
                    ratings: movieRatingChipsFor(radarrDetail),
                    overview: radarrDetail?.overview,
                    // Upgrade badge now lives inline next to the title (via
                    // `titleBadge`). Trailing slot is empty for movies; the
                    // download client / score have their own gutter inside
                    // the download section.
                    existingTrailer: nil,
                    posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore),
                    fallbackSymbol: "film",
                    posterAspect: 2.0/3.0
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
                    cast: cast,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) }
                )
            case .sonarr:
                // While an episode is pushed (incl. the auto-drill from a queue
                // tap), keep the series body a spinner so the season list
                // doesn't flash behind the push. Back from the episode clears
                // `selectedEpisode` → the season view renders.
                if selectedEpisode != nil {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 60)
                } else {
                    let titleFallback = splitTitleAndYear(item.title)
                    let seriesHeader = headerCard(
                        title: sonarrDetail?.title ?? titleFallback.title,
                        year: sonarrDetail?.year ?? titleFallback.year,
                        runtime: sonarrDetail?.runtime,
                        genres: sonarrDetail?.genres ?? [],
                        certification: sonarrDetail?.network,
                        ratings: sonarrRatingChipsFor(sonarrDetail),
                        overview: sonarrDetail?.overview,
                        existingTrailer: nil,
                        posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore),
                        fallbackSymbol: "tv",
                        posterAspect: 2.0/3.0
                    )
                    SonarrDetailPanel(
                        item: item,
                        viewModel: viewModel,
                        siblings: siblings,
                        loadError: loadError,
                        header: seriesHeader,
                        cast: cast,
                        sonarrDetail: $sonarrDetail,
                        sonarrEpisodes: sonarrEpisodes,
                        sonarrEpisodeFiles: sonarrEpisodeFiles,
                        selectedSeasonNumber: $selectedSeasonNumber,
                        selectedEpisode: $selectedEpisode
                    )
                }
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

    private func sonarrRatingChipsFor(_ detail: SonarrSeriesDetail?) -> [RatingChip] {
        guard let r = detail?.ratings, let v = r.value else { return [] }
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
        overview: String?,
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
            overview: overview,
            posterURL: posterUrl ?? item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: arrAPIKey(for: item, in: configStore),
            fallbackSymbol: fallbackSymbol,
            posterAspect: posterAspect,
            blurred: configStore.shouldBlurPoster(for: item.source),
            trailing: existingTrailer,
            // Badge moved next to the status pill in
            // DownloadProgressCard — one consistent location across
            // list rows + detail surfaces.
            titleBadge: nil,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = url ?? item.posterURL
                }
            },
            // Title + year live in the nav-bar title now; hero hides
            // its in-card title to avoid duplication.
            showTitle: false
        )
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
                await fetchMovieCast(movieId: entityId)
            case .sonarr:
                let client = SonarrClient(config: configStore.sonarr)
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                async let files = (try? client.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                sonarrDetail = try await d
                sonarrEpisodes = try await eps
                sonarrEpisodeFiles = await files
                await fetchSeriesCast(seriesId: entityId, tmdbId: sonarrDetail?.tmdbId)
                // Auto-drill straight to the episode overlay when
                // the incoming queue item identifies a specific
                // episode. Clicking "Foo S02E04" in queue should
                // land on that episode's detail, not the series
                // splash — the user already picked a specific row.
                if autoDrillToEpisode,
                   !didAutoDrill,
                   selectedEpisode == nil,
                   let sn = item.seasonNumber, sn > 0,
                   let en = item.episodeNumber,
                   let ep = sonarrEpisodes.first(where: {
                       $0.seasonNumber == sn && $0.episodeNumber == en
                   }) {
                    didAutoDrill = true
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

    /// Movie cast straight from Radarr's `/credit` endpoint — Radarr stores
    /// it, so NO TMDB key is required (resolves the "key is AI-only" mismatch
    /// for movies).
    private func fetchMovieCast(movieId: Int) async {
        // Demo Radarr is enabled but has a blank baseURL (mocks, no real host),
        // so isConfigured is false — gate on demo too or demo movies show no cast.
        guard DemoMode.isActive || configStore.radarr.isConfigured else { return }
        let credits = (try? await RadarrClient(config: configStore.radarr).fetchCredits(movieId: movieId)) ?? []
        cast = CastMember.from(radarrCredits: credits)
    }

    /// Series cast from TMDB — Sonarr has no `/credit` endpoint, so this is
    /// the only source and it needs a configured TMDB key + the series'
    /// tmdbId. No-op otherwise (row stays hidden).
    private func fetchSeriesCast(seriesId: Int, tmdbId: Int?) async {
        if DemoMode.isActive {
            cast = DemoMocks.sonarrSeriesCast(seriesId: seriesId)
            return
        }
        let key = configStore.tmdbApiKey
        guard !key.isEmpty, let tmdbId, tmdbId > 0 else { return }
        guard let credits = try? await TMDBClient(apiKey: key).tvCredits(tvId: tmdbId) else { return }
        cast = CastMember.from(tmdbCast: credits.cast)
    }
}

