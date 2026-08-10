import SwiftUI

/// Hashable marker for "push the series DetailView for this queue item"
/// nav action. Lives next to `EpisodeQuickDetail` since the only place
/// that pushes one is the episode hero's series-title tap.
public struct SeriesPushRequest: Hashable {
    public let queueItemId: String
    public let source: QueueItem.Source
    /// Carried verbatim so the destination can render DetailView without
    /// having to refetch the QueueItem from the view model.
    public let item: QueueItem

    public init(item: QueueItem) {
        self.queueItemId = item.id
        self.source = item.source
        self.item = item
    }

    public static func == (lhs: SeriesPushRequest, rhs: SeriesPushRequest) -> Bool {
        lhs.queueItemId == rhs.queueItemId
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(queueItemId)
    }
}

/// Direct-entry episode detail used when the user taps a Sonarr queue
/// row that's for a specific episode. Skips the intermediate Series
/// (DetailView) level — the user lands straight on the episode they
/// were downloading. The series view is reachable via the "series name
/// >" chevron-tap in the EpisodeDetailOverlay hero, which pushes
/// DetailView through a local `.navigationDestination(item:)`.
///
/// Owns the Sonarr fetch (series details + episodes + episode file map)
/// so EpisodeDetailOverlay below can render the same hero / sticky CTA
/// it does inside DetailView. Stub data built from the queue row lets
/// the hero render immediately while the fetch is in flight.
public struct EpisodeQuickDetail: View {
    let item: QueueItem
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    /// Breadcrumb label threaded into the series DetailView this view
    /// pushes (so its toolbar back-target reads the same tab name).
    var originLabel: LocalizedStringKey = "Details"

    @Environment(\.isDetachedWindow) private var isDetachedWindow
    /// Pops this episode push in the detached window, where the wrapped
    /// EpisodeDetailOverlay's own back button (its only back affordance there)
    /// fires `onClose`. The attached panel pops via the native nav chevron.
    @Environment(\.dismiss) private var dismiss

    @State private var sonarrDetail: SonarrSeriesDetail?
    @State private var fullEpisode: SonarrEpisodeDetail?
    @State private var episodeFileMap: [Int: SonarrEpisodeFile] = [:]
    @State private var loadError: String?
    /// Series drill-down. Owned HERE (not at the root NavigationStack)
    /// so the series push nests as a CHILD of this episode view: the
    /// back chevron then pops series → episode → queue, instead of
    /// collapsing straight to the queue. Sibling `navigationDestination`
    /// bindings at the root don't nest, which is what broke "back".
    @State private var seriesPush: SeriesPushRequest?
    /// All of the series' episodes (kept from `load`) so the hero's season link
    /// can push a fully-populated `SeasonDetailView`.
    @State private var allEpisodes: [SonarrEpisodeDetail] = []
    /// Season drill-down — pushed when the user taps the hero's "Season N" link.
    /// Nests under THIS view (like `seriesPush`) so back returns to the episode.
    @State private var seasonPush: SeasonDrill?

    public init(
        item: QueueItem,
        viewModel: QueueViewModel,
        originLabel: LocalizedStringKey = "Details"
    ) {
        self.item = item
        self.viewModel = viewModel
        self.originLabel = originLabel
    }

    public var body: some View {
        // No full-view spinner: render the overlay immediately from the stub
        // built off the queue row (hero = series · SxxExx · poster · download
        // status); `isLoadingDetails` skeletons the episode title / overview
        // until the Sonarr fetch lands.
        EpisodeDetailOverlay(
            episode: displayEpisode,
            seriesTitle: sonarrDetail?.title ?? splitTitleAndYear(item.title).title,
            posterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
            posterRequiresAuth: item.posterRequiresAuth,
            apiKey: configStore.sonarr.apiKey,
            episodeFile: displayEpisode.episodeFileId.flatMap { episodeFileMap[$0] },
            queueItems: liveQueueItems,
            onClose: { dismiss() },
            onSearch: { episodeId in
                let client = SonarrClient(config: configStore.sonarr)
                try? await client.searchEpisodes(episodeIds: [episodeId])
            },
            warningActionURL: arrWebURL(for: item, in: configStore),
            onPauseEpisode: { q in await viewModel.pause(q); await viewModel.refresh() },
            onResumeEpisode: { q in await viewModel.resume(q); await viewModel.refresh() },
            onDeleteEpisode: { q in Task { await viewModel.delete(q) } },
            onTapSeries: { seriesPush = SeriesPushRequest(item: item) },
            onTapSeason: {
                seasonPush = SeasonDrill(
                    seriesId: item.entityId ?? 0,
                    seasonNumber: item.seasonNumber ?? 0,
                    seriesTitle: sonarrDetail?.title ?? splitTitleAndYear(item.title).title,
                    seriesYear: sonarrDetail?.year ?? splitTitleAndYear(item.title).year
                )
            },
            seriesYear: sonarrDetail?.year ?? splitTitleAndYear(item.title).year,
            isLoadingDetails: fullEpisode == nil && loadError == nil,
            // Live off `displayEpisode` (which tracks the `fullEpisode` state),
            // not a captured value — the stub carries `monitored: nil` so no
            // bookmark shows until the real record lands.
            monitored: displayEpisode.monitored
        )
        .conditionalNavTitle(sonarrDetail?.title ?? splitTitleAndYear(item.title).title, apply: !isDetachedWindow)
        // Series push nests under THIS view (see `seriesPush`), so back
        // returns to the episode rather than the queue.
        .navigationDestination(item: $seriesPush) { req in
            DetailView(
                item: req.item,
                onBack: { seriesPush = nil },
                originLabel: originLabel,
                viewModel: viewModel
            )
        }
        // Season push nests under THIS view too, so back returns to the episode.
        .navigationDestination(item: $seasonPush) { drill in
            SeasonDetailView(
                drill: drill,
                sonarrDetail: sonarrDetail,
                episodes: allEpisodes.filter { $0.seasonNumber == drill.seasonNumber },
                queueByEpisodeId: seasonQueueByEpisodeId,
                fileByEpisodeFileId: episodeFileMap,
                seriesPosterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
                seriesPosterRequiresAuth: item.posterRequiresAuth,
                seriesPosterAPIKey: configStore.sonarr.apiKey,
                onBack: { seasonPush = nil },
                viewModel: viewModel
            )
        }
        .task(id: item.id) { await load() }
        // When the episode leaves the queue (import done / removed) while the
        // detail is open, refetch so the overlay swaps the stale download view
        // for the on-disk file (fresh `fullEpisode.hasFile` + episode-file map).
        .onChange(of: isInLiveQueue) { _, stillQueued in
            if !stillQueued, item.arrQueueId != 0 {
                Task { await load() }
            }
        }
    }

    /// Live queue rows pulled from the view model, mirroring `DetailView`. The
    /// `item` handed in via `navigationDestination` is a static open-time
    /// snapshot (the binding never re-reads the queue), so reading the pool
    /// here lets every background refresh advance the progress bar.
    ///
    /// ALL active downloads for this episode (same series + season/episode),
    /// not just the row the view was opened on — a duplicate grab stays
    /// visible in the overlay. The opened row is moved to the front so the
    /// hero keeps tracking it. Empty once every row leaves the queue (import
    /// finished / removed) — we deliberately DON'T fall back to the captured
    /// snapshot, which is frozen at e.g. "importing"; empty lets
    /// `EpisodeDetailOverlay` fall through to the on-disk file section
    /// (which the `onChange` refetch below populates).
    private var liveQueueItems: [QueueItem] {
        var matches = viewModel.items(for: item.source).filter {
            $0.arrQueueId != 0
                && $0.entityId == item.entityId
                && $0.seasonNumber == item.seasonNumber
                && $0.episodeNumber == item.episodeNumber
        }
        if let idx = matches.firstIndex(where: {
            $0.id == item.id || ($0.arrQueueId != 0 && $0.arrQueueId == item.arrQueueId)
        }), idx != 0 {
            matches.swapAt(0, idx)
        }
        return matches
    }

    /// Whether the opened row is still a live queue row — flips false the moment
    /// the import completes and the arr drops it, cueing a detail refetch.
    private var isInLiveQueue: Bool {
        viewModel.items(for: item.source)
            .contains { $0.id == item.id || $0.arrQueueId == item.arrQueueId }
    }

    /// Either the fetched-from-Sonarr episode (full data) or a stub
    /// built straight from queue metadata so the hero has something to
    /// render while the fetch is in flight.
    private var displayEpisode: SonarrEpisodeDetail {
        fullEpisode ?? SonarrEpisodeDetail(
            id: 0,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            title: nil,
            overview: nil,
            airDateUtc: nil,
            hasFile: nil,
            monitored: nil,
            runtime: nil,
            episodeFileId: nil
        )
    }

    /// episode-id → all active queue items for this series — feeds
    /// SeasonDetailView's per-episode download indicators when pushed from
    /// the hero's season link. List-valued so duplicate grabs stay visible.
    private var seasonQueueByEpisodeId: [Int: [QueueItem]] {
        guard let id = item.entityId else { return [:] }
        var map: [Int: [QueueItem]] = [:]
        for q in viewModel.items(for: .sonarr) where q.entityId == id && q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let ep = allEpisodes.first(where: { $0.seasonNumber == sn && $0.episodeNumber == en }) {
                map[ep.id, default: []].append(q)
            }
        }
        return map
    }

    private func load() async {
        guard let seriesId = item.entityId else { return }
        let client = SonarrClient(config: configStore.sonarr)
        do {
            async let detailReq = client.fetchSeriesDetails(id: seriesId)
            async let episodesReq = client.fetchEpisodes(seriesId: seriesId)
            async let filesReq = client.fetchEpisodeFileMap(seriesId: seriesId)
            let detail = try await detailReq
            let episodes = try await episodesReq
            let files = try await filesReq
            self.sonarrDetail = detail
            self.allEpisodes = episodes
            self.fullEpisode = episodes.first {
                $0.seasonNumber == item.seasonNumber
                    && $0.episodeNumber == item.episodeNumber
            }
            self.episodeFileMap = files
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
