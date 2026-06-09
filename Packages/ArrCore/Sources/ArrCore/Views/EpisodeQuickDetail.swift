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
        Group {
            if fullEpisode == nil && loadError == nil {
                loadingState
            } else {
                EpisodeDetailOverlay(
                    episode: displayEpisode,
                    seriesTitle: sonarrDetail?.title ?? splitTitleAndYear(item.title).title,
                    posterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth,
                    apiKey: configStore.sonarr.apiKey,
                    episodeFile: displayEpisode.episodeFileId.flatMap { episodeFileMap[$0] },
                    queueItem: item,
                    onClose: { },
                    onSearch: { episodeId in
                        let client = SonarrClient(config: configStore.sonarr)
                        try? await client.searchEpisodes(episodeIds: [episodeId])
                    },
                    warningActionURL: arrWebURL(for: item, in: configStore),
                    onPauseEpisode: { q in Task { await viewModel.pause(q) } },
                    onResumeEpisode: { q in Task { await viewModel.resume(q) } },
                    onDeleteEpisode: { q in Task { await viewModel.delete(q) } },
                    onTapSeries: { seriesPush = SeriesPushRequest(item: item) },
                    seriesYear: sonarrDetail?.year ?? splitTitleAndYear(item.title).year
                )
            }
        }
        .navigationTitle(sonarrDetail?.title ?? splitTitleAndYear(item.title).title)
        // Series push nests under THIS view (see `seriesPush`), so back
        // returns to the episode rather than the queue.
        .navigationDestination(item: $seriesPush) { req in
            DetailView(
                item: req.item,
                onBack: { seriesPush = nil },
                originLabel: originLabel,
                // Don't auto-drill back into the episode the user just
                // left to view the series.
                autoDrillToEpisode: false,
                viewModel: viewModel
            )
        }
        .task(id: item.id) { await load() }
    }

    /// Spinner + breadcrumb while the Sonarr fetch is in flight. Same
    /// pattern as DetailView (`if loading { ProgressView }`) so the
    /// user never sees half-populated hero metadata popping in field by
    /// field while data lands.
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("detail.loadingEpisode.button", bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
