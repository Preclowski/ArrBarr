import SwiftUI

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
    let item: QueueItem
    @EnvironmentObject var configStore: ConfigStore
    let siblings: [QueueItem]
    let loadError: String?
    /// Detail fetch still in flight — the seasons list / cast show a skeleton
    /// instead of nothing, so the view fills in element-by-element.
    var isLoading: Bool = false
    let header: Header
    /// Cast (TMDB — Sonarr has no cast endpoint) — horizontal headshot strip.
    var cast: [CastMember] = []
    @Binding var sonarrDetail: SonarrSeriesDetail?
    let sonarrEpisodes: [SonarrEpisodeDetail]
    let sonarrEpisodeFiles: [Int: SonarrEpisodeFile]
    /// Tap handler for a season row — DetailView pushes `SeasonDetailView`.
    let onTapSeason: (SonarrSeasonInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synopsis now renders inside the header card's right column
            // (beside the poster) — see MediaHeaderCard.overview.
            header

            if !cast.isEmpty {
                CastRow(cast: cast)
            } else if isLoading, !configStore.tmdbApiKey.isEmpty {
                // Series cast comes from TMDB and only with a key (Sonarr has no
                // cast endpoint). No key → it will never load, so don't pulse a
                // skeleton for heads that aren't coming.
                SkeletonCastRow()
            }

            if let seasons = sonarrDetail?.seasons {
                let visibleSeasons = seasons.filter { $0.seasonNumber > 0 }
                if !visibleSeasons.isEmpty {
                    seasonsHeader
                    // Each season is a progress-bar summary row; tapping it pushes
                    // SeasonDetailView (its episodes + that season's search buttons).
                    VStack(spacing: 3) {
                        ForEach(visibleSeasons, id: \.seasonNumber) { season in
                            SeasonRow(
                                season: season,
                                episodes: sonarrEpisodes.filter { $0.seasonNumber == season.seasonNumber },
                                queueByEpisodeId: queueByEpisodeId,
                                onTap: { onTapSeason(season) }
                            )
                        }
                    }
                }
            } else if isLoading {
                // Series detail still loading — skeleton the seasons list (its
                // main content) so the surface isn't an empty column.
                seasonsHeader
                SkeletonRows(count: 6)
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

    /// Map episode-id → ALL active queue items, built from `siblings`
    /// (queue items for this series) joined to the loaded
    /// `sonarrEpisodes`. Powers the per-episode in-progress
    /// indicator + hover action icons that replaced the standalone
    /// "in queue" list. A list so duplicate grabs of the same episode
    /// all stay visible (the old single-value map dropped one).
    private var queueByEpisodeId: [Int: [QueueItem]] {
        var map: [Int: [QueueItem]] = [:]
        for q in siblings where q.arrQueueId != 0 {
            guard let sn = q.seasonNumber, let en = q.episodeNumber else { continue }
            if let ep = sonarrEpisodes.first(where: {
                $0.seasonNumber == sn && $0.episodeNumber == en
            }) {
                map[ep.id, default: []].append(q)
            }
        }
        return map
    }

    /// Section header for the seasons list. Series-wide "search whole series"
    /// affordance lived here briefly; pulled per UX feedback — per-season search
    /// (now the bottom CTA, targeting the open accordion row) is more precise.
    private var seasonsHeader: some View {
        HStack(spacing: 8) {
            Text("detail.seasons.button", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

}
