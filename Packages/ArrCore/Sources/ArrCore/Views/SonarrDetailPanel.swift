import SwiftUI

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
    let item: QueueItem
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let siblings: [QueueItem]
    let loadError: String?
    let header: Header
    /// Cast (TMDB — Sonarr has no cast endpoint) — horizontal headshot strip.
    var cast: [CastMember] = []
    @Binding var sonarrDetail: SonarrSeriesDetail?
    let sonarrEpisodes: [SonarrEpisodeDetail]
    let sonarrEpisodeFiles: [Int: SonarrEpisodeFile]
    @Binding var selectedSeasonNumber: Int?
    @Binding var selectedEpisode: SonarrEpisodeDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synopsis now renders inside the header card's right column
            // (beside the poster) — see MediaHeaderCard.overview.
            header

            if !cast.isEmpty {
                CastRow(cast: cast)
            }

            if let seasons = sonarrDetail?.seasons {
                let visibleSeasons = seasons.filter { $0.seasonNumber > 0 }
                if !visibleSeasons.isEmpty {
                    seasonsHeader(seasons: visibleSeasons)
                    seasonPillBar(visibleSeasons)
                    if let active = visibleSeasons.first(where: { $0.seasonNumber == effectiveSeasonNumber(in: visibleSeasons) }) {
                        SeasonRow(
                            season: active,
                            episodes: sonarrEpisodes.filter { $0.seasonNumber == active.seasonNumber },
                            queueByEpisodeId: queueByEpisodeId,
                            fileByEpisodeFileId: sonarrEpisodeFiles,
                            onSearchSeason: searchSeasonClosure(seasonNumber: active.seasonNumber),
                            onSearchEpisode: searchEpisodeClosure,
                            onTapEpisode: { ep in
                                withAnimation(.smooth(duration: 0.22)) { selectedEpisode = ep }
                            },
                            onPauseEpisode: { q in
                                Task { await viewModel.pause(q) }
                            },
                            onResumeEpisode: { q in
                                Task { await viewModel.resume(q) }
                            },
                            onDeleteEpisode: { q in
                                Task { await viewModel.delete(q) }
                            },
                            onSetMonitored: setSeasonMonitoredClosure(seasonNumber: active.seasonNumber),
                            initiallyExpanded: true,
                            hideExpandChevron: true,
                            seriesTitle: sonarrDetail?.title ?? item.title,
                            seriesPosterURL: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore) ?? item.posterURL,
                            seriesPosterRequiresAuth: item.posterRequiresAuth,
                            seriesPosterAPIKey: configStore.sonarr.apiKey
                        )
                    }
                }
            }
            // DownloadSection used to live here for series — the
            // separate "w kolejce" list with all active episode
            // downloads. Removed: each in-progress episode is now
            // marked inline (status dot on the row + hover actions
            // for pause/resume/remove), and the season pill carries
            // a "currently downloading" indicator so the user can
            // jump to the right season without scrolling a parallel
            // list. One source of truth per episode = fewer surfaces
            // for the action buttons to land out of reach.

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }

    /// Map episode-id → active queue item, built from `siblings`
    /// (queue items for this series) joined to the loaded
    /// `sonarrEpisodes`. Powers the per-episode in-progress
    /// indicator + hover action icons that replaced the standalone
    /// "in queue" list.
    private var queueByEpisodeId: [Int: QueueItem] {
        var map: [Int: QueueItem] = [:]
        for q in siblings where q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let ep = sonarrEpisodes.first(where: {
                $0.seasonNumber == sn && $0.episodeNumber == en
            }) {
                map[ep.id] = q
            }
        }
        return map
    }

    /// Dominant queue status across all in-flight episodes for a
    /// season. Priority: downloading > paused > other. Drives the
    /// season-pill colour dot so it matches the actual state of the
    /// episodes inside (blue dot on a season full of paused episodes
    /// used to be a UX lie).
    private func dominantQueueStatus(forSeason sn: Int) -> QueueItem.Status? {
        let inSeason = siblings.filter {
            $0.seasonNumber == sn && $0.arrQueueId != 0
        }
        guard !inSeason.isEmpty else { return nil }
        if inSeason.contains(where: { $0.status == .downloading }) { return .downloading }
        if inSeason.contains(where: { $0.status == .paused }) { return .paused }
        return inSeason.first?.status
    }

    /// Wrapping pill-row of season selectors. Replaces the legacy
    /// vertical list of expandable SeasonRows — only one season's
    /// content is visible at a time, the pill bar is the navigation.
    @ViewBuilder
    private func seasonPillBar(_ seasons: [SonarrSeasonInfo]) -> some View {
        let activeNumber = effectiveSeasonNumber(in: seasons)
        #if os(iOS)
        // iOS: a single scrollable row of larger, tab-strip-style pills
        // (instead of the wrapping flow layout used in the compact macOS
        // popover). Auto-scrolls to keep the active season in view.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.seasonNumber) { season in
                        seasonPill(season, isActive: season.seasonNumber == activeNumber, large: true)
                            .id(season.seasonNumber)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .onChange(of: activeNumber) { _, new in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(activeNumber, anchor: .center) }
        }
        #else
        TooltipFlowLayout(spacing: 6) {
            ForEach(seasons, id: \.seasonNumber) { season in
                seasonPill(season, isActive: season.seasonNumber == activeNumber)
            }
        }
        #endif
    }

    @ViewBuilder
    private func seasonPill(_ season: SonarrSeasonInfo, isActive: Bool, large: Bool = false) -> some View {
        let have = season.statistics?.episodeFileCount ?? 0
        let total = season.statistics?.totalEpisodeCount ?? season.statistics?.episodeCount ?? 0
        let complete = total > 0 && have >= total
        let queueStatus = dominantQueueStatus(forSeason: season.seasonNumber)
        let dot: CGFloat = large ? 5 : 4
        Button {
            withAnimation(.smooth(duration: 0.2)) {
                selectedSeasonNumber = season.seasonNumber
            }
        } label: {
            HStack(spacing: large ? 5 : 4) {
                Text(String(format: String(localized: "detail.seasonLld.label", bundle: .module), season.seasonNumber))
                    .scaledFont(size: large ? 13 : 10, weight: isActive ? .semibold : .medium)
                    .foregroundStyle(isActive ? .primary : .secondary)
                // Dot colour reflects what the user will see when
                // they open the season: blue if anything's actively
                // downloading, orange if everything's paused, green
                // when the season is complete and idle. No dot when
                // partial + nothing in queue (still missing).
                if let s = queueStatus {
                    Circle()
                        .fill(isActive ? s.tint : s.tint.opacity(0.75))
                        .frame(width: dot, height: dot)
                } else if complete {
                    Circle()
                        .fill(isActive ? Color.green : Color.green.opacity(0.7))
                        .frame(width: dot, height: dot)
                }
            }
            .padding(.horizontal, large ? 14 : 8)
            .padding(.vertical, large ? 7 : 3)
            .background(
                Capsule()
                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.primary.opacity(isActive ? 0 : 0.18),
                        lineWidth: 0.6
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Resolves which season's content to show. User explicit pick
    /// wins; otherwise default to the first season with aired
    /// missing episodes (where the user is most likely heading);
    /// fall back to the latest season.
    private func effectiveSeasonNumber(in seasons: [SonarrSeasonInfo]) -> Int? {
        if let picked = selectedSeasonNumber,
           seasons.contains(where: { $0.seasonNumber == picked }) {
            return picked
        }
        // First season with at least one aired-but-missing episode.
        let now = Date()
        if let firstMissing = seasons.first(where: { season in
            sonarrEpisodes.contains { ep in
                guard ep.seasonNumber == season.seasonNumber else { return false }
                let aired = ep.airDateUtc.flatMap(parseArrDate).map { $0 <= now } ?? true
                return aired && ep.hasFile != true
            }
        }) {
            return firstMissing.seasonNumber
        }
        // Otherwise the latest season — most users want "what's
        // happening now" rather than the back catalogue.
        return seasons.max(by: { $0.seasonNumber < $1.seasonNumber })?.seasonNumber
    }

    // MARK: - Sonarr search-missing affordances

    /// Total *aired* missing episodes across non-special seasons. Drives
    /// the "Search all N missing" pill visibility. We use episode-level
    /// Section header for the seasons list. Series-wide "search whole
    /// series" affordance lived here briefly; pulled per UX feedback
    /// because per-season searches already let the user pick exactly
    /// which season to grab and the rollup added an ambiguous count.
    @ViewBuilder
    private func seasonsHeader(seasons: [SonarrSeasonInfo]) -> some View {
        HStack(spacing: 8) {
            Text("detail.seasons.button", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

    private func searchSeasonClosure(seasonNumber: Int) -> (() async -> Void)? {
        guard let seriesId = item.entityId else { return nil }
        return {
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
        }
    }

    private var searchEpisodeClosure: ((Int) async -> Void)? {
        // Series itself doesn't gate this — episode rows already only
        // show their button when an episode is missing.
        { episodeId in
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.searchEpisodes(episodeIds: [episodeId])
        }
    }

    /// Closure that flips season monitoring via Sonarr's `/seasonpass`
    /// endpoint. The SeasonRow drives optimistic UI locally; on server
    /// success we refresh `sonarrDetail` so the next read reconciles
    /// state (also brings in any side-effects, e.g. Sonarr's
    /// monitorNewItems policy auto-monitoring siblings).
    private func setSeasonMonitoredClosure(seasonNumber: Int) -> ((Bool) async -> Void)? {
        guard let seriesId = item.entityId else { return nil }
        return { state in
            let client = SonarrClient(config: configStore.sonarr)
            try? await client.setSeasonMonitored(
                seriesId: seriesId,
                seasonNumber: seasonNumber,
                monitored: state
            )
            // Refresh series detail so future paints see the true state
            // from the server (covers any auto-mark policies Sonarr ran).
            if let refreshed = try? await client.fetchSeriesDetails(id: seriesId) {
                await MainActor.run { self.sonarrDetail = refreshed }
            }
        }
    }
}
