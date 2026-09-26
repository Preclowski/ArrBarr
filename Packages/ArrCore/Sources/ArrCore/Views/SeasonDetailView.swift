import SwiftUI

/// Pushed when the user taps a season in the series detail. Identifies which
/// season to open — kept a distinct type from `ManualSearchTarget` etc. so its
/// `.navigationDestination` never collides with others in the same stack.
public struct SeasonDrill: Identifiable, Hashable, Sendable {
    public let seriesId: Int
    public let seasonNumber: Int
    public let seriesTitle: String
    public let seriesYear: Int?
    public init(seriesId: Int, seasonNumber: Int, seriesTitle: String, seriesYear: Int?) {
        self.seriesId = seriesId
        self.seasonNumber = seasonNumber
        self.seriesTitle = seriesTitle
        self.seriesYear = seriesYear
    }
    public var id: String { "\(seriesId)-s\(seasonNumber)" }
}

/// Distinct wrapper so the season's "Manual search" push doesn't share a value
/// type with the movie/album `ManualSearchTarget` destination up the stack.
private struct SeasonReleaseSearch: Identifiable, Hashable {
    let target: ManualSearchTarget
    var id: String { target.id }
}

/// A single season's screen: its episode list + Manual/Automatic search buttons
/// pinned at the bottom. Search is now unambiguous — you're *inside* the season,
/// so the buttons obviously act on it (replaces the ambiguous series-level CTA).
struct SeasonDetailView: View {
    let drill: SeasonDrill
    /// Series detail for the hero header (poster / overview / metadata) — the
    /// season screen reuses the same `MediaHeaderCard` as the series view.
    let sonarrDetail: SonarrSeriesDetail?
    let episodes: [SonarrEpisodeDetail]
    let queueByEpisodeId: [Int: [QueueItem]]
    let fileByEpisodeFileId: [Int: SonarrEpisodeFile]
    let seriesPosterURL: URL?
    let seriesPosterRequiresAuth: Bool
    let seriesPosterAPIKey: String?
    let onBack: () -> Void
    var viewModel: QueueViewModel
    /// Monitor-toggle callbacks up to the state owner (DetailView /
    /// EpisodeQuickDetail own `sonarrDetail` + the episode array; this view
    /// only receives copies). nil renders the bookmarks as inert state.
    var onSetSeasonMonitored: ((Bool) async -> Void)? = nil
    var onSetEpisodeMonitored: ((Int, Bool) async -> Void)? = nil

    @EnvironmentObject private var configStore: ConfigStore
    @Environment(\.isDetachedWindow) private var isDetachedWindow

    @State private var selectedEpisode: SonarrEpisodeDetail?
    @State private var enlargedPoster: URL?
    @State private var manualSearchTarget: SeasonReleaseSearch?
    @State private var autoSearching = false
    @State private var autoDidSearch = false
    /// The connected media server's artwork for *this season*, once fetched.
    /// nil keeps the series poster, which is what every surface showed before.
    @State private var mediaServerSeasonPoster: URL?
    /// Same series-level country the series view shows — a cache hit in
    /// `CountryProvider` when the user drilled in from there.
    @State private var countries: [String] = []
    /// Series cast, loaded once per series for the episode screens below.
    @State private var cast: [CastMember] = []
    /// The series' quality-profile name, for the episode hero's chip.
    @State private var profileName: String?

    /// Season art when the media server has it, series art otherwise. Every
    /// poster on this screen goes through here so the header, the lightbox and
    /// the episode rows can't disagree about which image the season has.
    private var posterURL: URL? { mediaServerSeasonPoster ?? seriesPosterURL }

    /// A media-server poster is fetched with the server's own header (see
    /// `MediaServerPosterAccess`), never the arr's key — so both arr
    /// credentials drop away as soon as the override wins.
    private var posterRequiresAuth: Bool {
        mediaServerSeasonPoster == nil && seriesPosterRequiresAuth
    }

    private var posterAPIKey: String? {
        mediaServerSeasonPoster == nil ? seriesPosterAPIKey : nil
    }

    private var navTitle: String {
        String(format: String(localized: "detail.seasonLld.label", bundle: .module), drill.seasonNumber)
    }

    /// This season's own monitored flag, read live off the series detail the
    /// parent hands down on every body pass — no local copy to go stale when
    /// the flag is flipped upstream. `nil` (unreported) renders no bookmark.
    private var seasonMonitored: Bool? {
        sonarrDetail?.seasons?.first { $0.seasonNumber == drill.seasonNumber }?.monitored
    }

    /// On the poster's top-right corner, matching `DetailView` — the bookmark
    /// is state about the season, not header chrome.
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
            // Self-drawn header (the popover's native chevron is hidden by the
            // parent DetailView's `windowToolbar` hide; the detached window has
            // none either). iOS keeps the native nav bar.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(verbatim: "\(drill.seriesTitle) · \(navTitle)")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                headerSearchMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    seasonHeader
                    // Header + rows share a 6pt stack (the CastRow rhythm) so
                    // the label hugs its list instead of floating 12pt above.
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
                                    // Episodes have no art of their own; the
                                    // hover tooltip borrows this season's
                                    // poster (series art when there is none).
                                    posterURL: posterURL,
                                    posterRequiresAuth: posterRequiresAuth,
                                    posterAPIKey: posterAPIKey,
                                    onToggleMonitored: onSetEpisodeMonitored.map { toggle in
                                        { m in await toggle(ep.id, m) }
                                    },
                                    onAutomaticSearch: { await searchEpisode(ep) },
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
            // No bottom strip — the season's Search choice lives in the
            // header cluster now.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .posterLightbox(url: $enlargedPoster, apiKey: posterAPIKey, aspectRatio: 2.0 / 3.0)
        // Lazily — one request per series the user actually opens a season of,
        // and the index caches the answer for the rest of the session.
        .task(id: drill.seriesId) {
            countries = await CountryProvider.seriesCountries(
                tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
        }
        // For the episode screens pushed from here. `CastProvider` coalesces
        // and caches per title, so coming from the series detail this is a
        // cache hit and costs nothing.
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
                    try? await configStore.sonarrClient.searchEpisodes(episodeIds: [episodeId])
                },
                onPauseEpisode: { q in await viewModel.pause(q); await viewModel.refresh() },
                onResumeEpisode: { q in await viewModel.resume(q); await viewModel.refresh() },
                onDeleteEpisode: { q in Task { await viewModel.delete(q) } },
                // Tapping the hero's season link pops back to this season view.
                onTapSeason: { selectedEpisode = nil },
                seriesYear: drill.seriesYear,
                cast: cast,
                genres: sonarrDetail?.genres ?? [],
                certification: sonarrDetail?.certification,
                seriesTmdbId: sonarrDetail?.tmdbId,
                seriesTvdbId: sonarrDetail?.tvdbId,
                profileName: profileName,
                mediaServerKeys: sonarrDetail?.mediaServerKeys ?? [],
                // Re-read from the live array rather than the pushed `ep`
                // snapshot, which is frozen at tap time.
                monitored: episodes.first { $0.id == ep.id }?.monitored,
                onToggleMonitored: onSetEpisodeMonitored.map { toggle in { m in await toggle(ep.id, m) } }
            )
        }
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target,
                            existingByEpisode: existingFileByEpisodeNumber,
                            waitContext: WaitCardContext(series: sonarrDetail, seriesYear: drill.seriesYear,
                                                         cast: cast, posterURL: posterURL),
                            onBack: { manualSearchTarget = nil })
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // `.primaryAction` matches the placement the sibling detail screens
        // already use. (The monitor toggle lives on the poster corner.)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                headerSearchMenu
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
    }

    /// What each episode already has on disk, keyed by episode number — the
    /// baseline a single-episode row in the manual search diffs against. A pack
    /// replaces many files, so it keeps no baseline of its own.
    private var existingFileByEpisodeNumber: [Int: UpgradeDiffView.Side] {
        var out: [Int: UpgradeDiffView.Side] = [:]
        for episode in episodes {
            guard let number = episode.episodeNumber,
                  let file = episode.episodeFileId.flatMap({ fileByEpisodeFileId[$0] }) else { continue }
            out[number] = UpgradeDiffView.side(episodeFile: file)
        }
        return out
    }

    /// The season's Search choice, in the header cluster (same component the
    /// other detail surfaces use).
    private var headerSearchMenu: some View {
        HeaderSearchMenu(
            inFlight: autoSearching,
            didQueue: autoDidSearch,
            onAutomatic: { startAutomaticSearch() },
            onManual: {
                manualSearchTarget = SeasonReleaseSearch(target: .season(
                    seriesId: drill.seriesId, seasonNumber: drill.seasonNumber,
                    title: "\(drill.seriesTitle) · \(navTitle)"))
            }
        )
    }

    /// `Series · S02E04` — what the release list titles an episode search with,
    /// matching the episode screen's own nav title.
    private func episodeSearchTitle(_ ep: SonarrEpisodeDetail) -> String {
        let code = String(format: "S%02dE%02d", drill.seasonNumber, ep.episodeNumber ?? 0)
        return "\(drill.seriesTitle) · \(code)"
    }

    /// One episode's automatic search, fired from its row's context menu. The
    /// row owns the spinner; failures are silent for the same reason the
    /// header's sweep is — the arr queues the search, it doesn't report on it.
    private func searchEpisode(_ ep: SonarrEpisodeDetail) async {
        try? await configStore.sonarrClient.searchEpisodes(episodeIds: [ep.id])
    }

    private func startAutomaticSearch() {
        guard !autoSearching else { return }
        Task {
            autoSearching = true
            try? await configStore.sonarrClient
                .searchSeason(seriesId: drill.seriesId, seasonNumber: drill.seasonNumber)
            autoSearching = false
            autoDidSearch = true
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            autoDidSearch = false
        }
    }

    /// Sonarr's series score is TVDB's — the chip wears that name and mark,
    /// same as the series detail one screen up. It used to read "Rating",
    /// which named no source at all.
    private var ratings: [RatingChip] {
        guard let v = sonarrDetail?.ratings?.value else { return [] }
        return [RatingChip.tvdb(v, linkTitle: drill.seriesTitle,
                                tvdbId: sonarrDetail?.tvdbId,
                                votes: sonarrDetail?.ratings?.votes)].compactMap { $0 }
    }

    /// Same hero card as the series view — poster + overview + metadata. Title is
    /// hidden (the header bar already shows "Series · Season N").
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
