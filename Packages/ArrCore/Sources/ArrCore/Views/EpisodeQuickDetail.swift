import SwiftUI
import os
import MediaKit

public struct SeriesPushRequest: Hashable {
    public let queueItemId: String
    /// Carried verbatim so DetailView needn't refetch the item.
    public let item: QueueItem

    public init(item: QueueItem) {
        self.queueItemId = item.id
        self.item = item
    }

    public static func == (lhs: SeriesPushRequest, rhs: SeriesPushRequest) -> Bool {
        lhs.queueItemId == rhs.queueItemId
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(queueItemId)
    }
}

/// Queue rows carry season/episode numbers, not the episode id.
struct EpisodeSlot: Hashable {
    let season: Int
    let episode: Int
}

/// Opens straight on the episode a Sonarr queue row downloads; the hero's
/// series link pushes DetailView. Renders from a queue-row stub while loading.
struct EpisodeQuickDetail: View {
    private static let log = Logger(category: "Detail")
    let item: QueueItem
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    @Environment(\.isDetachedWindow) private var isDetachedWindow
    /// Not `@Environment(\.dismiss)`: reading it in a `navigationDestination`
    /// body re-renders it every display cycle (~85 Hz).
    var onBack: () -> Void

    @State private var sonarrDetail: ArrSeries?
    @State private var cast: [CastMember] = []
    @State private var profileName: String?
    @State private var fullEpisode: ArrEpisode?
    @State private var episodeFileMap: [Int: ArrFile] = [:]
    @State private var loadError: String?
    /// Owned here, not at the root stack: sibling root destinations don't nest,
    /// so back would skip the episode.
    @State private var seriesPush: SeriesPushRequest?
    @State private var allEpisodes: [ArrEpisode] = []
    /// Nests under this view like `seriesPush`, so back returns to the episode.
    @State private var seasonPush: SeasonDrill?
    @State private var mediaServerSeasonPoster: URL?
    /// Ids only, never episodes: `monitored` is flipped optimistically in
    /// `allEpisodes`, and a second copy would render stale.
    @State private var episodeIdBySlot: [EpisodeSlot: Int] = [:]

    init(
        item: QueueItem,
        viewModel: QueueViewModel,
        onBack: @escaping () -> Void
    ) {
        self.item = item
        self.viewModel = viewModel
        self.onBack = onBack
    }

    var body: some View {
        // No spinner: the queue-row stub renders now; `isLoadingDetails` skeletons the rest.
        EpisodeDetailOverlay(
            episode: displayEpisode,
            seriesTitle: sonarrDetail?.title ?? splitTitleAndYear(item.title).title,
            posterURL: mediaServerSeasonPoster ?? seriesPosterURL,
            posterRequiresAuth: mediaServerSeasonPoster == nil && item.posterRequiresAuth,
            apiKey: configStore.sonarr.apiKey,
            episodeFile: displayEpisode.episodeFileId.flatMap { episodeFileMap[$0] },
            queueItems: liveQueueItems,
            onClose: onBack,
            onSearch: { episodeId in
                let client = configStore.sonarrClient
                try await client.searchEpisodes(episodeIds: [episodeId])
            },
            seriesWebURL: arrWebURL(for: item, in: configStore),
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
            cast: cast,
            genres: sonarrDetail?.genres ?? [],
            certification: sonarrDetail?.certification,
            seriesTmdbId: sonarrDetail?.tmdbId,
            seriesTvdbId: sonarrDetail?.tvdbId,
            profileName: profileName,
            mediaServerKeys: sonarrDetail?.mediaServerKeys ?? [],
            isLoadingDetails: fullEpisode == nil && loadError == nil,
            // The stub carries `monitored: nil`, so no bookmark until the real record lands.
            monitored: displayEpisode.monitored,
            onToggleMonitored: { monitored in
                // id 0 is the pre-fetch stub.
                guard let epId = fullEpisode?.id, epId != 0 else { return }
                fullEpisode?.monitored = monitored
                if let idx = allEpisodes.firstIndex(where: { $0.id == epId }) {
                    allEpisodes[idx].monitored = monitored
                }
                do {
                    try await configStore.sonarrClient
                        .setEpisodesMonitored(episodeIds: [epId], monitored: monitored)
                } catch {
                    await load()
                }
            },
            onFileDeleted: { Task { await load() } },
            intentItemID: item.id
        )
        .conditionalNavTitle(sonarrDetail?.title ?? splitTitleAndYear(item.title).title, apply: !isDetachedWindow)
        .navigationDestination(item: $seriesPush) { req in
            DetailView(
                item: req.item,
                onBack: { seriesPush = nil },
                viewModel: viewModel,
                // The episode page under it belongs to the series just deleted.
                onDeleted: {
                    Task { await viewModel.refresh() }
                    onBack()
                }
            )
        }
        .navigationDestination(item: $seasonPush) { drill in
            SeasonDetailView(
                drill: drill,
                sonarrDetail: sonarrDetail,
                episodes: allEpisodes.filter { $0.seasonNumber == drill.seasonNumber },
                queueByEpisodeId: seasonQueueByEpisodeId,
                fileByEpisodeFileId: episodeFileMap,
                seriesPosterURL: seriesPosterURL,
                seriesPosterRequiresAuth: item.posterRequiresAuth,
                seriesPosterAPIKey: configStore.sonarr.apiKey,
                onBack: { seasonPush = nil },
                viewModel: viewModel,
                onSetSeasonMonitored: { monitored in
                    if var seasons = sonarrDetail?.seasons,
                       let idx = seasons.firstIndex(where: { $0.seasonNumber == drill.seasonNumber }) {
                        seasons[idx].monitored = monitored
                        sonarrDetail?.seasons = seasons
                    }
                    do {
                        try await configStore.sonarrClient.setSeasonMonitored(
                            seriesId: drill.seriesId, seasonNumber: drill.seasonNumber, monitored: monitored)
                    } catch {
                        Self.log.error("season monitor flip failed: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
                    }
                    // Refetch: the flip cascades to every episode flag.
                    await load()
                },
                onSetEpisodeMonitored: { episodeId, monitored in
                    if let idx = allEpisodes.firstIndex(where: { $0.id == episodeId }) {
                        allEpisodes[idx].monitored = monitored
                    }
                    do {
                        try await configStore.sonarrClient
                            .setEpisodesMonitored(episodeIds: [episodeId], monitored: monitored)
                    } catch {
                        await load()
                    }
                },
                onSeriesDeleted: {
                    Task { await viewModel.refresh() }
                    onBack()
                },
                onEpisodeFileDeleted: { Task { await load() } }
            )
        }
        .task(id: item.id) { await load() }
        .task(id: sonarrDetail?.id) {
            let keys = sonarrDetail?.mediaServerKeys ?? []
            guard !keys.isEmpty, let season = item.seasonNumber else { return }
            await MediaServerIndex.shared.loadSeasonPosters(for: keys)
            mediaServerSeasonPoster = MediaServerIndex.shared.seasonPosterURL(for: keys, season: season)
        }
        // Import done: refetch so the stale download view gives way to the on-disk file.
        .onChange(of: isInLiveQueue) { _, stillQueued in
            if !stillQueued, item.arrQueueId != 0 {
                Task { await load() }
            }
        }
    }

    /// Same resolution as `DetailView`, so a title never wears two crops.
    private var seriesPosterURL: URL? {
        arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore,
                     mediaServerKeys: sonarrDetail?.mediaServerKeys ?? []) ?? item.posterURL
    }

    /// Read live: the pushed `item` is a frozen snapshot. Empty once the rows
    /// leave the queue, never the snapshot (it would freeze at "importing").
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

    private var isInLiveQueue: Bool {
        viewModel.items(for: item.source)
            .contains { $0.id == item.id || $0.arrQueueId == item.arrQueueId }
    }

    private var displayEpisode: ArrEpisode {
        fullEpisode ?? ArrEpisode(placeholderSeason: item.seasonNumber, episode: item.episodeNumber)
    }

    /// Runs on every queue tick, so it uses `episodeIdBySlot` instead of scanning
    /// `allEpisodes` (450-episode series made that `queue × 450`).
    private var seasonQueueByEpisodeId: [Int: [QueueItem]] {
        guard let id = item.entityId else { return [:] }
        var map: [Int: [QueueItem]] = [:]
        for q in viewModel.items(for: .sonarr) where q.entityId == id && q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let epId = episodeIdBySlot[EpisodeSlot(season: sn, episode: en)] {
                map[epId, default: []].append(q)
            }
        }
        return map
    }

    private func load() async {
        guard let seriesId = item.entityId else { return }
        let client = configStore.sonarrClient
        do {
            async let detailReq = client.fetchSeriesDetails(id: seriesId)
            async let episodesReq = client.fetchEpisodes(seriesId: seriesId)
            async let filesReq = client.fetchEpisodeFileMap(seriesId: seriesId)
            let detail = try await detailReq
            let episodes = try await episodesReq
            let files = try await filesReq
            self.sonarrDetail = detail
            cast = await CastProvider.seriesCredits(
                tmdbId: detail.tmdbId, tvdbId: detail.tvdbId, configStore: configStore).cast
            if let profileId = detail.qualityProfileId {
                profileName = await SearchClient.profileNameMap(config: configStore.sonarr, source: .sonarr)[profileId]
            }
            self.allEpisodes = episodes
            self.episodeIdBySlot = Dictionary(
                episodes.compactMap { ep in
                    guard let sn = ep.seasonNumber, let en = ep.episodeNumber else { return nil }
                    return (EpisodeSlot(season: sn, episode: en), ep.id)
                },
                uniquingKeysWith: { first, _ in first }
            )
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
