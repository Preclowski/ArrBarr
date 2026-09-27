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
    var viewModel: QueueViewModel
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
        if !matched.isEmpty { return matched }
        // No live queue rows for this entity. If we opened on a REAL queue row
        // (non-zero arrQueueId) it has since LEFT the queue — finished
        // importing, or was removed — so don't resurrect its stale snapshot
        // (frozen at e.g. "importing") as an active download: return empty so
        // `hasActiveDownloads` flips false and the panel shows the library
        // view (the `onChange` below refetches the now-on-disk file). A
        // synthetic open (chat / upcoming tap, arrQueueId == 0) was never in
        // the queue, so it keeps showing its single item.
        return item.arrQueueId != 0 ? [] : [item]
    }

    /// episode-id → ALL active queue items for this series, for
    /// SeasonDetailView's per-episode download indicators (mirrors
    /// SonarrDetailPanel's map). A list, not a single item — two grabs of the
    /// same episode (auto + manual) both stay visible; the old last-writer-wins
    /// dictionary silently hid one of them.
    ///
    /// Read from the `navigationDestination` closure, i.e. on every body pass:
    /// the slot → id lookup goes through `episodeIdBySlot` rather than scanning
    /// `sonarrEpisodes`, which on a long-running series cost `queue × episodes`
    /// comparisons per pass (same fix as `EpisodeQuickDetail`'s copy).
    private var sonarrQueueByEpisodeId: [Int: [QueueItem]] {
        var map: [Int: [QueueItem]] = [:]
        for q in siblings where q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let epId = episodeIdBySlot[EpisodeSlot(season: sn, episode: en)] {
                map[epId, default: []].append(q)
            }
        }
        return map
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
        let pool = viewModel.items(for: item.source)
        return pool.first { isSameRow($0) } ?? pool.first { $0.succeeds(item) } ?? pool.first { isSameEntity($0) } ?? item
    }

    /// Same *queue row* as the one the detail was opened on. The `arrQueueId`
    /// leg is guarded against 0: a synthetic item carries 0, and so would any
    /// non-queue row, so an unguarded `==` makes the two indistinguishable.
    private func isSameRow(_ candidate: QueueItem) -> Bool {
        candidate.id == item.id || (candidate.arrQueueId != 0 && candidate.arrQueueId == item.arrQueueId)
    }

    /// Same arr *record*, matched when the detail was opened before anything
    /// was downloading — straight after "Add to Radarr", where the synthetic
    /// item carries the arr record id but no queue id. When the arr's own
    /// search then grabs a release, the resulting queue row shares only
    /// `entityId`; without this leg `focused` stays pinned to the opening
    /// snapshot and the detail never notices its own download starting.
    ///
    /// Deliberately excludes Sonarr: there `entityId` is the *series* id and
    /// every episode row of that series carries it, so this would latch onto
    /// an arbitrary episode. Sonarr also never reaches the search CTA (its
    /// search is per-season, in SeasonDetailView).
    private func isSameEntity(_ candidate: QueueItem) -> Bool {
        guard item.arrQueueId == 0, item.source != .sonarr,
              let entityId = item.entityId else { return false }
        return candidate.entityId == entityId
    }

    /// Whether the opened item is still a live queue row. Flips false the
    /// moment an import finishes (or the row is removed) and the arr drops it
    /// from `/queue` — the cue to refetch so the detail swaps the stale
    /// download view for the freshly-imported on-disk file.
    private var isInLiveQueue: Bool {
        viewModel.items(for: item.source).contains { isSameRow($0) || $0.succeeds(item) || isSameEntity($0) }
    }

    /// True when at least one sibling is a real queue row (non-zero arrQueueId).
    /// `false` means this view was opened from a synthetic lookup item (chat
    /// card / upcoming row tap) and there's nothing to download right now —
    /// rendering a 0%/Unknown progress bar would be misleading.
    private var hasActiveDownloads: Bool {
        siblings.contains { $0.arrQueueId != 0 }
    }

    /// How many live queue rows this title has. >1 (a duplicate grab) drops
    /// the bottom pause/cancel — those act on `focused` only, which is
    /// ambiguous with two downloads on screen; the list rows control each.
    private var activeDownloadCount: Int {
        siblings.count { $0.arrQueueId != 0 }
    }

    @State private var radarrDetail: RadarrMovieDetail?
    /// Separately-fetched movie file. Radarr's `/movie/{id}` returns a
    /// stripped `movieFile` payload (no customFormats), so we hit
    /// `/moviefile?movieId={id}` afterwards to get the chip-bearing
    /// version for the ExistingFileBanner.
    @State private var radarrMovieFile: ArrFile?
    @State private var sonarrDetail: SonarrSeriesDetail?
    @State private var sonarrEpisodes: [SonarrEpisodeDetail] = []
    /// (season, episode) → episode id, rebuilt with `sonarrEpisodes`. Ids only,
    /// never episode payloads — `monitored` is flipped optimistically in
    /// `sonarrEpisodes` and a second copy would be one more thing to go stale.
    @State private var episodeIdBySlot: [EpisodeSlot: Int] = [:]
    /// `episodeFileId → file` map for the whole series. Fetched alongside
    /// `sonarrEpisodes` so downloaded `EpisodeRow`s can render their
    /// custom-format score in the right gutter instead of falling back to
    /// the air date — the score is the actionable info once an episode is
    /// on disk.
    @State private var sonarrEpisodeFiles: [Int: SonarrEpisodeFile] = [:]
    @State private var lidarrAlbum: LidarrAlbumDetail?
    @State private var lidarrTracks: [LidarrTrackDetail] = []
    @State private var lidarrTrackFiles: [LidarrTrackFile] = []
    /// Cast strip. Movies pull from Radarr's `/credit` (no key needed);
    /// series from TMDB (Sonarr has no cast endpoint) and only when a TMDB
    /// key is set. Empty = unavailable; the row just doesn't render.
    @State private var cast: [CastMember] = []
    /// Directing credits — a movie's director(s), a series' creator(s). Same
    /// source and same tap target as the cast strip; rendered above it.
    @State private var directors: [CastMember] = []
    /// Country of production (ISO 3166-1) for the hero's metadata row. TMDB-only
    /// — neither arr carries it — so empty whenever no key is set; the segment
    /// just doesn't render.
    @State private var countries: [String] = []
    /// Assigned quality-profile name ("Remux + WEB 2160p") — the hero's
    /// profile chip. Resolved from `/qualityprofile` alongside the detail.
    @State private var qualityProfileName: String?
    @State private var loading = true
    @State private var loadError: String?
    /// Cast-head → person view push, owned locally so back returns here.
    @State private var personRef: PersonRef?
    /// Album header's "artist name >" tap — pushes `LidarrArtistView`,
    /// owned locally (like `personRef`) so back returns to this album.
    @State private var artistDrill: QueueItem?

    /// Poster lightbox — set to a URL when the user taps the header
    /// card's poster, cleared by the xmark button. Renders as an
    /// overlay on top of the detail surface so it dismisses without
    /// leaving the popover.
    @State private var enlargedPoster: URL?
    /// YouTube video id of this title's trailer, resolved once the detail
    /// payload lands. Nil = no chip (no trailer, or no TMDB key for the
    /// series path).
    @State private var trailerKey: String?
    /// The clip currently on screen. Presentation lives in the shared
    /// `TrailerSession` (rendered by the surface root), so the clip survives
    /// the popover being closed and reopened mid-play.
    @ObservedObject private var trailerSession = TrailerSession.shared
    /// Season drill-down — set when the user taps a season row. Pushes
    /// `SeasonDetailView` (its episodes + that season's search buttons).
    @State private var seasonDrill: SeasonDrill?
    /// Manual-search push target (movie / album) when not downloading.
    @State private var manualSearchTarget: ManualSearchTarget?
    /// Header "..." → Edit: edit panel push (profile / availability / root folder).
    @State private var editRequest: MediaEditRequest?
    /// Header "..." → Delete — remove this record from the arr.
    @State private var deleteRequest: MediaDeleteRequest?
    /// "Show history" push — this record's history, scoped by `entityId`.
    @State private var historyShown = false
    /// Automatic-search in flight / just-queued feedback for the bottom CTA.
    @State private var autoSearching = false
    @State private var autoDidSearch = false
    /// The *server* is running an indexer search for this record. Covers the
    /// search the user fires from the CTA and, crucially, the one the arr
    /// starts by itself on add (`addOptions.searchForMovie`) — which the app
    /// never triggered and so has no other way to know about.
    @State private var searchRunning = false
    /// Bumped to restart the watcher after firing a search, so a search
    /// started long after the view opened still gets watched.
    @State private var searchWatchToken = 0
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
        // Pause/resume go straight to the download client; need one that's
        // configured AND reachable. And don't offer them when the item's arr is
        // unavailable — the data is stale, the action can't land. Both cases
        // hide the CTA (and the episode-row pause/resume/delete callbacks below).
        // Demo is exempt: no client is configured there and the actions are
        // served by the fixture transport.
        if DemoMode.isActive { return true }
        guard let kind = configStore.selectedDownloadClient(for: item.downloadProtocol) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        if viewModel.lastUnreachable.contains(item.source) { return false }
        return true
    }

    private var canPauseResume: Bool {
        let s = focused.status
        return s == .downloading || s == .paused || s == .queued
    }

    /// Queued (deferred) items get "play" like paused ones — resume force-starts them.
    private var focusedShowsPlay: Bool {
        focused.isPaused || focused.status == .queued
    }

    // MARK: - Monitored state

    /// What this detail's top-level entity is, and whether the arr says
    /// it's monitored. `nil` when the flag didn't decode — an arr (or fork,
    /// e.g. Whisparr V3) that doesn't report it gets NO bookmark rather
    /// than one asserting a state we never learned. Also `nil` while the
    /// detail fetch is still in flight, so the glyph appears with the data
    /// instead of flickering from a guessed value.
    private var monitorState: (entity: MonitorEntity, isMonitored: Bool)? {
        switch item.source {
        case .radarr, .whisparr:
            guard let m = radarrDetail?.monitored else { return nil }
            return (.movie, m)
        case .sonarr:
            guard let m = sonarrDetail?.monitored else { return nil }
            return (.series, m)
        case .lidarr:
            guard let m = lidarrAlbum?.monitored else { return nil }
            return (.album, m)
        }
    }

    /// Lives on the poster's top-right corner rather than in the header action
    /// cluster: the bookmark is a property OF this title, not a chrome action
    /// like Safari or trash, so it sits on the artwork it describes.
    /// `MonitorPosterToggle` carries its own contrast for light + dark posters.
    private var monitorPosterToggle: AnyView? {
        guard let state = monitorState else { return nil }
        return AnyView(
            MonitorPosterToggle(isMonitored: state.isMonitored, entity: state.entity) { monitored in
                await setTopLevelMonitored(monitored)
            }
        )
    }

    /// Push the person view for a tapped cast head (both providers stamp the
    /// TMDB id, so `PersonRef` init only fails for the rare id-less credit).
    private func openPerson(_ member: CastMember) {
        if let ref = PersonRef(castMember: member) { personRef = ref }
    }

    /// Flip the detail's top-level monitored flag: optimistic local write so
    /// the bookmark moves under the finger, then the arr call; a failure
    /// silently refetches so the UI snaps back to the server's truth.
    private func setTopLevelMonitored(_ monitored: Bool) async {
        guard let entityId = item.entityId else { return }
        do {
            switch item.source {
            case .radarr, .whisparr:
                radarrDetail?.monitored = monitored
                let client: any ArrAPIClient = item.source == .radarr
                    ? configStore.radarrClient
                    : configStore.whisparrClient
                try await client.setMovieMonitored(movieId: entityId, monitored: monitored)
            case .sonarr:
                sonarrDetail?.monitored = monitored
                try await configStore.sonarrClient
                    .setSeriesMonitored(seriesId: entityId, monitored: monitored)
            case .lidarr:
                lidarrAlbum?.monitored = monitored
                try await configStore.lidarrClient
                    .setAlbumMonitored(albumId: entityId, monitored: monitored)
            }
        } catch {
            await load(showSpinner: false)
        }
    }

    /// `Series · Season 02` — the title the release list shows for a season
    /// search started from a row, matching the season screen's own header.
    private func seasonSearchTitle(_ seasonNumber: Int) -> String {
        let season = String(format: String(localized: "detail.seasonLld.label", bundle: .module), seasonNumber)
        return "\(sonarrDetail?.title ?? splitTitleAndYear(item.title).title) · \(season)"
    }

    /// Flip ONE season's monitored flag. Optimistic write into the season array
    /// this view hands down (so the bookmark moves under the finger), then the
    /// Sonarr call, then a refetch either way: success cascades the flag to
    /// every episode server-side, failure snaps the optimistic flip back.
    ///
    /// Shared by the season list's row bookmarks and the pushed season screen —
    /// both flip the same flag, so they must flip it the same way.
    private func setSeasonMonitored(seasonNumber: Int, monitored: Bool) async {
        guard let seriesId = item.entityId else { return }
        if var seasons = sonarrDetail?.seasons,
           let idx = seasons.firstIndex(where: { $0.seasonNumber == seasonNumber }) {
            seasons[idx].monitored = monitored
            sonarrDetail?.seasons = seasons
        }
        do {
            try await configStore.sonarrClient.setSeasonMonitored(
                seriesId: seriesId, seasonNumber: seasonNumber, monitored: monitored)
        } catch {}
        await load(showSpinner: false)
    }

    public var body: some View {
        // Lidarr ARTIST items (search tap on an in-library artist, post-add
        // navigation, chat library card) get the artist surface — this view's
        // own lidarr path treats `entityId` as an ALBUM id and would fetch
        // `/album/{artistId}`, landing on an unrelated album.
        if item.isLidarrArtistLookup {
            LidarrArtistView(
                item: item,
                onBack: onBack,
                originLabel: originLabel,
                viewModel: viewModel
            )
        } else {
            detailBody
        }
    }

    private var detailBody: some View {
        ZStack {
            VStack(spacing: 0) {
                // Stacked header, not a `safeAreaBar`: tried both orders of
                // bar + `.scrollEdgeEffectStyle(.soft)` here and the system
                // never drew its blur on this surface, so the content just
                // disappeared under a header with nothing marking the seam.
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
                    // Floating CTA — no material backdrop / divider so the glass
                    // pill reads as an island on top of the content.
                    // Search lives in the header now — the strip only carries
                    // pause/cancel, and only when there's exactly one download
                    // (with duplicates each list row controls its own).
                    if hasActiveDownloads, activeDownloadCount == 1, canControl, canPauseResume {
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
            //
            // Parked on all four mechanisms while it's up (see
            // PopoverContentView for why hiding alone isn't parking). The
            // lightbox itself is applied outside this ZStack, so disabling the
            // content underneath can't reach its dismiss gestures.
            .opacity(enlargedPoster != nil ? 0 : 1)
            .allowsHitTesting(enlargedPoster == nil)
            .disabled(enlargedPoster != nil)
            .accessibilityHidden(enlargedPoster != nil)

            // Edit modal — scrim + bottom form card OVER the still-visible
            // detail (ConfirmAlertOverlay pattern; `.sheet` doesn't render in
            // a MenuBarExtra popover). Deliberately not a NavigationStack
            // push: that nudged the whole popover down by the collapsed nav
            // bar's height, which read as the window jumping.
            #if os(macOS)
            if let req = editRequest {
                MediaEditModalOverlay(request: req, onDismiss: { editRequest = nil })
                    .zIndex(6)
            }
            if let req = deleteRequest {
                MediaDeleteModalOverlay(request: req,
                                        onDismiss: { deleteRequest = nil },
                                        onDeleted: handleDeleted)
                    .zIndex(7)
            }
            #endif
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
        .task(id: trailerLookupToken) { await resolveTrailer() }
        .task(id: searchWatchToken) { await watchSearchState() }
        // When the row leaves the arr queue (import finished / removed) while
        // the detail is open, the queue view stops backing it — refetch so the
        // panel flips from the stale download state to the on-disk library
        // file. Silent (no spinner): the surface is already populated.
        .onChange(of: isInLiveQueue) { _, stillQueued in
            if !stillQueued, item.arrQueueId != 0 {
                Task { await load(showSpinner: false) }
            }
            // A grab is the search's real conclusion, and it lands here before
            // the command list catches up — drop the indicator now rather than
            // letting it linger over a row that's visibly downloading. Also
            // refetch: an item added seconds ago opened on a synthetic stub, so
            // this is the first point where there's a real record to show.
            if stillQueued {
                withAnimation(.easeInOut(duration: 0.2)) { searchRunning = false }
                if item.arrQueueId == 0 {
                    Task { await load(showSpinner: false) }
                }
            }
        }
        // Secondary actions live in the system toolbar — destructive
        // cancel + open-in-browser. Primary action (pause/resume) stays
        // on the sticky bottom CTA so the main verb sits under the
        // thumb / cursor where users expect it.
        // Trash + Safari go in the trailing toolbar cluster. Upgrade/New
        // badge stays in the hero (see headerCard's titleBadge param)
        // because macOS NavigationStack toolbar refuses to render non-
        // interactive views — we ran the experiment three times.
        // iOS-only toolbar host: macOS self-draws these in `header` (the popover
        // has no NSToolbar for `.toolbar` actions; the detached window self-draws).
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { headerActionsMenu }
        }
        #endif
        // Toolbar title carries the *item* identity — title + year —
        // instead of the generic source name, so the user always sees
        // what they're looking at in the chevron header. The hero card
        // below drops its own title/year duplication to stay clean.
        // In the DETACHED window we draw our own header (back + title + Safari),
        // so the NavigationStack title would stack a duplicate bar on top —
        // suppress it there. The menu-bar panel + iOS keep the native chevron.
        #if os(iOS)
        .navigationTitle(navTitleString)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS draws its own header (see `header`); hide the popover's native
        // NavigationStack chevron + title so they aren't duplicated. The detached
        // window has none to begin with (hand-built NSWindow), so this is a no-op
        // there.
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        // Cast-head → person view, owned here so back returns to this detail.
        .personDestination($personRef)
        // Album header's artist tap — push the artist's album list.
        .navigationDestination(item: $artistDrill) { artistItem in
            LidarrArtistView(
                item: artistItem,
                onBack: { artistDrill = nil },
                originLabel: originLabel,
                viewModel: viewModel
            )
        }
        // Season drill-down — push SeasonDetailView (its episodes + that season's
        // search buttons). The bottom search CTA there is unambiguous because the
        // user is *inside* the season.
        .navigationDestination(item: $seasonDrill) { drill in
            SeasonDetailView(
                drill: drill,
                sonarrDetail: sonarrDetail,
                episodes: sonarrEpisodes.filter { $0.seasonNumber == drill.seasonNumber },
                queueByEpisodeId: sonarrQueueByEpisodeId,
                fileByEpisodeFileId: sonarrEpisodeFiles,
                seriesPosterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                                              mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []) ?? item.posterURL,
                seriesPosterRequiresAuth: item.posterRequiresAuth,
                seriesPosterAPIKey: configStore.sonarr.apiKey,
                onBack: { seasonDrill = nil },
                viewModel: viewModel,
                onSetSeasonMonitored: { monitored in
                    await setSeasonMonitored(seasonNumber: drill.seasonNumber, monitored: monitored)
                },
                onSetEpisodeMonitored: { episodeId, monitored in
                    if let idx = sonarrEpisodes.firstIndex(where: { $0.id == episodeId }) {
                        sonarrEpisodes[idx].monitored = monitored
                    }
                    do {
                        try await configStore.sonarrClient
                            .setEpisodesMonitored(episodeIds: [episodeId], monitored: monitored)
                    } catch {
                        await load(showSpinner: false)
                    }
                }
            )
        }
        // iOS gets the edit panel as a native sheet — the modal treatment the
        // overlay approximates on macOS.
        #if os(iOS)
        .sheet(item: $editRequest) { req in
            // Detents live inside the panel: only it knows how many rows this
            // source puts on screen.
            MediaEditPanel(request: req, onBack: { editRequest = nil })
        }
        .sheet(item: $deleteRequest) { req in
            MediaDeletePanel(request: req,
                             onCancel: { deleteRequest = nil },
                             onDeleted: handleDeleted)
        }
        #endif
        // Manual-search ("Download") drill-down — releases for this movie/album.
        .navigationDestination(item: $manualSearchTarget) { target in
            ReleaseListView(target: target,
                            existing: manualSearchExistingFile,
                            existingByEpisode: manualSearchEpisodeFiles(for: target),
                            waitContext: manualSearchContext,
                            onBack: { manualSearchTarget = nil })
        }
        // "Show history" — this record's events only, titled after it.
        .navigationDestination(isPresented: $historyShown) {
            HistoryView(source: item.source, entityId: item.entityId, title: navTitleString,
                        viewModel: viewModel, onClose: { historyShown = false })
        }
        // Inline confirmation — replaces `.confirmationDialog` because
        // the system dialog steals focus from MenuBarExtra(.window),
        // which auto-dismisses the panel. The inline overlay renders
        // inside the panel so the panel keeps focus.
        .inlineConfirm(
            isPresented: $ctaPendingDelete,
            title: "Remove this download?",
            message: LocalizedStringKey("This will remove the download from the client."),
            confirmLabel: "Remove",
            isDestructive: true,
            onConfirm: {
                Task {
                    await viewModel.delete(item)
                    await MainActor.run { onBack() }
                }
            }
        )
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

    @ViewBuilder
    private var header: some View {
        // macOS draws its OWN header (back + title + Safari) on BOTH surfaces so
        // the menu-bar popover matches the detached window and iOS. The detached
        // NSWindow never renders the native chevron; in the popover we hide the
        // native chevron (`.toolbar(.hidden, for: .windowToolbar)` in `body`) and
        // replace it with this. iOS keeps the native nav bar + `.toolbar` instead.
        #if os(macOS)
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)
                .keyboardShortcut(.cancelAction)
            Text(navTitleString)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Cluster: search, then everything else behind "...". Monitor
            // moved out to the poster's top-right corner — see `headerCard`.
            headerSearchMenu
            Menu {
                if let target = editTarget {
                    Button { editRequest = target } label: {
                        Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                    }
                }
                if item.entityId != nil {
                    Button { historyShown = true } label: {
                        Label { Text("detail.showHistory.button", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
                    }
                }
                if let url = arrWebURL(for: item, in: configStore) {
                    Button { PlatformURLOpener.open(url) } label: {
                        Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
                    }
                }
                // Own section, last: the destructive item doesn't sit next to
                // "open in browser" where a mis-click costs a library record.
                if let target = deleteTarget {
                    Section {
                        Button(role: .destructive) { deleteRequest = target } label: {
                            Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(Text("common.moreActions.button", bundle: .module))
            .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }

    /// What the header's Edit item edits. Nil for Lidarr ALBUM details — the
    /// editable Lidarr entity is the artist (profiles / root folder live on
    /// it), so Edit lives in `LidarrArtistView` instead.
    private var editTarget: MediaEditRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaEditRequest(source: item.source, entityId: entityId)
    }

    /// Same record Edit edits, addressed for removal. Lidarr is excluded
    /// for the same reason: this surface's Lidarr entity is an ALBUM, and the
    /// deletable library record is its artist — that lives in `LidarrArtistView`.
    private var deleteTarget: MediaDeleteRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaDeleteRequest(source: item.source, entityId: entityId, title: navTitleString)
    }

    /// The record is gone from the arr: close the modal, drop its queue rows,
    /// and leave the detail — it describes something that no longer exists.
    private func handleDeleted() {
        deleteRequest = nil
        Task { await viewModel.refresh() }
        onBack()
    }

    #if os(iOS)
    /// Every header action behind one "..." — four glyphs in a row were eating
    /// most of the bar, which is why the title had almost no width and truncated
    /// on anything longer than a short name. Search is flattened in rather than
    /// nested as a submenu: two items do not earn a second level.
    private var headerActionsMenu: some View {
        Menu {
            if let target = editTarget {
                Button { editRequest = target } label: {
                    Label { Text("detail.edit.button", bundle: .module) } icon: { Image(systemName: "pencil") }
                }
            }
            if item.entityId != nil {
                Button { historyShown = true } label: {
                    Label { Text("detail.showHistory.button", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            if manualTarget != nil {
                Section {
                    Button { startAutomaticSearch() } label: {
                        Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
                    }
                    .disabled(autoSearching || searchRunning)
                    Button { manualSearchTarget = manualTarget } label: {
                        Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
                    }
                    .disabled(autoSearching || searchRunning)
                }
            }
            if let url = arrWebURL(for: item, in: configStore) {
                Button { PlatformURLOpener.open(url) } label: {
                    Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
                }
            }
            // Own section, last: destructive items don't sit next to "open in
            // browser" where a mis-tap costs a library record.
            if let target = deleteTarget {
                Section {
                    Button(role: .destructive) { deleteRequest = target } label: {
                        Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                    }
                }
            }
        } label: {
            // A running search still has to be visible without opening the menu.
            if autoSearching || searchRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
    }
    #endif

    /// The Search choice, relocated from the bottom CTA strip into the header
    /// action cluster (leads it, ahead of the "..." menu).
    @ViewBuilder
    private var headerSearchMenu: some View {
        if let target = manualTarget {
            HeaderSearchMenu(
                inFlight: autoSearching || searchRunning,
                didQueue: autoDidSearch,
                onAutomatic: { startAutomaticSearch() },
                onManual: { manualSearchTarget = target }
            )
        }
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

    /// What the bottom "Manual search" opens — a movie / album release list.
    /// nil for a Sonarr series: its search lives per-season inside SeasonDetailView.
    private var manualTarget: ManualSearchTarget? {
        guard let entityId = item.entityId else { return nil }
        switch item.source {
        case .radarr, .whisparr: return .movie(source: item.source, movieId: entityId, title: navTitleString)
        case .lidarr: return .album(albumId: entityId, title: navTitleString)
        case .sonarr: return nil
        }
    }

    /// The on-disk file a manual search from here would be replacing — the
    /// baseline `ReleaseListView` diffs its candidates against. Movies only: a
    /// Lidarr album is many track files with no single "current" one, and a
    /// Sonarr series doesn't open manual search from this level at all.
    private var manualSearchContext: WaitCardContext {
        WaitCardContext(movie: radarrDetail, series: sonarrDetail, album: lidarrAlbum,
                        cast: cast, directors: directors, posterURL: item.posterURL,
                        posterApiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil)
    }

    private var manualSearchExistingFile: UpgradeDiffView.Side? {
        switch item.source {
        case .radarr, .whisparr:
            // Same fallback as RadarrDetailPanel's banner: prefer the separately
            // fetched file (it carries customFormats), fall back to the stripped
            // inline one from /movie/{id}.
            guard let file = radarrMovieFile ?? radarrDetail?.movieFile else { return nil }
            return UpgradeDiffView.side(file: file)
        case .sonarr, .lidarr:
            return nil
        }
    }

    /// What each episode of the searched season already has on disk, keyed by
    /// episode number. A season search has no single baseline — a pack replaces
    /// many files — but its per-episode rows each diff against their own file.
    private func manualSearchEpisodeFiles(for target: ManualSearchTarget) -> [Int: UpgradeDiffView.Side] {
        guard item.source == .sonarr,
              let season = target.query.first(where: { $0.name == "seasonNumber" })?.value.flatMap(Int.init)
        else { return [:] }
        var out: [Int: UpgradeDiffView.Side] = [:]
        for episode in sonarrEpisodes where episode.seasonNumber == season {
            guard let number = episode.episodeNumber,
                  let file = episode.episodeFileId.flatMap({ sonarrEpisodeFiles[$0] }) else { continue }
            out[number] = UpgradeDiffView.side(episodeFile: file)
        }
        return out
    }

    /// Fire the server-side sweep and drive the CTA's state machine:
    /// spinner (in flight) → checkmark (queued) → spinner (sweep running).
    private func startAutomaticSearch() {
        guard !autoSearching, !searchRunning else { return }
        Task {
            autoSearching = true
            await runAutomaticSearch()
            autoSearching = false
            autoDidSearch = true
            // Assume it's running rather than waiting for the next poll to
            // notice — the command was just accepted, and a CTA that goes
            // idle for three seconds before the indicator appears reads as
            // "nothing happened" and invites a second tap.
            searchRunning = true
            searchWatchToken += 1
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            autoDidSearch = false
        }
    }

    /// Poll the arr for "is a search for this record still running".
    ///
    /// Bounded on purpose. The window restarts on every poll that *sees* a
    /// running search, so a slow indexer keeps the indicator alive for as long
    /// as it needs, but a detail left open on a settled item stops polling
    /// instead of tapping the server forever.
    private func watchSearchState() async {
        guard let entityId = item.entityId, item.source != .sonarr,
              let client = searchClient() else { return }
        var deadline = Date().addingTimeInterval(Self.searchWatchWindow)
        while !Task.isCancelled, Date() < deadline {
            let running = await client.isSearchRunning(entityId: entityId)
            if running != searchRunning {
                withAnimation(.easeInOut(duration: 0.2)) { searchRunning = running }
            }
            if running { deadline = Date().addingTimeInterval(Self.searchWatchWindow) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        if searchRunning {
            withAnimation(.easeInOut(duration: 0.2)) { searchRunning = false }
        }
    }

    /// How long to keep asking before assuming nothing is running. Comfortably
    /// longer than a normal indexer sweep, and refreshed while one is live.
    private static let searchWatchWindow: TimeInterval = 180

    private func searchClient() -> (any ArrAPIClient)? {
        item.source == .sonarr ? nil : configStore.arrClient(for: item.source)
    }

    /// Fire the arr's own "search now" command for this movie / album — the
    /// indexer search runs server-side. (Series search is per-season in
    /// SeasonDetailView, so Sonarr never reaches the bottom CTA here.)
    private func runAutomaticSearch() async {
        guard let entityId = item.entityId else { return }
        do {
            switch item.source {
            case .radarr:
                try await configStore.radarrClient.searchMovie(movieId: entityId)
            case .whisparr:
                try await configStore.whisparrClient
                    .postCommand(["name": "MoviesSearch", "movieIds": [entityId]])
            case .lidarr:
                try await configStore.lidarrClient.searchAlbum(albumId: entityId)
            case .sonarr:
                break
            }
        } catch {}
    }

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
                // Destructive Cancel anchors the trailing edge, away from the
                // primary verb — small and icon-only so it can't be mistaken
                // for the thing you actually came to press. Both platforms:
                // burying it in the "..." menu on iOS made the one-download
                // case need two taps for an action that is right there.
                cancelGlassCompact
            }
            // Inline-confirm attached to body instead of here so the
            // overlay fires regardless of whether the bottom CTA strip
            // is visible — toolbar trash button uses the same
            // `ctaPendingDelete` state.
        }
    }

    private enum CancelCTAMetrics {
        #if os(iOS)
        static let vPadding: CGFloat = 13
        static let glyph: CGFloat = 14
        #else
        static let vPadding: CGFloat = 7
        static let glyph: CGFloat = 13
        #endif
    }

    /// Compact icon-only cancel: red glyph on a glass square, the same height
    /// as the prominent CTA beside it but no wider than it needs to be —
    /// cancelling is the rare action, so it doesn't get a text slot.
    private var cancelGlassCompact: some View {
        Button {
            PanelActivation.bringForward(); ctaPendingDelete = true
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: CancelCTAMetrics.glyph, weight: .bold)
                .foregroundStyle(.red)
                .frame(width: 26)
                // Must match `PauseResumeButton`'s own padding, or the two
                // buttons sitting side by side come out different heights.
                .padding(.vertical, CancelCTAMetrics.vPadding)
        }
        // Matches the pause/resume capsule beside it — see `GlassTintedButtonStyle`.
        .modifier(GlassTintedButtonStyle())
        .tint(.red)
        .help(Text("queue.cancelDownload.button", bundle: .module))
        .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
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
        let showsPlay = focusedShowsPlay
        PauseResumeButton(
            isPaused: showsPlay,
            progress: f.source == .sonarr ? 1 : f.progress,
            // Tint by the ACTION, not the status: Pause orange, Resume blue
            // (Search moved to the header, so blue is free again). Red stays
            // Cancel's.
            tint: showsPlay ? .blue : .orange
        ) {
            if showsPlay {
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

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        // No monolithic spinner: the panel renders immediately from the lean
        // `item` (poster / title / queue status), and each data-driven section
        // shows its own skeleton (via `metadataLoading` on the hero +
        // `isLoading` on the panel) until its fetch lands — so the view fills
        // in element-by-element instead of gating behind one centred spinner.
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
                    posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore,
                                     mediaServerKeys: radarrDetail?.mediaServerKeys ?? []),
                    fallbackSymbol: "film",
                    posterAspect: 2.0/3.0,
                    metadataLoading: loading,
                    titleBadge: movieTitleBadge
                )
                RadarrDetailPanel(
                    item: item,
                    radarrDetail: radarrDetail,
                    radarrMovieFile: radarrMovieFile,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    isLoading: loading,
                    header: movieHeader,
                    cast: cast,
                    onTapPerson: openPerson,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) },
                    onPauseItem: { q in Task { await viewModel.pause(q); await viewModel.refresh() } },
                    onResumeItem: { q in Task { await viewModel.resume(q); await viewModel.refresh() } },
                    onDeleteItem: { q in Task { await viewModel.delete(q) } }
                )
            case .sonarr:
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
                    posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                                              mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []),
                    fallbackSymbol: "tv",
                    posterAspect: 2.0/3.0,
                    metadataLoading: loading,
                    // Any episode file on disk makes the series library-owned.
                    titleBadge: seriesTitleBadge,
                    // A series has no single director — TMDB's `created_by` is
                    // the credit that answers the same question.
                    directedByKey: "detail.createdBy.label"
                )
                SonarrDetailPanel(
                    item: item,
                    siblings: siblings,
                    loadError: loadError,
                    isLoading: loading,
                    header: seriesHeader,
                    cast: cast,
                    onTapPerson: openPerson,
                    sonarrDetail: $sonarrDetail,
                    onTapSeason: { season in
                        seasonDrill = SeasonDrill(
                            seriesId: item.entityId ?? 0,
                            seasonNumber: season.seasonNumber,
                            seriesTitle: sonarrDetail?.title ?? titleFallback.title,
                            seriesYear: sonarrDetail?.year ?? titleFallback.year
                        )
                    },
                    onSetSeasonMonitored: { season, monitored in
                        await setSeasonMonitored(seasonNumber: season.seasonNumber, monitored: monitored)
                    },
                    onAutomaticSeasonSearch: { season in
                        try? await configStore.sonarrClient.searchSeason(
                            seriesId: item.entityId ?? 0, seasonNumber: season.seasonNumber)
                    },
                    onManualSeasonSearch: { season in
                        manualSearchTarget = .season(
                            seriesId: item.entityId ?? 0,
                            seasonNumber: season.seasonNumber,
                            title: seasonSearchTitle(season.seasonNumber))
                    }
                )
            case .lidarr:
                LidarrDetailPanel(
                    item: item,
                    lidarrAlbum: lidarrAlbum,
                    lidarrTracks: lidarrTracks,
                    lidarrTrackFiles: lidarrTrackFiles,
                    siblings: siblings,
                    hasActiveDownloads: hasActiveDownloads,
                    loadError: loadError,
                    isLoading: loading,
                    enlargedPoster: $enlargedPoster,
                    selectedDiscNumber: $selectedDiscNumber,
                    arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) },
                    onPauseItem: { q in Task { await viewModel.pause(q); await viewModel.refresh() } },
                    onResumeItem: { q in Task { await viewModel.resume(q); await viewModel.refresh() } },
                    onDeleteItem: { q in Task { await viewModel.delete(q) } },
                    posterCornerAction: monitorPosterToggle,
                    onOpenArtist: { artist in
                        artistDrill = DetailRequest.syntheticArtistItem(
                            artistId: artist.id,
                            name: artist.artistName,
                            posterURL: arrPosterURL(images: artist.images, for: item, in: configStore),
                            posterRequiresAuth: item.posterRequiresAuth
                        )
                    }
                )
            }
    }

    /// Movie hero's title-slot badges: the "library" membership chip plus
    /// the release-status chip ("Released" / "In cinemas"). Release status
    /// is a fact of the TITLE, so it lives here next to the library label —
    /// not down in the existing-file banner, which describes one file.
    private var movieTitleBadge: AnyView? {
        let release = ArrReleaseStatusLabel.text(radarrDetail?.status, locale: configStore.currentLocale)
        // Nothing to say until the detail lands — a bare "Missing" while the
        // fetch is still in flight would be a claim we can't back yet.
        guard radarrDetail != nil || qualityProfileName != nil else { return nil }
        // Profile leads, then release status, then state — matching the series
        // hero, where the profile has always come first. It is the setting you
        // came to check; the release status is background.
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            if let release { TagChip(text: release) }
            if radarrDetail != nil {
                MediaStateChip(state: movieFileState, locale: configStore.currentLocale)
            }
        })
    }

    /// Downloaded / Missing, rather than the old "library" tag. Membership is
    /// implied — you can't have a file for something you don't own — and the
    /// tag left the question you actually opened the panel with unanswered.
    private var movieFileState: LibraryEntry.FileState {
        .movie(monitored: radarrDetail?.monitored,
               hasFile: (radarrMovieFile ?? radarrDetail?.movieFile) != nil)
    }

    /// Series hero's title badges — assigned profile + how much is on disk.
    private var seriesTitleBadge: AnyView? {
        guard sonarrDetail != nil || qualityProfileName != nil else { return nil }
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            // No have/total here: the season rows below already carry the count
            // per season, which is the number you can act on. A partial series
            // has nothing to say in one word, so it shows no chip at all.
            if sonarrDetail != nil, seriesFileState != .partial {
                MediaStateChip(state: seriesFileState, locale: configStore.currentLocale)
            }
        })
    }

    /// Files on disk vs episodes expected, summed from the season statistics —
    /// the arr's own numbers, which is what makes this agree with the Library
    /// tab. Counting `sonarrEpisodes` instead would call every ongoing series
    /// half-missing, since unaired episodes are in that list too.
    private var seriesEpisodeCounts: EpisodeFileCounts {
        sonarrDetail?.episodeFileCounts ?? EpisodeFileCounts(have: 0, total: 0)
    }

    private var seriesFileState: LibraryEntry.FileState {
        .series(monitored: sonarrDetail?.monitored, counts: seriesEpisodeCounts)
    }

    // MARK: - Trailer

    /// Re-resolves when the item changes AND when the detail payload lands —
    /// the ids the lookup needs (Radarr's trailer id, the series' tmdb/tvdb
    /// ids) only exist after `load()`, so keying on `item.id` alone would
    /// always look up nothing.
    private var trailerLookupToken: String {
        switch item.source {
        case .radarr, .whisparr:
            return "movie:\(item.id):\(radarrDetail?.youTubeTrailerId ?? "-"):\(radarrDetail?.tmdbId ?? 0)"
        case .sonarr:
            return "series:\(item.id):\(sonarrDetail?.tmdbId ?? 0):\(sonarrDetail?.tvdbId ?? 0)"
        case .lidarr:
            return "none:\(item.id)"
        }
    }

    private func resolveTrailer() async {
        // A new title must not keep the previous one's clip on screen — but
        // only OUR clip: on a fresh mount `trailerKey` is nil and a session
        // restored across a popover reopen must be left alone.
        if let old = trailerKey, trailerSession.key == old { trailerSession.dismiss() }
        trailerKey = nil
        switch item.source {
        case .radarr, .whisparr:
            trailerKey = await TrailerProvider.movieTrailerKey(
                radarrTrailerId: radarrDetail?.youTubeTrailerId,
                tmdbId: radarrDetail?.tmdbId,
                configStore: configStore
            )
        case .sonarr:
            trailerKey = await TrailerProvider.seriesTrailerKey(
                tmdbId: sonarrDetail?.tmdbId,
                tvdbId: sonarrDetail?.tvdbId,
                configStore: configStore
            )
        case .lidarr:
            break
        }
    }

    /// The badge in the poster's corner — only once a clip is actually known,
    /// so it never sits there dead.
    private var trailerBadge: AnyView? {
        guard let trailerKey else { return nil }
        return AnyView(
            TrailerPosterBadge(isPlaying: trailerSession.key == trailerKey) {
                withAnimation(.smooth(duration: 0.22)) {
                    trailerSession.toggle(trailerKey)
                }
            }
        )
    }

    private func movieRatingChipsFor(_ detail: RadarrMovieDetail?) -> [RatingChip] {
        guard let r = detail?.ratings else { return [] }
        // Radarr's detail payload carries no imdbId, so the IMDb pill links
        // to the site's search; TMDB gets a direct record link via tmdbId.
        let title = detail?.title ?? splitTitleAndYear(item.title).title
        return [
            r.imdb?.value.flatMap { RatingChip.imdb($0, linkTitle: title, votes: r.imdb?.votes) },
            r.tmdb?.value.flatMap { RatingChip.tmdb($0, linkTitle: title, tmdbId: detail?.tmdbId,
                                                    votes: r.tmdb?.votes) },
            r.rottenTomatoes?.value.flatMap {
                RatingChip.rottenTomatoes($0, linkTitle: title, votes: r.rottenTomatoes?.votes)
            },
            r.metacritic?.value.flatMap {
                RatingChip.metacritic($0, linkTitle: title, votes: r.metacritic?.votes)
            },
        ].compactMap { $0 }
    }

    private func sonarrRatingChipsFor(_ detail: SonarrSeriesDetail?) -> [RatingChip] {
        guard let r = detail?.ratings, let v = r.value else { return [] }
        // Sonarr's rating is TVDB-sourced — link to the TVDB series page
        // (the detail payload has no tvdbId here, so it goes via search).
        let title = detail?.title ?? splitTitleAndYear(item.title).title
        return [RatingChip.tvdb(v, linkTitle: title, votes: r.votes)].compactMap { $0 }
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
        posterAspect: CGFloat,
        metadataLoading: Bool = false,
        titleBadge: AnyView? = nil,
        /// "Directed by" for a movie, "Created by" for a series — the hero's
        /// credit line reads differently for each.
        directedByKey: LocalizedStringKey = "detail.directedBy.label"
    ) -> some View {
        heroCard(
            title: title, year: year, runtime: runtime, genres: genres,
            certification: certification, ratings: ratings, overview: overview,
            existingTrailer: existingTrailer, posterUrl: posterUrl,
            fallbackSymbol: fallbackSymbol, posterAspect: posterAspect,
            metadataLoading: metadataLoading, titleBadge: titleBadge,
            directedByKey: directedByKey
        )
    }

    @ViewBuilder
    private func heroCard(
        title: String,
        year: Int?,
        runtime: Int?,
        genres: [String],
        certification: String?,
        ratings: [RatingChip],
        overview: String?,
        existingTrailer: AnyView?,
        posterUrl: URL?,
        fallbackSymbol: String,
        posterAspect: CGFloat,
        metadataLoading: Bool,
        titleBadge: AnyView?,
        directedByKey: LocalizedStringKey = "detail.directedBy.label"
    ) -> some View {
        MediaHeaderCard(
            title: title,
            year: year,
            runtime: runtime,
            network: nil,
            certification: certification,
            // Straight off the view's state rather than a parameter: every
            // caller wants the country of the title this view is showing.
            countries: countries,
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
            // Library chip (owned titles) — moved up here from beside the
            // existing-file banner: membership is a property of the title.
            titleBadge: titleBadge,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = url ?? item.posterURL
                }
            },
            posterBadge: trailerBadge,
            posterCornerAction: monitorPosterToggle,
            watched: isWatched,
            // Title + year live in the nav-bar title now; hero hides
            // its in-card title to avoid duplication.
            showTitle: false,
            metadataLoading: metadataLoading,
            // Straight off the view's state, like `countries` above.
            directedBy: directors,
            directedByKey: directedByKey,
            onTapPerson: openPerson
        )
    }

    /// Has the media server played this title? Asked of the fetched record's
    /// own provider ids, with the queue row's precomputed answer as the
    /// fallback for the frame before the record lands.
    private var isWatched: Bool {
        let keys = radarrDetail?.mediaServerKeys ?? sonarrDetail?.mediaServerKeys ?? []
        return keys.isEmpty ? item.watched : MediaServerIndex.shared.isWatched(keys)
    }

    // MARK: - Loading

    /// `/qualityprofile` name for an id — nil on any failure (the chip
    /// simply doesn't render). Shared lookup (SearchClient.profileNameMap).
    private static func profileName(id: Int?, config: ServiceConfig, source: QueueItem.Source) async -> String? {
        guard let id else { return nil }
        return await SearchClient.profileNameMap(config: config, source: source)[id]
    }

    private func load(showSpinner: Bool = true) async {
        if showSpinner { loading = true }
        loadError = nil
        defer { if showSpinner { loading = false } }
        guard let entityId = item.entityId else {
            loadError = "No entity id"
            return
        }
        do {
            switch item.source {
            case .radarr:
                let client = configStore.radarrClient
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
                qualityProfileName = await Self.profileName(
                    id: radarrDetail?.qualityProfileId, config: configStore.radarr, source: .radarr)
                async let movieCountries = CountryProvider.movieCountries(
                    tmdbId: radarrDetail?.tmdbId, configStore: configStore)
                let movieCredits = await CastProvider.movieCredits(
                    radarrMovieId: entityId, tmdbId: radarrDetail?.tmdbId, configStore: configStore)
                cast = movieCredits.cast
                directors = movieCredits.directors
                countries = await movieCountries
            case .sonarr:
                let client = configStore.sonarrClient
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                async let files = (try? client.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                sonarrDetail = try await d
                sonarrEpisodes = try await eps
                episodeIdBySlot = Dictionary(
                    sonarrEpisodes.compactMap { ep in
                        guard let sn = ep.seasonNumber, let en = ep.episodeNumber else { return nil }
                        return (EpisodeSlot(season: sn, episode: en), ep.id)
                    },
                    // A series listing the same slot twice keeps the first
                    // record — the one the episode list renders.
                    uniquingKeysWith: { first, _ in first }
                )
                sonarrEpisodeFiles = await files
                qualityProfileName = await Self.profileName(
                    id: sonarrDetail?.qualityProfileId, config: configStore.sonarr, source: .sonarr)
                async let seriesCountries = CountryProvider.seriesCountries(
                    tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
                let seriesCredits = await CastProvider.seriesCredits(
                    tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
                cast = seriesCredits.cast
                directors = seriesCredits.directors
                countries = await seriesCountries
            case .lidarr:
                let client = configStore.lidarrClient
                async let a = client.fetchAlbumDetails(id: entityId)
                async let ts = client.fetchTracks(albumId: entityId)
                async let fs = client.fetchTrackFiles(albumId: entityId)
                lidarrAlbum = try await a
                lidarrTracks = try await ts
                lidarrTrackFiles = (try? await fs) ?? []
            case .whisparr:
                let client = configStore.whisparrClient
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
                qualityProfileName = await Self.profileName(
                    id: radarrDetail?.qualityProfileId, config: configStore.whisparr, source: .whisparr)            }
        } catch {
            loadError = "Couldn't load details: \(error.localizedDescription)"
        }
    }

}

extension View {
    /// Applies `.navigationTitle` only when `apply` is true. The detail surfaces
    /// (DetailView / EpisodeDetailOverlay / EpisodeQuickDetail) use this to DROP
    /// the macOS NavigationStack title in the DETACHED window, where they already
    /// draw their own in-content header — the nav title would otherwise stack a
    /// second, duplicate title bar on top.
    @ViewBuilder
    func conditionalNavTitle(_ title: String, apply: Bool) -> some View {
        if apply { navigationTitle(title) } else { self }
    }
}

