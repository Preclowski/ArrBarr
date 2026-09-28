import Foundation
import MediaKit

/// TMDB summary payloads → the same `SearchResult` rows the arr-lookup path produces.
nonisolated enum TMDBSearchMapping {

    /// `libraryMap` (tmdbId → ownership) routes owned results to the detail view.
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

    /// `id` (the tvdbId slot) stays 0; the TMDB id rides in `tmdbTVId`, which every
    /// consumer resolves from. Never re-find the show by title: that opened the wrong series.
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
