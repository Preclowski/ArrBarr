import SwiftUI

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
    /// Existing-file payload for upgrade-context rendering. Same shape
    /// the season list already passes to `EpisodeRow` — taken straight
    /// from `DetailView.sonarrEpisodeFiles` (works in demo too) instead
    /// of the per-episode async `/episodefile/{id}` fetch we used to
    /// fire, which returned nil in demo and broke the diff view.
    let episodeFile: SonarrEpisodeFile?
    /// Active queue item for this episode (when one's downloading).
    /// Powers the "new file" section that sits alongside the existing
    /// file — both can be present (upgrade in progress).
    let queueItem: QueueItem?
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

    @State private var isSearching = false
    @State private var ctaPendingDelete = false
    @State private var didSearch = false
    @State private var showSearchConfirm = false
    /// Own poster lightbox — set when the user taps the hero poster.
    @State private var enlargedPoster: URL?
    /// Manual-search ("Download") push target for this episode. Wrapped in a
    /// distinct type so its `.navigationDestination` doesn't collide with the
    /// parent DetailView's `ManualSearchTarget` destination in the same stack
    /// (SwiftUI ignores all but the root-most destination for a given type).
    @State private var manualSearchTarget: EpisodeReleaseSearch?
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
        episode: SonarrEpisodeDetail,
        seriesTitle: String,
        originLabel: LocalizedStringKey = "Details",
        posterURL: URL?,
        posterRequiresAuth: Bool,
        apiKey: String?,
        episodeFile: SonarrEpisodeFile? = nil,
        queueItem: QueueItem? = nil,
        onClose: @escaping () -> Void,
        onSearch: ((Int) async -> Void)?,
        warningActionURL: URL? = nil,
        onPauseEpisode: ((QueueItem) async -> Void)? = nil,
        onResumeEpisode: ((QueueItem) async -> Void)? = nil,
        onDeleteEpisode: ((QueueItem) -> Void)? = nil,
        onTapSeries: (() -> Void)? = nil,
        onTapSeason: (() -> Void)? = nil,
        seriesYear: Int? = nil,
        isLoadingDetails: Bool = false
    ) {
        self.episode = episode
        self.seriesTitle = seriesTitle
        self.originLabel = originLabel
        self.posterURL = posterURL
        self.posterRequiresAuth = posterRequiresAuth
        self.apiKey = apiKey
        self.episodeFile = episodeFile
        self.queueItem = queueItem
        self.onClose = onClose
        self.onSearch = onSearch
        self.warningActionURL = warningActionURL
        self.onPauseEpisode = onPauseEpisode
        self.onResumeEpisode = onResumeEpisode
        self.onDeleteEpisode = onDeleteEpisode
        self.onTapSeries = onTapSeries
        self.onTapSeason = onTapSeason
        self.seriesYear = seriesYear
        self.isLoadingDetails = isLoadingDetails
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
                Text(navTitleString)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let url = warningActionURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("detail.openInBrowser.button", bundle: .module))
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
        // Manual-search ("Download") drill-down — releases for this episode.
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target, onBack: { manualSearchTarget = nil })
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
                // Detached window surfaces Safari in the self-drawn header above
                // (the toolbar bar doesn't render in the hand-built NSWindow).
                if !isDetachedWindow, let url = warningActionURL {
                    Button { PlatformURLOpener.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help(Text("detail.openInBrowser.button", bundle: .module))
                }
                // iOS: delete in the toolbar, to the RIGHT of Safari.
                // macOS surfaces it next to the Resume CTA instead.
                #if os(iOS)
                if queueItem != nil, onDeleteEpisode != nil {
                    Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                    .help(Text("queue.cancelDownload.button", bundle: .module))
                }
                #endif
            }
        }
        // Inline confirmations — see InlineConfirm.swift for why we
        // can't use `.confirmationDialog` inside MenuBarExtra panels.
        .inlineConfirm(
            isPresented: $showSearchConfirm,
            title: "Search this episode?",
            message: LocalizedStringKey("Will query your indexers and start a download if a release matches."),
            confirmLabel: "Search",
            onConfirm: { performSearch() }
        )
        .inlineConfirm(
            isPresented: $ctaPendingDelete,
            title: "Cancel this download?",
            message: LocalizedStringKey("This will remove the download from the client."),
            confirmLabel: "Cancel download",
            cancelLabel: "Keep download",
            isDestructive: true,
            onConfirm: {
                if let q = queueItem { onDeleteEpisode?(q); onClose() }
            }
        )
    }

    private var shouldShowCTAStrip: Bool {
        let canPauseResume = (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        // Library episode that isn't downloading → offer manual search
        // ("Download"). Aired-only so we don't query indexers for future eps.
        let canManualSearch = hasAired && queueItem == nil
        // Trash + Safari moved to the toolbar; bottom strip only renders if a
        // primary verb (pause/resume, download, search) needs a place.
        return canPauseResume || canManualSearch
    }

    @ViewBuilder
    private var episodeCTAStrip: some View {
        let canPauseResume = (queueItem?.status == .downloading || queueItem?.status == .paused)
            && ((queueItem?.isPaused == true && onResumeEpisode != nil)
                || (queueItem?.isPaused == false && onPauseEpisode != nil))
        // Auto-search (queues an EpisodeSearch command); manual "Download" opens
        // the indexer release list. Manual works for upgrades too (file present),
        // so it isn't gated on `!hasFile` the way auto-search is.
        // Standardised: automatic search appears under the SAME rule as manual
        // search — episode not downloading + aired (works for upgrades too, so
        // it isn't gated on `!hasFile`).
        let canSearch = onSearch != nil && hasAired && queueItem == nil
        let canManualSearch = hasAired && queueItem == nil
        HStack(spacing: 8) {
            if canPauseResume, let q = queueItem {
                ctaPauseResume(q: q)
                #if os(macOS)
                // macOS: delete next to Resume — same prominent capsule shape as
                // the Download CTA, tinted red. iOS keeps it in the nav toolbar.
                if onDeleteEpisode != nil {
                    ctaCancelProminent
                }
                #endif
            } else if canManualSearch {
                ctaDownload
                if canSearch { ctaSearch }
            }
        }
    }

    @ViewBuilder
    private var ctaDownload: some View {
        Button {
            manualSearchTarget = EpisodeReleaseSearch(target: .episode(episodeId: episode.id, title: navTitleString))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Manual search", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
    }

    @ViewBuilder
    private func ctaPauseResume(q: QueueItem) -> some View {
        // Shared button: prominent glass capsule (Manual-search shape) with a
        // progress ring glyph + in-flight spinner; tint follows status.
        PauseResumeButton(isPaused: q.isPaused, progress: q.progress, tint: q.status.tint) {
            if q.isPaused { await onResumeEpisode?(q) } else { await onPauseEpisode?(q) }
        }
    }

    @ViewBuilder
    private var ctaCancelProminent: some View {
        Button { PanelActivation.bringForward(); ctaPendingDelete = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .scaledFont(size: 11, weight: .semibold)
                Text("queue.cancelDownload.button", bundle: .module)
                    .scaledFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .tint(.red)
    }

    @ViewBuilder
    private var ctaSearch: some View {
        Button { showSearchConfirm = true } label: {
            HStack(spacing: 6) {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if didSearch {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("detail.searchQueued.button", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                } else {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Automatic search", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .modifier(GlassProminentButtonStyle())
        .disabled(isSearching)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Poster + blur container match MediaHeaderCard's
                // chrome (110×165, 6pt corner, blur wrap) so episode
                // detail looks like every other detail surface in the
                // app instead of a custom one-off card.
                let poster = PosterBlurContainer(blurred: false, cornerRadius: Tokens.Radius.card) {
                    RemotePoster(
                        url: posterURL,
                        apiKey: posterRequiresAuth ? apiKey : nil,
                        size: CGSize(width: 110, height: 165),
                        cornerRadius: Tokens.Radius.card,
                        fallbackSymbol: "tv"
                    )
                }
                // Self-contained lightbox: this overlay is a NavigationStack
                // push, so a host-owned lightbox (DetailView's) renders
                // BELOW it and never shows. Tapping raises our own
                // `enlargedPoster` overlay instead — works in both the
                // from-queue (EpisodeQuickDetail) and from-series flows.
                Button {
                    withAnimation(.smooth(duration: 0.22)) { enlargedPoster = posterURL }
                } label: { poster }
                    .buttonStyle(.plain)
                    .disabled(posterURL == nil)
                    .help(Text("detail.showPoster.button", bundle: .module))
                VStack(alignment: .leading, spacing: 6) {
                    // Series title (with year) shows in content as a
                    // drill-in link — the episode's series context. Only
                    // when `onTapSeries` is set (episode opened straight
                    // from queue, series not yet in the stack); when
                    // opened from inside the series there's nothing to
                    // drill to, so it's dropped.
                    if let onTapSeries {
                        Button(action: onTapSeries) {
                            HStack(spacing: 4) {
                                Text(seriesTitleWithYear)
                                    .scaledFont(size: 12, weight: .medium)
                                    .lineLimit(2)
                                LinkChevron(size: 9)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        // Series-link chevron brightens when the cursor
                        // is over the title button, not just the glyph.
                        .linkRowHover()
                    }
                    // Season context — drill to it (from the queue) or back to
                    // it (from the season list). The nav bar now shows only
                    // "Episode N", so the season lives here as a chevron link.
                    if let onTapSeason {
                        Button(action: onTapSeason) {
                            HStack(spacing: 4) {
                                Text(verbatim: seasonLabel)
                                    .scaledFont(size: 12, weight: .medium)
                                    .lineLimit(1)
                                LinkChevron(size: 9)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .linkRowHover()
                    } else {
                        Text(verbatim: seasonLabel)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // SxxExx moved to the nav-bar title. "Unaired" only
                    // renders when relevant — no empty row left behind.
                    if !hasAired {
                        Text("detail.unaired.button", bundle: .module)
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip).stroke(Color.orange.opacity(0.30), lineWidth: 0.75))
                    }
                    // Episode name as the in-content hero, under the
                    // series link. The season/episode number lives in the
                    // nav-bar header now.
                    if let title = episode.title, !title.isEmpty {
                        Text(title)
                            .scaledFont(size: 17, weight: .semibold)
                            .lineLimit(3)
                    } else if isLoadingDetails {
                        SkeletonBar(width: 200, height: 18)
                    } else {
                        Text(verbatim: "—")
                            .scaledFont(size: 17, weight: .semibold)
                    }
                    // Runtime · air date on a single line (mirrors the movie /
                    // series hero's metadata row); the synopsis follows below.
                    let metaSegments: [String] = [
                        (episode.runtime ?? 0) > 0 ? "\(episode.runtime!) min" : nil,
                        episode.airDateUtc.flatMap(parseArrDate)
                            .map { EpisodeDetailOverlay.airFormatter.string(from: $0) },
                    ].compactMap { $0 }
                    if !metaSegments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(metaSegments.enumerated()), id: \.offset) { idx, seg in
                                if idx > 0 { SeparatorDot() }
                                Text(verbatim: seg)
                            }
                        }
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        ExpandableOverview(text: overview)
                    } else if isLoadingDetails {
                        SkeletonLines(count: 3)
                    }
                }
                Spacer(minLength: 0)
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
        if let q = queueItem, let existing = episodeFile, episode.hasFile == true {
            queueFileWithDiff(new: q, existing: existing)
        } else if let q = queueItem {
            queueFileSection(q)
        } else if let existing = episodeFile {
            // In library (on disk, not downloading) — lead with the same
            // "library" badge the movie detail wears.
            VStack(alignment: .leading, spacing: 6) {
                InLibraryBadge()
                ExistingFileBanner(episodeFile: existing)
            }
        }
    }

    /// Diff variant — new file (downloading) up top with its full
    /// presentation, existing file rolled into a `└─` sub-line that
    /// carries quality/size/score + delta. CF chip diff (added /
    /// removed) follows the new chip strip if the sets differ.
    @ViewBuilder
    private func queueFileWithDiff(new q: QueueItem, existing: SonarrEpisodeFile) -> some View {
        // Sonarr ships existing-file metadata in a separate
        // `/episodefile/{id}` payload (not on the QueueItem), so we
        // tunnel it into the card via `existingOverride`. The card
        // then renders the same in-header diff line every other
        // surface uses — movie detail and episode detail wear
        // identical chrome.
        let existingTags = (existing.customFormats ?? []).map(\.name)
        VStack(alignment: .leading, spacing: 6) {
            DownloadProgressCard(
                item: q,
                showHeader: true,
                showProgressFill: false,
                existingOverride: DownloadProgressCard.ExistingFileSnapshot(
                    quality: existing.quality?.name,
                    size: existing.size,
                    score: existing.customFormatScore,
                    formats: existingTags,
                    filename: existing.relativePath
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
            DownloadProgressCard(item: q, showUpgradeDiff: false, showHeader: true, showProgressFill: false)
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
