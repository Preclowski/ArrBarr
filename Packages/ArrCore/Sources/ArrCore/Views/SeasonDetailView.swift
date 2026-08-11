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

    private var navTitle: String {
        String(format: String(localized: "detail.seasonLld.label", bundle: .module), drill.seasonNumber)
    }

    /// This season's own monitored flag, read live off the series detail the
    /// parent hands down on every body pass — no local copy to go stale when
    /// the flag is flipped upstream. `nil` (unreported) renders no bookmark.
    private var seasonMonitored: Bool? {
        sonarrDetail?.seasons?.first { $0.seasonNumber == drill.seasonNumber }?.monitored
    }

    @ViewBuilder
    private var monitorToggle: some View {
        if let seasonMonitored {
            MonitorToggleButton(
                isMonitored: seasonMonitored,
                entity: .season,
                onToggle: onSetSeasonMonitored.map { toggle in { m in await toggle(m) } }
            )
        }
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
                monitorToggle
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
                                    onPauseQueueItem: { q in Task { await viewModel.pause(q) } },
                                    onResumeQueueItem: { q in Task { await viewModel.resume(q) } },
                                    onDeleteQueueItem: { q in Task { await viewModel.delete(q) } },
                                    seriesTitle: drill.seriesTitle,
                                    seriesPosterURL: seriesPosterURL,
                                    seriesPosterRequiresAuth: seriesPosterRequiresAuth,
                                    seriesPosterAPIKey: seriesPosterAPIKey
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
        .posterLightbox(url: $enlargedPoster, apiKey: seriesPosterAPIKey, aspectRatio: 2.0 / 3.0)
        .conditionalNavTitle("\(drill.seriesTitle) · \(navTitle)", apply: !isDetachedWindow)
        .navigationDestination(item: $selectedEpisode) { ep in
            EpisodeDetailOverlay(
                episode: ep,
                seriesTitle: drill.seriesTitle,
                posterURL: seriesPosterURL,
                posterRequiresAuth: seriesPosterRequiresAuth,
                apiKey: seriesPosterAPIKey,
                episodeFile: ep.episodeFileId.flatMap { fileByEpisodeFileId[$0] },
                queueItems: queueByEpisodeId[ep.id] ?? [],
                onClose: { selectedEpisode = nil },
                onSearch: { episodeId in
                    try? await SonarrClient(config: configStore.sonarr).searchEpisodes(episodeIds: [episodeId])
                },
                onPauseEpisode: { q in await viewModel.pause(q); await viewModel.refresh() },
                onResumeEpisode: { q in await viewModel.resume(q); await viewModel.refresh() },
                onDeleteEpisode: { q in Task { await viewModel.delete(q) } },
                // Tapping the hero's season link pops back to this season view.
                onTapSeason: { selectedEpisode = nil },
                seriesYear: drill.seriesYear,
                // Re-read from the live array rather than the pushed `ep`
                // snapshot, which is frozen at tap time.
                monitored: episodes.first { $0.id == ep.id }?.monitored,
                onToggleMonitored: onSetEpisodeMonitored.map { toggle in { m in await toggle(ep.id, m) } }
            )
        }
        .navigationDestination(item: $manualSearchTarget) { wrapper in
            ReleaseListView(target: wrapper.target, onBack: { manualSearchTarget = nil })
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // This screen had no toolbar at all — the season monitor toggle is its
        // first trailing action. `.primaryAction` matches the placement the
        // sibling detail screens already use.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                headerSearchMenu
                monitorToggle
            }
        }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
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

    private func startAutomaticSearch() {
        guard !autoSearching else { return }
        Task {
            autoSearching = true
            try? await SonarrClient(config: configStore.sonarr)
                .searchSeason(seriesId: drill.seriesId, seasonNumber: drill.seasonNumber)
            autoSearching = false
            autoDidSearch = true
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            autoDidSearch = false
        }
    }

    private var ratings: [RatingChip] {
        guard let v = sonarrDetail?.ratings?.value else { return [] }
        return [RatingChip(label: "Rating", value: String(format: "%.1f", v), color: .yellow)]
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
            genres: sonarrDetail?.genres ?? [],
            ratings: ratings,
            overview: sonarrDetail?.overview,
            posterURL: seriesPosterURL,
            posterRequiresAuth: seriesPosterRequiresAuth,
            apiKey: seriesPosterAPIKey,
            fallbackSymbol: "tv",
            posterAspect: 2.0 / 3.0,
            blurred: false,
            trailing: nil,
            titleBadge: nil,
            onPosterTap: { url in
                withAnimation(.smooth(duration: 0.22)) { enlargedPoster = url ?? seriesPosterURL }
            },
            showTitle: false
        )
    }

}
