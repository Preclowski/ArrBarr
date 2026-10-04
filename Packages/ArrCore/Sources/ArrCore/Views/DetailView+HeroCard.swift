import SwiftUI
import MediaKit

extension DetailView {
    // MARK: - Trailer

    /// Keyed on the payload too: the ids the lookup needs only exist after `load()`.
    var trailerLookupToken: String {
        switch item.source {
        case .radarr, .whisparr:
            return "movie:\(item.id):\(radarrDetail?.youTubeTrailerId ?? "-"):\(radarrDetail?.tmdbId ?? 0)"
        case .sonarr:
            return "series:\(item.id):\(sonarrDetail?.tmdbId ?? 0):\(sonarrDetail?.tvdbId ?? 0)"
        case .lidarr:
            return "none:\(item.id)"
        }
    }

    func resolveTrailer() async {
        // Dismiss only OUR clip: on a fresh mount `trailer` is nil and a session restored across
        // a popover reopen must be left alone.
        if trailerSession.isShowing(trailer) { trailerSession.dismiss() }
        trailer = nil
        let reel: TrailerReel?
        switch item.source {
        case .radarr, .whisparr:
            reel = await TrailerProvider.movieReel(
                radarrTrailerId: radarrDetail?.youTubeTrailerId,
                tmdbId: radarrDetail?.tmdbId,
                configStore: configStore
            )
        case .sonarr:
            reel = await TrailerProvider.seriesReel(
                tmdbId: sonarrDetail?.tmdbId,
                tvdbId: sonarrDetail?.tvdbId,
                configStore: configStore
            )
        case .lidarr:
            reel = nil
        }
        withAnimation(DetailView.landing) { trailer = reel }
    }

    func movieRatingChipsFor(_ detail: ArrMovie?) -> [RatingChip] {
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

    func sonarrRatingChipsFor(_ detail: ArrSeries?) -> [RatingChip] {
        guard let r = detail?.ratings, let v = r.value else { return [] }
        // Sonarr's rating is TVDB-sourced and the payload has no tvdbId, so link via search.
        let title = detail?.title ?? splitTitleAndYear(item.title).title
        return [RatingChip.tvdb(v, linkTitle: title, votes: r.votes)].compactMap { $0 }
    }

    // MARK: - Shared header card

    @ViewBuilder
    func headerCard(
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
            posterCornerAction: monitorPosterToggle,
            watched: isWatched,
            libraryMark: heroLibraryMark,
            // Title + year live in the nav-bar title.
            showTitle: false,
            metadataLoading: metadataLoading,
            directedBy: directors,
            directedByKey: directedByKey,
            directedByLoading: metadataLoading && directors.isEmpty && expectsCredits,
            onTapPerson: openPerson
        )
    }

    /// Radarr serves its own credits; a series' come from TMDB only.
    private var expectsCredits: Bool {
        item.source == .radarr || (item.source == .sonarr && !configStore.tmdbApiKey.isEmpty)
    }

    /// Falls back to the queue row's precomputed answer until the record lands.
    private var isWatched: Bool {
        let keys = radarrDetail?.mediaServerKeys ?? sonarrDetail?.mediaServerKeys ?? []
        return keys.isEmpty ? item.watched : MediaServerIndex.shared.isWatched(keys)
    }
}
