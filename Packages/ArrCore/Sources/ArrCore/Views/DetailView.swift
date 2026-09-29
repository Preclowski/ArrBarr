import SwiftUI
import os
import MediaKit

/// Detail for a queue item or lookup — replaces the popover content while shown.
struct DetailView: View {
    private static let searchLog = Logger(category: "Detail")
    let item: QueueItem
    let onBack: () -> Void
    var viewModel: QueueViewModel
    /// The record went from the library; the host drops whatever still lists it.
    let onDeleted: (() -> Void)?
    @Environment(ConfigStore.self) var configStore

    init(
        item: QueueItem,
        onBack: @escaping () -> Void,
        viewModel: QueueViewModel,
        onDeleted: (() -> Void)? = nil
    ) {
        self.item = item
        self.onBack = onBack
        self.viewModel = viewModel
        self.onDeleted = onDeleted
    }

    /// All queue items of the same arr entity; more than one renders a stacked list.
    var siblings: [QueueItem] {
        let pool = viewModel.items(for: item.source)
        guard let id = item.entityId else { return [item] }
        let matched = pool.filter { $0.entityId == id }
        if !matched.isEmpty { return matched }
        // A real queue row (arrQueueId != 0) that left the queue finished importing or was
        // removed — don't resurrect its stale snapshot; a synthetic open keeps its item.
        return item.arrQueueId != 0 ? [] : [item]
    }

    var nextEpisode: ArrEpisode? {
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
    var focused: QueueItem {
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
    var hasActiveDownloads: Bool {
        siblings.contains { $0.arrQueueId != 0 }
    }

    /// >1 (a duplicate grab) drops the bottom pause/cancel — they act on `focused` only;
    /// the list rows control each download.
    private var activeDownloadCount: Int {
        siblings.count { $0.arrQueueId != 0 }
    }

    @State var radarrDetail: ArrMovie?
    /// Radarr's `/movie/{id}` strips customFormats from `movieFile`; `/moviefile` has them.
    @State var radarrMovieFile: ArrFile?
    @State var sonarrDetail: ArrSeries?
    @State var sonarrEpisodes: [ArrEpisode] = []
    /// Ids only, never payloads — `monitored` is flipped optimistically in `sonarrEpisodes`
    /// and a second copy would go stale.
    @State var episodeIdBySlot: [EpisodeSlot: Int] = [:]
    /// Lets downloaded episode rows show their custom-format score instead of the air date.
    @State var sonarrEpisodeFiles: [Int: ArrFile] = [:]
    @State var lidarrAlbum: ArrAlbum?
    @State var lidarrTracks: [ArrTrack] = []
    @State var lidarrTrackFiles: [ArrFile] = []
    /// Movies from Radarr's `/credit`; series from TMDB only (Sonarr has no cast endpoint).
    @State var cast: [CastMember] = []
    /// A movie's director(s), a series' creator(s).
    @State var directors: [CastMember] = []
    /// ISO 3166-1; TMDB-only — neither arr carries it.
    @State var countries: [String] = []
    @State var qualityProfileName: String?
    @State var loading = true
    @State var loadError: String?
    /// Owned locally so back returns here.
    @State private var personRef: PersonRef?
    /// Owned locally (like `personRef`) so back returns to this album.
    @State var artistDrill: QueueItem?

    @State var enlargedPoster: URL?
    /// Nil = no badge (no trailer, or no TMDB key for the series path).
    @State var trailer: TrailerReel?
    /// Shared session, so the clip survives the popover closing mid-play.
    var trailerSession: TrailerSession { .shared }
    @State var seasonDrill: SeasonDrill?
    @State var manualSearchTarget: ManualSearchTarget?
    @State var actionState = DetailActionState()
    @State var searchFeedback: SearchFeedback = .idle
    /// The server is running an indexer search for this record — including the one the arr
    /// starts by itself on add, which the app never triggered.
    @State var searchRunning = false
    /// Bumped to restart the watcher, so a search started long after opening is still watched.
    @State var searchWatchToken = 0
    /// `nil` = the first disc with missing tracks, else the lowest disc.
    @State var selectedDiscNumber: Int?

    @State var ctaPendingDelete = false

    // MARK: - Download action gating
    // Same conditions as QueueRowView.canControl / canPauseResume.
    var canControl: Bool {
        // Needs a configured, reachable download client, and a reachable arr — stale data
        // means the action can't land.
        configStore.canControlDownload(item) && !viewModel.lastUnreachable.contains(item.source)
    }

    var canPauseResume: Bool {
        let s = focused.status
        return s == .downloading || s == .paused || s == .queued
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
    var monitorPosterToggle: AnyView? {
        guard let state = monitorState else { return nil }
        return AnyView(
            MonitorPosterToggle(isMonitored: state.isMonitored, entity: state.entity) { monitored in
                await setTopLevelMonitored(monitored)
            }
        )
    }

    /// `PersonRef` init fails only for the rare credit without a TMDB id.
    func openPerson(_ member: CastMember) {
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

    func seasonSearchTitle(_ seasonNumber: Int) -> String {
        let season = String(format: String(localized: "detail.seasonLld.label", bundle: .module), seasonNumber)
        return "\(sonarrDetail?.title ?? splitTitleAndYear(item.title).title) · \(season)"
    }

    /// Optimistic flip, then Sonarr, then a refetch either way: success cascades to every
    /// episode server-side, failure snaps back. Shared by the season list and the season screen.
    func setSeasonMonitored(seasonNumber: Int, monitored: Bool) async {
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
            Self.searchLog.error("season monitor flip failed: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
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
        }
        .detailActionsHost($actionState) { _ in handleDeleted() }
        .onDetailIntent(for: item.id, ready: !loading) { detailActions.carryOut($0, state: $actionState) }
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
                },
                onSeriesDeleted: { handleDeleted() },
                onEpisodeFileDeleted: { Task { await load(showSpinner: false) } }
            )
        }
        .navigationDestination(item: $manualSearchTarget) { target in
            ReleaseListView(target: target,
                            existing: manualSearchExistingFile,
                            existingByEpisode: manualSearchEpisodeFiles(for: target),
                            waitContext: manualSearchContext,
                            onBack: { manualSearchTarget = nil })
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
    var navTitleString: String {
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

}

extension View {
    /// Drops the macOS nav title in the detached window, which draws its own header.
    @ViewBuilder
    func conditionalNavTitle(_ title: String, apply: Bool) -> some View {
        if apply { navigationTitle(title) } else { self }
    }
}

