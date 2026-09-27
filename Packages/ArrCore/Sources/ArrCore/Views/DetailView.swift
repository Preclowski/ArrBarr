import SwiftUI
import os
import MediaKit

/// Detail for a queue item or lookup — replaces the popover content while shown.
struct DetailView: View {
    private static let searchLog = Logger(category: "Detail")
    let item: QueueItem
    let onBack: () -> Void
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    init(
        item: QueueItem,
        onBack: @escaping () -> Void,
        viewModel: QueueViewModel
    ) {
        self.item = item
        self.onBack = onBack
        self.viewModel = viewModel
    }

    /// All queue items of the same arr entity; more than one renders a stacked list.
    private var siblings: [QueueItem] {
        let pool = viewModel.items(for: item.source)
        guard let id = item.entityId else { return [item] }
        let matched = pool.filter { $0.entityId == id }
        if !matched.isEmpty { return matched }
        // A real queue row (arrQueueId != 0) that left the queue finished importing or was
        // removed — don't resurrect its stale snapshot; a synthetic open keeps its item.
        return item.arrQueueId != 0 ? [] : [item]
    }

    private var nextEpisode: ArrEpisode? {
        let now = Date()
        return sonarrEpisodes
            .compactMap { ep -> (ArrEpisode, Date)? in
                guard (ep.seasonNumber ?? 0) > 0,
                      let air = ep.airDateUtc.flatMap(parseArrDate), air > now else { return nil }
                return (ep, air)
            }
            .min { $0.1 < $1.1 }?.0
    }

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

    /// Live re-read of `item` from `viewModel.items`; the init snapshot goes stale after a
    /// poll or an optimistic Pause/Resume, so CTAs must use this.
    private var focused: QueueItem {
        let pool = viewModel.items(for: item.source)
        return pool.first { isSameRow($0) } ?? pool.first { $0.succeeds(item) } ?? pool.first { isSameEntity($0) } ?? item
    }

    /// Guarded against 0: synthetic and non-queue items all carry `arrQueueId` 0.
    private func isSameRow(_ candidate: QueueItem) -> Bool {
        candidate.id == item.id || (candidate.arrQueueId != 0 && candidate.arrQueueId == item.arrQueueId)
    }

    /// Matches a queue row by record id, so a detail opened right after "Add" notices its
    /// download starting. Not Sonarr: there `entityId` is the series, shared by every episode row.
    private func isSameEntity(_ candidate: QueueItem) -> Bool {
        guard item.arrQueueId == 0, item.source != .sonarr,
              let entityId = item.entityId else { return false }
        return candidate.entityId == entityId
    }

    /// Flips false when an import finishes and the arr drops the row — the cue to refetch.
    private var isInLiveQueue: Bool {
        viewModel.items(for: item.source).contains { isSameRow($0) || $0.succeeds(item) || isSameEntity($0) }
    }

    /// False for a synthetic open (chat card / upcoming tap): a 0% progress bar would mislead.
    private var hasActiveDownloads: Bool {
        siblings.contains { $0.arrQueueId != 0 }
    }

    /// >1 (a duplicate grab) drops the bottom pause/cancel — they act on `focused` only;
    /// the list rows control each download.
    private var activeDownloadCount: Int {
        siblings.count { $0.arrQueueId != 0 }
    }

    @State private var radarrDetail: ArrMovie?
    /// Radarr's `/movie/{id}` strips customFormats from `movieFile`; `/moviefile` has them.
    @State private var radarrMovieFile: ArrFile?
    @State private var sonarrDetail: ArrSeries?
    @State private var sonarrEpisodes: [ArrEpisode] = []
    /// Ids only, never payloads — `monitored` is flipped optimistically in `sonarrEpisodes`
    /// and a second copy would go stale.
    @State private var episodeIdBySlot: [EpisodeSlot: Int] = [:]
    /// Lets downloaded episode rows show their custom-format score instead of the air date.
    @State private var sonarrEpisodeFiles: [Int: ArrFile] = [:]
    @State private var lidarrAlbum: ArrAlbum?
    @State private var lidarrTracks: [ArrTrack] = []
    @State private var lidarrTrackFiles: [ArrFile] = []
    /// Movies from Radarr's `/credit`; series from TMDB only (Sonarr has no cast endpoint).
    @State private var cast: [CastMember] = []
    /// A movie's director(s), a series' creator(s).
    @State private var directors: [CastMember] = []
    /// ISO 3166-1; TMDB-only — neither arr carries it.
    @State private var countries: [String] = []
    @State private var qualityProfileName: String?
    @State private var loading = true
    @State private var loadError: String?
    /// Owned locally so back returns here.
    @State private var personRef: PersonRef?
    /// Owned locally (like `personRef`) so back returns to this album.
    @State private var artistDrill: QueueItem?

    @State private var enlargedPoster: URL?
    /// Nil = no badge (no trailer, or no TMDB key for the series path).
    @State private var trailer: TrailerReel?
    /// Shared session, so the clip survives the popover closing mid-play.
    @ObservedObject private var trailerSession = TrailerSession.shared
    @State private var seasonDrill: SeasonDrill?
    @State private var manualSearchTarget: ManualSearchTarget?
    @State private var editRequest: MediaEditRequest?
    @State private var deleteRequest: MediaDeleteRequest?
    @State private var historyShown = false
    @State private var searchFeedback: SearchFeedback = .idle
    /// The server is running an indexer search for this record — including the one the arr
    /// starts by itself on add, which the app never triggered.
    @State private var searchRunning = false
    /// Bumped to restart the watcher, so a search started long after opening is still watched.
    @State private var searchWatchToken = 0
    /// `nil` = the first disc with missing tracks, else the lowest disc.
    @State private var selectedDiscNumber: Int?

    // MARK: - Download action gating
    // Same conditions as QueueRowView.canControl / canPauseResume.
    private var canControl: Bool {
        // Needs a configured, reachable download client, and a reachable arr — stale data
        // means the action can't land.
        configStore.canControlDownload(item.downloadProtocol) && !viewModel.lastUnreachable.contains(item.source)
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

    /// `nil` when the arr (or a fork like Whisparr V3) doesn't report the flag, or while
    /// loading — no bookmark beats one asserting a state we never learned.
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

    /// On the poster rather than the header: monitoring is a property of the title, not a chrome action.
    private var monitorPosterToggle: AnyView? {
        guard let state = monitorState else { return nil }
        return AnyView(
            MonitorPosterToggle(isMonitored: state.isMonitored, entity: state.entity) { monitored in
                await setTopLevelMonitored(monitored)
            }
        )
    }

    /// `PersonRef` init fails only for the rare credit without a TMDB id.
    private func openPerson(_ member: CastMember) {
        if let ref = PersonRef(castMember: member) { personRef = ref }
    }

    /// Optimistic write so the bookmark moves under the finger; a failure refetches to snap back.
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

    private func seasonSearchTitle(_ seasonNumber: Int) -> String {
        let season = String(format: String(localized: "detail.seasonLld.label", bundle: .module), seasonNumber)
        return "\(sonarrDetail?.title ?? splitTitleAndYear(item.title).title) · \(season)"
    }

    /// Optimistic flip, then Sonarr, then a refetch either way: success cascades to every
    /// episode server-side, failure snaps back. Shared by the season list and the season screen.
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
        } catch {
            // The refetch below snaps the optimistic flip back; the reason only reaches the log.
            Self.searchLog.error("season monitor flip failed: \(error.localizedDescription, privacy: .public)")
        }
        await load(showSpinner: false)
    }

    var body: some View {
        // This view's Lidarr path treats `entityId` as an ALBUM id; an artist id here would
        // fetch an unrelated album.
        if item.isLidarrArtistLookup {
            LidarrArtistView(
                item: item,
                onBack: onBack,
                viewModel: viewModel
            )
        } else {
            detailBody
        }
    }

    private var detailBody: some View {
        ZStack {
            VStack(spacing: 0) {
                // Stacked, not a `safeAreaBar`: the system never drew the soft scroll-edge blur on this
                // surface, so content vanished under the header with no seam.
                header
                ScrollView {
                    content
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // With duplicate downloads each list row controls its own, so no strip.
                    if hasActiveDownloads, activeDownloadCount == 1, canControl, canPauseResume {
                        downloadCTAStrip
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // Parked while the lightbox is up (see PopoverContentView — hiding alone isn't parking).
            // The lightbox sits outside this ZStack, so disabling can't reach its dismiss gestures.
            .opacity(enlargedPoster != nil ? 0 : 1)
            .allowsHitTesting(enlargedPoster == nil)
            .disabled(enlargedPoster != nil)
            .accessibilityHidden(enlargedPoster != nil)

            // `.sheet` doesn't render in a MenuBarExtra popover, and a NavigationStack push nudged the
            // popover down by the collapsed nav bar's height.
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
        .posterLightbox(
            url: $enlargedPoster,
            apiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil,
            aspectRatio: item.source == .lidarr ? 1.0 : 2.0 / 3.0
        )
        .task(id: item.id) { await load() }
        .task(id: trailerLookupToken) { await resolveTrailer() }
        .task(id: searchWatchToken) { await watchSearchState() }
        // The row left the queue (import finished / removed): refetch silently so the panel
        // shows the on-disk file instead of the stale download.
        .onChange(of: isInLiveQueue) { _, stillQueued in
            if !stillQueued, item.arrQueueId != 0 {
                Task { await load(showSpinner: false) }
            }
            // A grab lands here before the command list catches up — drop the indicator now. Refetch
            // too: an item added seconds ago opened on a synthetic stub.
            if stillQueued {
                withAnimation(.easeInOut(duration: 0.2)) { searchRunning = false }
                if item.arrQueueId == 0 {
                    Task { await load(showSpinner: false) }
                }
            }
        }
        // macOS self-draws these in `header`: the popover has no NSToolbar for `.toolbar` actions.
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { headerActionsMenu }
        }
        #endif
        // The detached window draws its own header, so a nav title there would stack a duplicate bar.
        #if os(iOS)
        .navigationTitle(navTitleString)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS draws its own header; hide the popover's native chevron so it isn't duplicated.
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        // Owned here so back returns to this detail.
        .personDestination($personRef)
        .navigationDestination(item: $artistDrill) { artistItem in
            LidarrArtistView(
                item: artistItem,
                onBack: { artistDrill = nil },
                viewModel: viewModel
            )
        }
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
        #if os(iOS)
        .sheet(item: $editRequest) { req in
            // Detents live inside the panel: only it knows how many rows this source shows.
            MediaEditPanel(request: req, onBack: { editRequest = nil })
        }
        .sheet(item: $deleteRequest) { req in
            MediaDeletePanel(request: req,
                             onCancel: { deleteRequest = nil },
                             onDeleted: handleDeleted)
        }
        #endif
        .navigationDestination(item: $manualSearchTarget) { target in
            ReleaseListView(target: target,
                            existing: manualSearchExistingFile,
                            existingByEpisode: manualSearchEpisodeFiles(for: target),
                            waitContext: manualSearchContext,
                            onBack: { manualSearchTarget = nil })
        }
        .navigationDestination(isPresented: $historyShown) {
            HistoryView(source: item.source, entityId: item.entityId, title: navTitleString,
                        viewModel: viewModel, onClose: { historyShown = false })
        }
        // Not `.confirmationDialog`: the system dialog steals focus and MenuBarExtra(.window)
        // auto-dismisses.
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

    /// Falls back to the queue-row title (usually already "(YYYY)") until the fetch lands.
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
        // Self-drawn on both macOS surfaces: the detached NSWindow has no native chevron and the
        // popover's is hidden in `body`.
        #if os(macOS)
        HStack(spacing: 6) {
            FloatingBackButton(action: onBack)
                .keyboardShortcut(.cancelAction)
            Text(navTitleString)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
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
                // Last, own section: a mis-click next to "open in browser" would cost a library record.
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

    /// Nil for Lidarr albums — the editable entity is the artist, edited in `LidarrArtistView`.
    private var editTarget: MediaEditRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaEditRequest(source: item.source, entityId: entityId)
    }

    /// Lidarr excluded: the deletable record is the artist, handled in `LidarrArtistView`.
    private var deleteTarget: MediaDeleteRequest? {
        guard item.source != .lidarr, let entityId = item.entityId else { return nil }
        return MediaDeleteRequest(source: item.source, entityId: entityId, title: navTitleString)
    }

    private func handleDeleted() {
        deleteRequest = nil
        Task { await viewModel.refresh() }
        onBack()
    }

    #if os(iOS)
    /// All header actions behind one "..." — separate glyphs left the title too little width.
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
                    .disabled(searchFeedback.isSending || searchRunning)
                    Button { manualSearchTarget = manualTarget } label: {
                        Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
                    }
                    .disabled(searchFeedback.isSending || searchRunning)
                }
            }
            if let url = arrWebURL(for: item, in: configStore) {
                Button { PlatformURLOpener.open(url) } label: {
                    Label { Text("detail.openInBrowser.button", bundle: .module) } icon: { Image(systemName: "safari") }
                }
            }
            // Last, own section: a mis-tap next to "open in browser" would cost a library record.
            if let target = deleteTarget {
                Section {
                    Button(role: .destructive) { deleteRequest = target } label: {
                        Label { Text("detail.delete.button", bundle: .module) } icon: { Image(systemName: "trash") }
                    }
                }
            }
        } label: {
            if searchFeedback.isSending || searchRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityLabel(Text("common.moreActions.button", bundle: .module))
    }
    #endif

    @ViewBuilder
    private var headerSearchMenu: some View {
        if let target = manualTarget {
            HeaderSearchMenu(
                feedback: searchRunning ? .sending : searchFeedback,
                onAutomatic: { startAutomaticSearch() },
                onManual: { manualSearchTarget = target }
            )
        }
    }

    // MARK: - Download CTA strip
    @State private var ctaPendingDelete = false

    /// nil for a Sonarr series: its search lives per-season inside SeasonDetailView.
    private var manualTarget: ManualSearchTarget? {
        guard let entityId = item.entityId else { return nil }
        switch item.source {
        case .radarr, .whisparr: return .movie(source: item.source, movieId: entityId, title: navTitleString)
        case .lidarr: return .album(albumId: entityId, title: navTitleString)
        case .sonarr: return nil
        }
    }

    /// The file a manual search would replace. Movies only: an album has no single file and a
    /// series doesn't open manual search from this level.
    private var manualSearchContext: WaitCardContext {
        WaitCardContext(movie: radarrDetail, series: sonarrDetail, album: lidarrAlbum,
                        cast: cast, directors: directors, posterURL: item.posterURL,
                        posterApiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil)
    }

    private var manualSearchExistingFile: UpgradeDiffView.Side? {
        switch item.source {
        case .radarr, .whisparr:
            // Prefer the separately fetched file (it carries customFormats) over the stripped inline one.
            guard let file = radarrMovieFile ?? radarrDetail?.movieFile else { return nil }
            return UpgradeDiffView.side(file: file)
        case .sonarr, .lidarr:
            return nil
        }
    }

    /// A season pack has no single baseline, so each episode row diffs against its own file.
    private func manualSearchEpisodeFiles(for target: ManualSearchTarget) -> [Int: UpgradeDiffView.Side] {
        guard item.source == .sonarr,
              let season = target.season
        else { return [:] }
        var out: [Int: UpgradeDiffView.Side] = [:]
        for episode in sonarrEpisodes where episode.seasonNumber == season {
            guard let number = episode.episodeNumber,
                  let file = episode.episodeFileId.flatMap({ sonarrEpisodeFiles[$0] }) else { continue }
            out[number] = UpgradeDiffView.side(file: file)
        }
        return out
    }

    /// Drives the CTA: spinner (in flight) → checkmark (queued) → spinner (sweep running).
    private func startAutomaticSearch() {
        guard !searchRunning else { return }
        SearchFeedback.run($searchFeedback) {
            try await runAutomaticSearch()
            // Show it running now, or the CTA idles until the next poll and invites a second tap.
            searchRunning = true
            searchWatchToken += 1
        }
    }

    /// Bounded: each poll that sees a running search restarts the window, but a settled item
    /// stops polling instead of tapping the server forever.
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

    /// Comfortably longer than a normal indexer sweep, and refreshed while one is live.
    private static let searchWatchWindow: TimeInterval = 180

    private func searchClient() -> (any ArrAPIClient)? {
        item.source == .sonarr ? nil : configStore.arrClient(for: item.source)
    }

    /// Movie / album only — series search is per-season in SeasonDetailView.
    private func runAutomaticSearch() async throws {
        guard let entityId = item.entityId else { return }
        switch item.source {
        case .radarr: try await configStore.radarrClient.searchMovie(movieId: entityId)
        case .whisparr: try await configStore.whisparrClient.searchMovie(movieId: entityId)
        case .lidarr: try await configStore.lidarrClient.searchAlbum(albumId: entityId)
        case .sonarr: break
        }
    }

    @ViewBuilder
    private var downloadCTAStrip: some View {
        let hasDownloadControls = hasActiveDownloads && canControl
        if hasDownloadControls, canPauseResume {
            HStack(spacing: 8) {
                pauseResumeProminent
                // Small and icon-only so it can't be mistaken for the primary verb.
                cancelGlassCompact
            }
            // The inline confirm is attached to body so the toolbar trash can use it too.
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

    private var cancelGlassCompact: some View {
        Button {
            PanelActivation.bringForward(); ctaPendingDelete = true
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: CancelCTAMetrics.glyph, weight: .bold)
                .foregroundStyle(.red)
                .frame(width: 26)
                // Must match `PauseResumeButton`'s padding, or the two buttons differ in height.
                .padding(.vertical, CancelCTAMetrics.vPadding)
        }
        .modifier(GlassTintedButtonStyle())
        .tint(.red)
        .help(Text("queue.cancelDownload.button", bundle: .module))
        .accessibilityLabel(Text("queue.cancelDownload.button", bundle: .module))
    }

    // MARK: - CTA strip sub-views

    @ViewBuilder
    private var pauseResumeProminent: some View {
        let f = focused
        let showsPlay = focusedShowsPlay
        PauseResumeButton(
            isPaused: showsPlay,
            progress: f.source == .sonarr ? 1 : f.progress,
            // Tint by the action, not the status; red stays Cancel's.
            tint: showsPlay ? .blue : .orange
        ) {
            if showsPlay {
                await viewModel.resume(f)
            } else {
                await viewModel.pause(f)
            }
            // Poll now so the status flip lands before the spinner releases, or the label reverts
            // until the next scheduled refresh.
            await viewModel.refresh()
        }
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        // No monolithic spinner: each section shows its own skeleton until its fetch lands.
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
                    // A series has no single director — TMDB's `created_by` answers the same question.
                    directedByKey: "detail.createdBy.label"
                )
                SonarrDetailPanel(
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
                        try await configStore.sonarrClient.searchSeason(
                            seriesId: item.entityId ?? 0, seasonNumber: season.seasonNumber)
                    },
                    onManualSeasonSearch: { season in
                        manualSearchTarget = .season(
                            seriesId: item.entityId ?? 0,
                            seasonNumber: season.seasonNumber,
                            title: seasonSearchTitle(season.seasonNumber))
                    },
                    nextEpisode: nextEpisode,
                    posterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                                            mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []) ?? item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth,
                    posterAPIKey: configStore.sonarr.apiKey
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
                        guard let artistId = artist.id, let name = artist.artistName else { return }
                        artistDrill = DetailRequest.syntheticArtistItem(
                            artistId: artistId,
                            name: name,
                            posterURL: arrPosterURL(images: artist.images, for: item, in: configStore),
                            posterRequiresAuth: item.posterRequiresAuth
                        )
                    }
                )
            }
    }

    /// Release status is a fact of the title, so it sits here, not in the file banner.
    private var movieTitleBadge: AnyView? {
        let release = ArrReleaseStatusLabel.text(radarrDetail?.status, locale: configStore.currentLocale)
        // Nothing until the detail lands — a bare "Missing" mid-fetch would be a claim we can't back.
        guard radarrDetail != nil || qualityProfileName != nil else { return nil }
        // Profile first, matching the series hero.
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            if let release { TagChip(text: release) }
            if radarrDetail != nil {
                MediaStateChip(state: movieFileState, locale: configStore.currentLocale)
            }
        })
    }

    private var movieFileState: LibraryEntry.FileState {
        .movie(monitored: radarrDetail?.monitored,
               hasFile: (radarrMovieFile ?? radarrDetail?.movieFile) != nil)
    }

    /// Series hero's title badges — assigned profile + how much is on disk.
    private var seriesTitleBadge: AnyView? {
        guard sonarrDetail != nil || qualityProfileName != nil else { return nil }
        return AnyView(HStack(spacing: 4) {
            if let profile = qualityProfileName { ProfileChip(name: profile) }
            // No have/total: the season rows carry the actionable count, and a partial series has
            // nothing to say in one word.
            if sonarrDetail != nil, seriesFileState != .partial {
                MediaStateChip(state: seriesFileState, locale: configStore.currentLocale)
            }
        })
    }

    /// From the season statistics, matching the Library tab; counting `sonarrEpisodes` would
    /// call every ongoing series half-missing (unaired episodes are listed too).
    private var seriesEpisodeCounts: EpisodeFileCounts {
        sonarrDetail?.episodeFileCounts ?? EpisodeFileCounts(have: 0, total: 0)
    }

    private var seriesFileState: LibraryEntry.FileState {
        .series(monitored: sonarrDetail?.monitored, counts: seriesEpisodeCounts)
    }

    // MARK: - Trailer

    /// Keyed on the payload too: the ids the lookup needs only exist after `load()`.
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
        // Dismiss only OUR clip: on a fresh mount `trailer` is nil and a session restored across
        // a popover reopen must be left alone.
        if trailerSession.isShowing(trailer) { trailerSession.dismiss() }
        trailer = nil
        switch item.source {
        case .radarr, .whisparr:
            trailer = await TrailerProvider.movieReel(
                radarrTrailerId: radarrDetail?.youTubeTrailerId,
                tmdbId: radarrDetail?.tmdbId,
                configStore: configStore
            )
        case .sonarr:
            trailer = await TrailerProvider.seriesReel(
                tmdbId: sonarrDetail?.tmdbId,
                tvdbId: sonarrDetail?.tvdbId,
                configStore: configStore
            )
        case .lidarr:
            break
        }
    }

    /// Only once a clip is known, so it never sits there dead.
    private var trailerBadge: AnyView? {
        guard let trailer else { return nil }
        return AnyView(
            TrailerPosterBadge(isPlaying: trailerSession.isShowing(trailer)) {
                withAnimation(.smooth(duration: 0.22)) {
                    trailerSession.toggle(trailer)
                }
            }
        )
    }

    private func movieRatingChipsFor(_ detail: ArrMovie?) -> [RatingChip] {
        guard let r = detail?.ratings else { return [] }
        // Radarr's payload has no imdbId, so IMDb links to a search; TMDB links via tmdbId.
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

    private func sonarrRatingChipsFor(_ detail: ArrSeries?) -> [RatingChip] {
        guard let r = detail?.ratings, let v = r.value else { return [] }
        // Sonarr's rating is TVDB-sourced and the payload has no tvdbId, so link via search.
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
        existingTrailer: AnyView?,
        posterUrl: URL?,
        fallbackSymbol: String,
        posterAspect: CGFloat,
        metadataLoading: Bool = false,
        titleBadge: AnyView? = nil,
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
            titleBadge: titleBadge,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) {
                    enlargedPoster = url ?? item.posterURL
                }
            },
            posterBadge: trailerBadge,
            posterCornerAction: monitorPosterToggle,
            watched: isWatched,
            // Title + year live in the nav-bar title.
            showTitle: false,
            metadataLoading: metadataLoading,
            directedBy: directors,
            directedByKey: directedByKey,
            onTapPerson: openPerson
        )
    }

    /// Falls back to the queue row's precomputed answer until the record lands.
    private var isWatched: Bool {
        let keys = radarrDetail?.mediaServerKeys ?? sonarrDetail?.mediaServerKeys ?? []
        return keys.isEmpty ? item.watched : MediaServerIndex.shared.isWatched(keys)
    }

    // MARK: - Loading

    /// nil on any failure — the chip simply doesn't render.
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
                // `/movie/{id}` omits customFormats on the inline movieFile; on failure (older Radarr)
                // the inline one still backs the banner.
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
                    // A duplicated slot keeps the first record — the one the episode list renders.
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
                do { lidarrTrackFiles = try await fs } catch {
                    Logger.extras.debug("lidarr track files failed: \(error.localizedDescription, privacy: .public)")
                    lidarrTrackFiles = []
                }
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
    /// Drops the macOS nav title in the detached window, which draws its own header.
    @ViewBuilder
    func conditionalNavTitle(_ title: String, apply: Bool) -> some View {
        if apply { navigationTitle(title) } else { self }
    }
}

