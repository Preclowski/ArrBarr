import Foundation
import MediaKit

/// One place that turns TMDB summary payloads into `SearchResult` rows.
///
/// Both the chat TMDB tools and (soon) the person view's filmography render
/// TMDB movies/series as the same `SearchResult` the arr-lookup path produces,
/// so the mapping — poster URL derivation, genre-id → name, library-owned
/// tagging, the tvdb-id-is-not-a-tmdb-id caveat — lives here rather than being
/// re-derived per surface.
nonisolated enum TMDBSearchMapping {

    /// TMDB movies → `SearchResult`. `libraryMap` (tmdbId → ownership) tags
    /// already-owned results, so the UI routes their tap to the detail view
    /// instead of the add flow and shows the right ownership chip.
    static func movies(
        _ movies: some Sequence<TMDBMovieSummary>,
        libraryMap: [Int: LibraryOwnership] = [:],
        roles: [Int: String] = [:]
    ) -> [SearchResult] {
        movies.map { m in
            SearchResult(
                externalId: m.id,
                foreignId: String(m.id),
                title: m.title,
                subtitle: roles[m.id],
                year: m.year,
                rating: m.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: m.overview,
                runtime: nil,
                genres: TMDBGenres.movieNames(for: m.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: m.posterPath),
                source: .radarr
            )
            .withLibraryOwnership(libraryMap[m.id])
        }
    }

    /// TMDB series → `SearchResult`. Sonarr indexes by tvdbId while TMDB
    /// exposes its own tv id, so `id` (the tvdbId slot) stays `0` here and the
    /// TMDB id rides in `tmdbTVId` instead. That field is the whole point of
    /// this mapping: every consumer — ownership tagging, cast, trailer, the
    /// add flow — resolves from it by id. Nothing downstream may re-find the
    /// show by title; that is what opened the wrong series.
    ///
    /// `libraryMap` is **tmdbId → ownership** (`ArrLibraryMaps
    /// .sonarrByTMDBId`), so these rows tag exactly like the movie ones.
    static func series(
        _ shows: some Sequence<TMDBTVSummary>,
        libraryMap: [Int: LibraryOwnership] = [:],
        roles: [Int: String] = [:]
    ) -> [SearchResult] {
        shows.map { s in
            SearchResult(
                externalId: 0,
                foreignId: "",
                title: s.name,
                subtitle: roles[s.id],
                year: s.year,
                rating: s.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: s.overview,
                runtime: nil,
                genres: TMDBGenres.tvNames(for: s.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: s.posterPath),
                source: .sonarr,
                tmdbTVId: s.id
            )
            .withLibraryOwnership(libraryMap[s.id])
        }
    }
}
