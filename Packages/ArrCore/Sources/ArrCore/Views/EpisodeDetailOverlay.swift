import SwiftUI
import MediaKit

/// Compact full-popover episode detail. Pushed on top of `DetailView`
/// when the user taps an `EpisodeRow`. Shows episode metadata, the
/// download/on-disk file section and the header action cluster
/// (search / bookmark / safari). Closes via the leading back chevron
/// or Esc.
public struct EpisodeDetailOverlay: View {
    let episode: ArrEpisode
    let seriesTitle: String
    let posterURL: URL?
    let posterRequiresAuth: Bool
    let apiKey: String?
    /// Lazy-loaded file payload — `nil` until the parent fetches
    /// `/episodefile/{id}` for an on-disk episode. Drives the
    /// quality / size / customFormats chip strip.
    /// Existing-file payload for upgrade-context rendering. Same shape
    /// the season list already passes to `EpisodeRow` — taken straight
    /// from `DetailView.sonarrEpisodeFiles` (works in demo too) instead
    /// of the per-episode async `/episodefile/{id}` fetch we used to
    /// fire, which returned nil in demo and broke the diff view.
    let episodeFile: ArrFile?
    /// ALL active queue items for this episode (usually 0 or 1; 2+ when the
    /// same episode was grabbed twice). Powers the "new file" section that
    /// sits alongside the existing file — both can be present (upgrade in
    /// progress). With duplicates, every download renders its own block with
    /// its own pause/cancel controls.
    let queueItems: [QueueItem]
    /// Representative download — first of `queueItems`. Single-download
    /// paths (CTA strip, toolbar trash, diff section) act on this.
    private var queueItem: QueueItem? { queueItems.first }
    let onClose: () -> Void
    let onSearch: ((Int) async -> Void)?
    /// Pause/Resume/Cancel closures for the active queueItem — wired
    /// by DetailView from the same `viewModel.pause/resume/delete`
    /// pipeline the season list uses. Drives the sticky bottom CTA
    /// strip on download/paused episodes.
    // Async so the Pause/Resume CTA can show an in-flight spinner until the
    // action (and its queue refresh) completes.
    let onPauseEpisode: ((QueueItem) async -> Void)?
    let onResumeEpisode: ((QueueItem) async -> Void)?
    let onDeleteEpisode: ((QueueItem) -> Void)?
    /// Set when this episode was opened directly from queue (no series
    /// view in the back stack). Tap on the series title fires this so
    /// the caller can push a series DetailView. `nil` = series title is
    /// inert text (matches the "opened from inside Series" flow).
    let onTapSeries: (() -> Void)?
    /// Set when the season is reachable from here — tapping the hero's "Season N"
    /// link drills to it (from the queue) or pops back to it (from the season
    /// list). nil leaves the season as inert context text.
    let onTapSeason: (() -> Void)?
    /// Optional series year for the nav-bar title (`Series (2019) · S03E04`).
    /// Falls back to bare `Series · S03E04` when unknown.
    let seriesYear: Int?
    /// Series facts the episode hero borrows — an episode has no genres or age
    /// rating of its own, and the movie hero shows both.
    var genres: [String] = []
    var certification: String? = nil
    /// The series' TMDB / TVDB ids, for the episode's own TMDB score.
    var seriesTmdbId: Int? = nil
    var seriesTvdbId: Int? = nil
    /// The series' assigned quality profile, drawn beside the state chips —
    /// the same `ProfileChip` the movie hero carries. The series owns the
    /// profile, so whoever fetched the series record resolves the name.
    var profileName: String? = nil
    /// Provider ids of the SERIES, for the media server's watch state. Empty
    /// when the host didn't resolve them — the wedge then simply stays off.
    var mediaServerKeys: [MediaServerExternalKey] = []
    /// The SERIES cast (TMDB has no per-episode credits worth the extra call).
    /// Handed down by whoever already loaded it, so opening an episode from a
    /// series the user was just looking at costs nothing.
    var cast: [CastMember] = []
    /// URL of the arr's web UI for the active queue item — surfaced
    /// as a CTA on the warning banner. Most `statusMessages` are only
    /// actionable inside the arr's own UI (manual import, blocklist,
    /// edit grab), so a one-click jump there is the actionable bit.
    let warningActionURL: URL?
    /// Detail fetch still in flight (opened straight from the queue, full
    /// episode metadata not yet loaded) — show skeletons for the episode
    /// title / overview instead of a bare dash, so the hero fills in rather
    /// than gating behind a spinner. Defaults off for the from-series flow,
    /// which always passes a fully-loaded episode.
    var isLoadingDetails: Bool = false
    /// Monitored flag, passed in EXPLICITLY rather than read off `episode`.
    /// This view is pushed via `.navigationDestination(item:)`, so `episode`
    /// is the snapshot captured when the row was tapped — reading the flag
    /// from it would give a bookmark that never changes after it's flipped.
    /// The parent recomputes this from its live episode array on every body
    /// pass. `nil` renders no bookmark.
    var monitored: Bool? = nil
    /// Flips the episode's monitored flag — wired by the parent, which owns
    /// the live episode array. nil renders the bookmark as inert state.
    var onToggleMonitored: ((Bool) async -> Void)? = nil

    /// Pinned to the hero poster's top-right corner, matching `DetailView` /
    /// `SeasonDetailView` — the bookmark is state about the episode, not a
    /// header action.
    @ViewBuilder
    private var monitorPosterToggle: some View {
        if let monitored {
            MonitorPosterToggle(isMonitored: monitored, entity: .episode, onToggle: onToggleMonitored)
        }
    }

    @State private var isSearching = false
    @State private var ctaPendingDelete = false
    @State private var didSearch = false
    /// Own poster lightbox — set when the user taps the hero poster.
    @State private var enlargedPoster: URL?
    /// Manual-search ("Download") push target for this episode. Wrapped in a
    /// distinct type so its `.navigationDestination` doesn't collide with the
    /// parent DetailView's `ManualSearchTarget` destination in the same stack
    /// (SwiftUI ignores all but the root-most destination for a given type).
    @State private var manualSearchTarget: EpisodeReleaseSearch?
    /// Pushed from a cast head. Owned here: this overlay is its own stack
    /// entry, so the host's person destination sits below it and never shows.
    @State private var personRef: PersonRef?
    /// TMDB's score for THIS episode — the only per-episode rating there is.
    @State private var episodeRating: EpisodeRatingProvider.Rating?
    /// Only for the TMDB key behind the episode rating; every other input to
    /// this view is handed down by its host.
    @EnvironmentObject private var configStore: ConfigStore
    /// The detached NSWindow draws no NavigationStack chevron, so we render our
    /// own back header there (mirrors DetailView) — otherwise the episode detail
    /// is a navigation trap with no way back.
    @Environment(\.isDetachedWindow) private var isDetachedWindow

    private var hasAired: Bool {
        guard let air = episode.airDateUtc.flatMap(parseArrDate) else { return true }
        return air <= Date()
    }

    /// Nav-bar title carries the season/episode number in long form —
    /// `Season 3 · Episode 5` (localized "Sezon 3 · Odcinek 5"). The
    /// episode NAME lives in the content hero; the series identity is
    /// the year-bearing drill-in link.
    private var navTitleString: String {
        // Header carries only "Episode N" now — the season moved to a tappable
        // link in the hero (see `content`).
        String(format: String(localized: "detail.episodeLld.label", bundle: .module),
               episode.episodeNumber ?? 0)
    }

    /// "Season N" for the hero's season drill-in link.
    private var seasonLabel: String {
        String(format: String(localized: "detail.seasonLld.label", bundle: .module),
               episode.seasonNumber ?? 0)
    }

    /// Series title with year for the content drill-in link —
    /// `Series (2019)`. Year dropped when unknown.
    private var seriesTitleWithYear: String {
        if let year = seriesYear { return "\(seriesTitle) (\(year))" }
        return seriesTitle
    }

    public init(
        episode: ArrEpisode,
        seriesTitle: String,
        posterURL: URL?,
        posterRequiresAuth: Bool,
        apiKey: String?,
        episodeFile: ArrFile? = nil,
        queueItems: [QueueItem] = [],
        onClose: @escaping () -> Void,
        onSearch: ((Int) async -> Void)?,
        warningActionURL: URL? = nil,
        onPauseEpisode: ((QueueItem) async -> Void)? = nil,
        onResumeEpisode: ((QueueItem) async -> Void)? = nil,
        onDeleteEpisode: ((QueueItem) -> Void)? = nil,
        onTapSeries: (() -> Void)? = nil,
        onTapSeason: (() -> Void)? = nil,
        seriesYear: Int? = nil,
        cast: [CastMember] = [],
        genres: [String] = [],
        certification: String? = nil,
        seriesTmdbId: Int? = nil,
        seriesTvdbId: Int? = nil,
        profileName: String? = nil,
        mediaServerKeys: [MediaServerExternalKey] = [],
        isLoadingDetails: Bool = false,
        monitored: Bool? = nil,
        onToggleMonitored: ((Bool) async -> Void)? = nil
    ) {
        self.episode = episode
        self.seriesTitle = seriesTitle
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.episodeFile = episodeFile
        self.queueItems = queueItems
        self.onClose = onClose
        self.onSearch = onSearch
        self.warningActionURL = warningActionURL
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
        self.onTapSeries = onTapSeries
        self.onTapSeason = onTapSeason
        self.seriesYear = seriesYear
        self.cast = cast
        self.genres = genres
        self.certification = certification
        self.seriesTmdbId = seriesTmdbId
        self.seriesTvdbId = seriesTvdbId
        self.profileName = profileName
        self.mediaServerKeys = mediaServerKeys
        self.isLoadingDetails = isLoadingDetails
        self.monitored = monitored
        self.onToggleMonitored = onToggleMonitored
    }

    public var body: some View {
        // No solid scrim — would kill the popover's native
        // translucent chrome. Underlying series detail is opacity-
        // hidden in DetailView while this overlay is up, so we don't
        // need to mask it ourselves. The view fills the popover, lets
        // glass shine through.
        VStack(spacing: 0) {
            // macOS self-draws the header (back + title + Safari) on BOTH
            // surfaces. The detached NSWindow renders no native chevron; the
            // popover's chevron is suppressed because the parent DetailView hides
            // the window toolbar — so without this the episode view is a back-less
            // trap there. iOS keeps the native nav bar + `.toolbar`.
            #if os(macOS)
            HStack(spacing: 6) {
                FloatingBackButton(action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("settings.back.button", bundle: .module))
                Text(navTitleString)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                headerSearchMenu
                if let url = warningActionURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("detail.openInBrowser.button", bundle: .module))
                    .accessibilityLabel(Text("detail.openInBrowser.button", bundle: .module))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // 4pt (matches DetailView / SeasonDetailView headers) so the hero
            // doesn't shift a few px down when pushing season → episode.
            .padding(.bottom, 4)
            #endif
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            // Sticky bottom CTA — same shape as `DetailView`'s
            // `downloadCTAStrip`. Pause/Resume when downloading,
            // Search when missing+aired, Safari as fallback / secondary.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowCTAStrip {
                    // Same floating-island treatment as DetailView's
                    // strip — no material backdrop / top divider.
                    episodeCTAStrip
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Full-screen poster: iOS covers all chrome (no header/back, tap to
        // close); macOS overlays inside the popover.
        .posterLightbox(
            url: $enlargedPoster,
            apiKey: posterRequiresAuth ? apiKey : nil,
            aspectRatio: 2.0 / 3.0
        )
        // Manual-search ("Download") drill-down — releases for this episode,
        // diffed against the episode file on disk when there is one.
        .task(id: episode.id) {
            episodeRating = await EpisodeRatingProvider.rating(
                tmdbId: seriesTmdbId, tvdbId: seriesTvdbId,
                season: episode.seasonNumber, episode: episode.episodeNumber,
                configStore: configStore)
        }
        .personDestination($personRef)
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target,
                            existing: episodeFile.map(UpgradeDiffView.side(file:)),
                            waitContext: WaitCardContext(seriesYear: seriesYear, cast: cast, posterURL: posterURL),
                            onBack: { manualSearchTarget = nil })
        }
        #if os(iOS)
        .navigationTitle(navTitleString)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS self-draws the header above; hide the native chevron + title so
        // they aren't duplicated (and stay consistent with the parent DetailView).
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        // Secondary actions (Trash, Safari) lifted to the system
        // toolbar — matches the DetailView pattern so the user finds
        // them in the same place regardless of drill-down depth.
        // `ToolbarItemGroup(placement: .primaryAction)` — same workaround
        // as DetailView for the macOS multi-`.automatic`-item hides
        // bug. Single placement, cluster ordered left-to-right.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // iOS-only: macOS already carries these in the self-drawn
                // header above, and adding them here too would double them up.
                #if os(iOS)
                headerSearchMenu
                #endif
                // Detached window surfaces Safari in the self-drawn header above
                // (the toolbar bar doesn't render in the hand-built NSWindow).
                if !isDetachedWindow, let url = warningActionURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help(Text("detail.openInBrowser.button", bundle: .module))
                    .accessibilityLabel(Text("detail.openInBrowser.button", bundle: .module))
                }
                // iOS: delete in the toolbar, to the RIGHT of Safari.
                // macOS surfaces it next to the Resume CTA instead.
                #if os(iOS)
                // Single download only — with duplicates each block carries
                // its own trash, so a toolbar-level one would be ambiguous.
                if queueItems.count == 1, onDeleteEpisode != nil {
                    Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.red)
                    .help(Text("queue.cancelDownload.button", bundle: .module))
                    .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
                    // Destructive and irreversible — say what it actually does
                    // before the user double-taps a bare trash can.
                    .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
                }
                #endif
            }
        }
        // Inline confirmations — see InlineConfirm.swift for why we
        // can't use `.confirmationDialog` inside MenuBarExtra panels.
        // (Automatic search lost its confirm: picking it from the Search
        // menu is already a deliberate two-step choice.)
        .inlineConfirm(
            isPresented: $ctaPendingDelete,
            title: "Remove this download?",
            message: LocalizedStringKey("This will remove the download from the client."),
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: {
                if let q = queueItem { onDeleteEpisode?(q); onClose() }
            }
        )
        // (Per-download cancel on the duplicate path confirms inside MultiRow —
        // ConfirmCenter on macOS, native dialog on iOS — and deliberately does
        // NOT close the overlay: the other download is still live.)
    }

    private var shouldShowCTAStrip: Bool {
        // Pause/resume only — Search lives in the header now, and duplicate
        // grabs put the controls on each download block instead of the strip.
        queueItems.count == 1
            && (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
    }

    /// Search moved to the header cluster — the strip only carries the
    /// pause/cancel verbs, and only for a single active download (with
    /// duplicates each block controls its own).
    @ViewBuilder
    private var episodeCTAStrip: some View {
        let canPauseResume = queueItems.count == 1
            && (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        HStack(spacing: 8) {
            if canPauseResume, let q = queueItem {
                ctaPauseResume(q: q)
                #if os(macOS)
                // macOS: destructive Cancel anchors the trailing edge, away
                // from the primary verb. iOS keeps it in the nav toolbar.
                if onDeleteEpisode != nil {
                    ctaCancelProminent
                }
                #endif
            }
        }
    }

    /// The episode's Search choice, relocated to the header cluster. Aired
    /// episodes only (searching indexers for a future episode is noise).
    /// With no auto-search closure wired, a one-item menu would be pointless —
    /// the glyph goes straight to the release list instead.
    @ViewBuilder
    private var headerSearchMenu: some View {
        if hasAired {
            if onSearch != nil {
                HeaderSearchMenu(
                    inFlight: isSearching,
                    didQueue: didSearch,
                    onAutomatic: { performSearch() },
                    onManual: { manualSearchTarget = EpisodeReleaseSearch(target: .episode(episodeId: episode.id, title: navTitleString)) }
                )
            } else {
                Button {
                    manualSearchTarget = EpisodeReleaseSearch(target: .episode(episodeId: episode.id, title: navTitleString))
                } label: {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Manual search", bundle: .module))
                .accessibilityLabel(Text("Manual search", bundle: .module))
            }
        }
    }

    @ViewBuilder
    private func ctaPauseResume(q: QueueItem) -> some View {
        // Shared button: prominent glass capsule (Manual-search shape) with a
        // progress ring glyph + in-flight spinner; tint follows status.
        // Action tint, not status tint — see DetailView.pauseResumeProminent.
        PauseResumeButton(isPaused: q.isPaused, progress: q.progress, tint: q.isPaused ? .blue : .orange) {
            if q.isPaused { await onResumeEpisode?(q) } else { await onPauseEpisode?(q) }
        }
        // The button's progress ring is the only place this episode's
        // completion is shown on the CTA strip — publish it as the value so
        // VoiceOver announces "Pause download, 62%".
        .accessibilityValue(Text(max(0.0, min(1.0, q.progress)), format: .percent.precision(.fractionLength(0))))
    }

    /// Compact icon-only trash — red glyph on neutral gray glass, matching
    /// DetailView.cancelGlassCompact.
    @ViewBuilder
    private var ctaCancelProminent: some View {
        Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 13, weight: .bold)
                .frame(width: 26)
                .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
        .help(Text("queue.cancelDownload.button", bundle: .module))
        .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
        // Destructive: spell out the consequence, since "Cancel download"
        // alone doesn't say the client loses the transfer.
        .accessibilityHint(Text("This will remove the download from the client.", bundle: .module))
    }

    /// Episode name, or a dash once we know there isn't one. While the full
    /// record is still loading the card skeletons it (empty title +
    /// `metadataLoading`).
    private var episodeHeroTitle: String {
        if let title = episode.title, !title.isEmpty { return title }
        return isLoadingDetails ? "" : "—"
    }

    /// The episode's own TMDB score, as the app's one rating pill. Empty until
    /// it lands (or forever, without a TMDB key) — the card then simply has no
    /// rating row, exactly as before.
    private var ratingChips: [RatingChip] {
        guard let episodeRating else { return [] }
        return [RatingChip.tmdb(episodeRating.value, votes: episodeRating.votes)].compactMap { $0 }
    }

    private var airDateText: String? {
        episode.airDateUtc.flatMap(parseArrDate).map { Self.airFormatter.string(from: $0) }
    }

    /// Chips above the title: on disk, and "not aired yet" when that is the
    /// news.
    @ViewBuilder
    private var heroBadges: some View {
        HStack(spacing: 4) {
            if let profileName { ProfileChip(name: profileName) }
            if episode.hasFile == true {
                LibraryStateBadge(isDownloaded: true)
            }
            if !hasAired {
                Text("detail.unaired.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .chipOutline(.orange)
            }
        }
    }

    /// Has the media server played THIS episode? (Series-level watch state
    /// says nothing about one episode — see `MediaServerIndex.isWatched`.)
    private var isWatched: Bool {
        MediaServerIndex.shared.isWatched(mediaServerKeys,
                                          season: episode.seasonNumber,
                                          episode: episode.episodeNumber)
    }

    /// Everything that sits ABOVE the episode name: the state chips, then the
    /// series and season drill-ins. Not `titleBadge` — that slot renders in
    /// the title's own line, which put "Downloaded" next to the episode name.
    /// Either link can be absent: opened from inside the series there is
    /// nothing to drill to.
    @ViewBuilder
    private var seriesContextLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            heroBadges
            if let onTapSeries {
                Button(action: onTapSeries) {
                    HStack(spacing: 4) {
                        Text(seriesTitleWithYear)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(2)
                            // The series name is a heading, not chrome:
                            // `.secondary` over the popover's vibrant backdrop
                            // read as half-faded.
                            .foregroundStyle(.primary)
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .linkRowHover()
            }
            if let onTapSeason {
                Button(action: onTapSeason) {
                    HStack(spacing: 4) {
                        Text(verbatim: seasonLabel)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                        LinkChevron(size: 9)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .linkRowHover()
            } else if onTapSeries == nil {
                Text(verbatim: seasonLabel)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The SAME hero every other detail surface draws (movie, series,
            // season, album). This screen used to hand-roll its own — poster,
            // title, metadata line and synopsis all re-implemented — which is
            // where the drift came from: a different poster tier and crop
            // between the season screen and this one, a 17pt title against
            // everyone else's 15pt, and no skeletons while the episode loaded.
            MediaHeaderCard(
                title: episodeHeroTitle,
                runtime: episode.runtime,
                certification: certification,
                extraMetadata: airDateText.map { [$0] } ?? [],
                genres: genres,
                ratings: ratingChips,
                overview: episode.overview,
                posterURL: posterURL,
                posterRequiresAuth: posterRequiresAuth,
                apiKey: apiKey,
                fallbackSymbol: "tv",
                // Spelled out rather than defaulted: the series, season and
                // episode heroes must draw their artwork identically, and a
                // default is one edit away from disagreeing.
                posterAspect: 2.0 / 3.0,
                blurred: false,
                onPosterTap: { url in
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url }
                },
                posterCornerAction: AnyView(monitorPosterToggle),
                // Series / season context stays where it was: above the
                // episode name, in the column beside the poster.
                aboveTitle: AnyView(seriesContextLinks),
                watched: isWatched,
                metadataLoading: isLoadingDetails
            )

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: { member in
                    if let ref = PersonRef(castMember: member) { personRef = ref }
                })
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
                // No explicit Divider — the progress bar at the top
                // of `DownloadProgressCard` reads as a natural
                // horizontal rule between description and file
                // section.
                fileSection
            }

            // Search / pause / cancel / safari all surfaced as the
            // sticky bottom CTA strip (`episodeCTAStrip`) — body stays
            // pure content (poster, metadata, file section).
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
        if queueItems.count > 1 {
            duplicateDownloadsSection
        } else if let q = queueItem, let existing = episodeFile, episode.hasFile == true {
            queueFileWithDiff(new: q, existing: existing)
        } else if let q = queueItem {
            queueFileSection(q)
        } else if let existing = episodeFile {
            // On disk, not downloading. The library chip lives in the hero
            // now — this block is captioned by what it actually is.
            VStack(alignment: .leading, spacing: 6) {
                DetailSectionHeader("Existing file")
                ExistingFileBanner(file: existing)
            }
        }
    }

    /// Duplicate-grab path: 2+ active downloads for this one episode. Every
    /// download renders its own progress card with its OWN pause/cancel row
    /// (the bottom CTA strip is suppressed — a single pause there would be
    /// ambiguous). The on-disk file (upgrade target), when present, renders
    /// once below — it's shared by both downloads, so per-block diffs would
    /// just repeat it.
    @ViewBuilder
    private var duplicateDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("queue.inQueue.button", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                SeparatorDot()
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("unit.downloads", bundle: .module, comment: ""),
                    queueItems.count
                ))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            }
            ForEach(queueItems) { q in
                duplicateDownloadBlock(q)
            }
            if let existing = episodeFile, episode.hasFile == true {
                // Upgrade target shared by all the duplicate grabs above —
                // same "Existing file" caption as the idle in-library block.
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("Existing file")
                    ExistingFileBanner(file: existing)
                }
            }
        }
    }

    /// One duplicate download = one `MultiRow` (the same pause-ring + compact
    /// card + context-menu row the movie multi-list uses — it was a hand-rolled
    /// near-copy of it before), plus the episode-specific extras below: the
    /// warning banner and the release name, which is what actually tells two
    /// grabs of the same episode apart.
    @ViewBuilder
    private func duplicateDownloadBlock(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MultiRow(
                item: q,
                onPause: { Task { await onPauseEpisode?(q) } },
                onResume: { Task { await onResumeEpisode?(q) } },
                onDelete: onDeleteEpisode.map { del in { del(q) } }
            )
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: warningActionURL
                )
            }
            ReleaseNameBlock(release: q.releaseName)
        }
    }

    /// Diff variant — new file (downloading) up top with its full
    /// presentation, existing file rolled into a `└─` sub-line that
    /// carries quality/size/score + delta. CF chip diff (added /
    /// removed) follows the new chip strip if the sets differ.
    @ViewBuilder
    private func queueFileWithDiff(new q: QueueItem, existing: ArrFile) -> some View {
        // Sonarr ships existing-file metadata in a separate
        // `/episodefile/{id}` payload (not on the QueueItem), so we
        // tunnel it into the card via `existingOverride`. The card
        // then renders the same in-header diff line every other
        // surface uses — movie detail and episode detail wear
        // identical chrome.
        let existingTags = (existing.customFormats ?? []).map(\.name)
        VStack(alignment: .leading, spacing: 6) {
            DownloadingSectionHeader(item: q)
            DownloadProgressCard(
                item: q,
                showHeader: true,
                showStatusRow: false,
                existingOverride: DownloadProgressCard.ExistingFileSnapshot(
                    quality: existing.quality?.name,
                    size: existing.size,
                    score: existing.customFormatScore,
                    formats: existingTags,
                    // Last path component only — matches the queue path's
                    // `existingFileName` and the episode tooltip so the old
                    // name reads the same across detail / overview surfaces.
                    filename: existing.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                )
            )
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: warningActionURL
                )
            }
            // CF chips + diff AND the release-name block used to live here.
            // The card's `UpgradeDiffView` now renders both the gained/lost
            // format chips and the (untruncated) incoming + replaced file
            // names, so repeating them here would just double up.
        }
    }

    /// Section describing what's actively being downloaded for this
    /// episode. Same shape as the on-disk file section so the user
    /// reads both with a single mental model. Status pill + progress
    /// bar at the top give the "is this happening now" answer at a
    /// glance.
    @ViewBuilder
    private func queueFileSection(_ q: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DownloadingSectionHeader(item: q)
            DownloadProgressCard(item: q, showUpgradeDiff: false, showHeader: true, showStatusRow: false)
            if !q.statusMessages.isEmpty {
                QueueStatusMessagesBanner(
                    messages: q.statusMessages,
                    tint: q.status.tint,
                    actionURL: warningActionURL
                )
            }
            if !q.customFormats.isEmpty {
                CustomFormatChips(formats: q.customFormats, score: 0)
            }
            ReleaseNameBlock(release: q.releaseName)
        }
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

/// Distinct wrapper so the episode's manual-search `.navigationDestination`
/// doesn't share a value type with the parent DetailView's `ManualSearchTarget`
/// destination in the same NavigationStack (which SwiftUI can't disambiguate).
private struct EpisodeReleaseSearch: Identifiable, Hashable {
    let target: ManualSearchTarget
    var id: String { target.id }
}
