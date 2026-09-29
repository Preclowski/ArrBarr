import SwiftUI
import MediaKit

/// A distinct type so its `.navigationDestination` never collides with others in the stack.
struct SeasonDrill: Identifiable, Hashable, Sendable {
    let seriesId: Int
    let seasonNumber: Int
    let seriesTitle: String
    let seriesYear: Int?
    init(seriesId: Int, seasonNumber: Int, seriesTitle: String, seriesYear: Int?) {
        self.seriesId = seriesId
        self.seasonNumber = seasonNumber
        self.seriesTitle = seriesTitle
        self.seriesYear = seriesYear
    }
    var id: String { "\(seriesId)-s\(seasonNumber)" }
}

/// Distinct from `ManualSearchTarget` so the two destinations don't collide in one stack.
private struct SeasonReleaseSearch: Identifiable, Hashable {
    let target: ManualSearchTarget
    var id: String { target.id }
}

struct SeasonDetailView: View {
    let drill: SeasonDrill
    let sonarrDetail: ArrSeries?
    let episodes: [ArrEpisode]
    let queueByEpisodeId: [Int: [QueueItem]]
    let fileByEpisodeFileId: [Int: ArrFile]
    let seriesPosterURL: URL?
    let seriesPosterRequiresAuth: Bool
    let seriesPosterAPIKey: String?
    let onBack: () -> Void
    var viewModel: QueueViewModel
    /// The parent owns `sonarrDetail` and the episodes; nil renders the bookmarks inert.
    var onSetSeasonMonitored: ((Bool) async -> Void)? = nil
    var onSetEpisodeMonitored: ((Int, Bool) async -> Void)? = nil
    /// The series went from the library: the parent leaves too.
    var onSeriesDeleted: (() -> Void)? = nil
    /// An episode's file went from disk: the parent reloads the files it lends this view.
    var onEpisodeFileDeleted: (() -> Void)? = nil

    @EnvironmentObject private var configStore: ConfigStore
    @Environment(\.isDetachedWindow) private var isDetachedWindow

    @State private var selectedEpisode: ArrEpisode?
    @State private var enlargedPoster: URL?
    @State private var manualSearchTarget: SeasonReleaseSearch?
    @State private var searchFeedback: SearchFeedback = .idle
    @State private var actionState = DetailActionState()
    /// nil keeps the series poster.
    @State private var mediaServerSeasonPoster: URL?
    @State private var countries: [String] = []
    @State private var cast: [CastMember] = []
    @State private var profileName: String?

    /// Every poster on this screen goes through here so header, lightbox and rows agree.
    private var posterURL: URL? { mediaServerSeasonPoster ?? seriesPosterURL }

    /// A media-server poster carries the server's own header (resolved in `PosterStore`), never the arr's key.
    private var posterRequiresAuth: Bool {
        mediaServerSeasonPoster == nil && seriesPosterRequiresAuth
    }

    private var posterAPIKey: String? {
        mediaServerSeasonPoster == nil ? seriesPosterAPIKey : nil
    }

    private var navTitle: String {
        String(format: String(localized: "detail.seasonLld.label", bundle: .module), drill.seasonNumber)
    }

    /// Read live off the parent's series detail so it can't go stale; nil renders no bookmark.
    private var seasonMonitored: Bool? {
        sonarrDetail?.seasons?.first { $0.seasonNumber == drill.seasonNumber }?.monitored
    }

    private var monitorPosterToggle: AnyView? {
        guard let seasonMonitored else { return nil }
        return AnyView(
            MonitorPosterToggle(
                isMonitored: seasonMonitored,
                entity: .season,
                onToggle: onSetSeasonMonitored.map { toggle in { m in await toggle(m) } }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The popover's chevron is hidden by DetailView's `windowToolbar` and the detached window has none.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(verbatim: "\(drill.seriesTitle) · \(navTitle)")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                headerMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    seasonHeader
                    VStack(alignment: .leading, spacing: 6) {
                        DetailSectionHeader(
                        "queue.episodes.button",
                        have: episodes.count { $0.hasFile == true },
                        total: episodes.count
                    )
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(episodes.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) })) { ep in
                                EpisodeRow(
                                    episode: ep,
                                    queueItems: queueByEpisodeId[ep.id] ?? [],
                                    episodeFile: ep.episodeFileId.flatMap { fileByEpisodeFileId[$0] },
                                    onTap: { episode in
                                        withAnimation(.smooth(duration: 0.22)) { selectedEpisode = episode }
                                    },
                                    // Episodes have no art of their own.
                                    posterURL: posterURL,
                                    posterRequiresAuth: posterRequiresAuth,
                                    posterAPIKey: posterAPIKey,
                                    onToggleMonitored: onSetEpisodeMonitored.map { toggle in
                                        { m in await toggle(ep.id, m) }
                                    },
                                    onAutomaticSearch: { try await searchEpisode(ep) },
                                    onManualSearch: {
                                        manualSearchTarget = SeasonReleaseSearch(target: .episode(
                                            episodeId: ep.id, title: episodeSearchTitle(ep)))
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(url: $enlargedPoster, apiKey: posterAPIKey, aspectRatio: 2.0 / 3.0)
        // Lazy: one request per series, cached by the index for the session.
        .task(id: drill.seriesId) {
            countries = await CountryProvider.seriesCountries(
                tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
        }
        // `CastProvider` caches per title, so coming from the series detail this is a cache hit.
        .task(id: drill.seriesId) {
            cast = await CastProvider.seriesCredits(
                tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore).cast
        }
        .task(id: sonarrDetail?.qualityProfileId) {
            guard let id = sonarrDetail?.qualityProfileId else { return }
            profileName = await SearchClient.profileNameMap(config: configStore.sonarr, source: .sonarr)[id]
        }
        .task(id: drill.seriesId) {
            let keys = sonarrDetail?.mediaServerKeys ?? []
            guard !keys.isEmpty else { return }
            await MediaServerIndex.shared.loadSeasonPosters(for: keys)
            mediaServerSeasonPoster = MediaServerIndex.shared.seasonPosterURL(
                for: keys, season: drill.seasonNumber)
        }
        .conditionalNavTitle("\(drill.seriesTitle) · \(navTitle)", apply: !isDetachedWindow)
        .navigationDestination(item: $selectedEpisode) { ep in
            EpisodeDetailOverlay(
                episode: ep,
                seriesTitle: drill.seriesTitle,
                posterURL: posterURL,
                posterRequiresAuth: posterRequiresAuth,
                apiKey: posterAPIKey,
                episodeFile: ep.episodeFileId.flatMap { fileByEpisodeFileId[$0] },
                queueItems: queueByEpisodeId[ep.id] ?? [],
                onClose: { selectedEpisode = nil },
                onSearch: { episodeId in
                    try await configStore.sonarrClient.searchEpisodes(episodeIds: [episodeId])
                },
                seriesWebURL: seriesWebURL,
                onPauseEpisode: { q in await viewModel.pause(q); await viewModel.refresh() },
                onResumeEpisode: { q in await viewModel.resume(q); await viewModel.refresh() },
                onDeleteEpisode: { q in Task { await viewModel.delete(q) } },
                onTapSeason: { selectedEpisode = nil },
                seriesYear: drill.seriesYear,
                cast: cast,
                genres: sonarrDetail?.genres ?? [],
                certification: sonarrDetail?.certification,
                seriesTmdbId: sonarrDetail?.tmdbId,
                seriesTvdbId: sonarrDetail?.tvdbId,
                profileName: profileName,
                mediaServerKeys: sonarrDetail?.mediaServerKeys ?? [],
                // The pushed `ep` is a snapshot frozen at tap time.
                monitored: episodes.first { $0.id == ep.id }?.monitored,
                onToggleMonitored: onSetEpisodeMonitored.map { toggle in { m in await toggle(ep.id, m) } },
                onFileDeleted: onEpisodeFileDeleted
            )
        }
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target,
                            existingByEpisode: existingFileByEpisodeNumber,
                            waitContext: WaitCardContext(series: sonarrDetail, seriesYear: drill.seriesYear,
                                                         cast: cast, posterURL: posterURL, posterApiKey: posterAPIKey),
                            onBack: { manualSearchTarget = nil })
        }
        .detailActionsHost($actionState) { _ in onSeriesDeleted?() }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                headerMenu
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
    }

    /// Baseline for single-episode rows in the manual search; a pack replaces many files, so it has none.
    private var existingFileByEpisodeNumber: [Int: UpgradeDiffView.Side] {
        var out: [Int: UpgradeDiffView.Side] = [:]
        for episode in episodes {
            guard let number = episode.episodeNumber,
                  let file = episode.episodeFileId.flatMap({ fileByEpisodeFileId[$0] }) else { continue }
            out[number] = UpgradeDiffView.side(file: file)
        }
        return out
    }

    private var headerMenu: some View {
        DetailActionsMenu(actions: detailActions, state: $actionState, feedback: searchFeedback)
    }

    /// A season has no record of its own, so edit and delete act on the series and say so.
    private var detailActions: DetailActions {
        let title = "\(drill.seriesTitle) · \(navTitle)"
        return DetailActions(
            edit: MediaEditRequest(source: .sonarr, entityId: drill.seriesId),
            editLabel: "detail.editSeries.button",
            search: DetailActions.Search(
                isSending: searchFeedback.isSending,
                onAutomatic: { startAutomaticSearch() },
                onManual: {
                    manualSearchTarget = SeasonReleaseSearch(target: .season(
                        seriesId: drill.seriesId, seasonNumber: drill.seasonNumber, title: title))
                }),
            webURL: seriesWebURL,
            delete: onSeriesDeleted.map { _ in MediaDeleteRequest(source: .sonarr, target: .record(drill.seriesId), title: drill.seriesTitle) },
            deleteLabel: "detail.deleteSeries.button")
    }

    private var seriesWebURL: URL? {
        arrWebURL(source: .sonarr, slug: sonarrDetail?.titleSlug, in: configStore)
    }

    private func episodeSearchTitle(_ ep: ArrEpisode) -> String {
        let code = EpisodeCode.string(season: drill.seasonNumber, episode: ep.episodeNumber ?? 0)
        return "\(drill.seriesTitle) · \(code)"
    }

    private func searchEpisode(_ ep: ArrEpisode) async throws {
        try await configStore.sonarrClient.searchEpisodes(episodeIds: [ep.id])
    }

    private func startAutomaticSearch() {
        let (client, seriesId, season) = (configStore.sonarrClient, drill.seriesId, drill.seasonNumber)
        SearchFeedback.run($searchFeedback) { try await client.searchSeason(seriesId: seriesId, seasonNumber: season) }
    }

    /// Sonarr's series score is TVDB's.
    private var ratings: [RatingChip] {
        guard let v = sonarrDetail?.ratings?.value else { return [] }
        return [RatingChip.tvdb(v, linkTitle: drill.seriesTitle,
                                tvdbId: sonarrDetail?.tvdbId,
                                votes: sonarrDetail?.ratings?.votes)].compactMap { $0 }
    }

    /// Title hidden: the header bar already shows "Series · Season N".
    private var seasonHeader: some View {
        MediaHeaderCard(
            title: drill.seriesTitle,
            year: drill.seriesYear,
            runtime: sonarrDetail?.runtime,
            network: nil,
            certification: sonarrDetail?.network,
            countries: countries,
            genres: sonarrDetail?.genres ?? [],
            ratings: ratings,
            overview: sonarrDetail?.overview,
            posterURL: posterURL,
            posterRequiresAuth: posterRequiresAuth,
            apiKey: posterAPIKey,
            fallbackSymbol: "tv",
            posterAspect: 2.0 / 3.0,
            blurred: false,
            trailing: nil,
            titleBadge: nil,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url ?? posterURL }
            },
            posterCornerAction: monitorPosterToggle,
            showTitle: false
        )
    }

}
