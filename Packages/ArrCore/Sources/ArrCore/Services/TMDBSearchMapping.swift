import Foundation

/// One place that turns TMDB summary payloads into `SearchResult` rows.
///
/// Both the chat TMDB tools and (soon) the person view's filmography render
/// TMDB movies/series as the same `SearchResult` the arr-lookup path produces,
/// so the mapping — poster URL derivation, genre-id → name, library-owned
/// tagging, the tvdb-id-is-not-a-tmdb-id caveat — lives here rather than being
/// re-derived per surface.
public enum TMDBSearchMapping {

    /// TMDB movies → `SearchResult`. `libraryMap` (tmdbId → Radarr movie id)
    /// tags already-owned results with `inLibraryArrId`, so the UI routes their
    /// tap to the detail view instead of the add flow.
    public static func movies(
        _ movies: some Sequence<TMDBMovieSummary>,
        libraryMap: [Int: Int] = [:],
        roles: [Int: String] = [:]
    ) -> [SearchResult] {
        movies.map { m in
            SearchResult(
                id: m.id,
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
                source: .radarr,
                inLibraryArrId: libraryMap[m.id]
            )
        }
    }

    /// TMDB series → `SearchResult`. The TV path is fuzzier than movies: Sonarr
    /// indexes by tvdbId while TMDB exposes its own tv id, so we stash `0` in
    /// `id` — the add-tap path then falls back to a title lookup and Sonarr
    /// resolves the right tvdbId at add time. `libraryMap` (tvdbId → Sonarr
    /// series id) can only tag results that already carry a real tvdbId, so
    /// TMDB-discover rows stay untagged; callers that resolved through Sonarr's
    /// own lookup can pass a populated map.
    public static func series(
        _ shows: some Sequence<TMDBTVSummary>,
        libraryMap: [Int: Int] = [:],
        roles: [Int: String] = [:]
    ) -> [SearchResult] {
        shows.map { s in
            SearchResult(
                id: 0,
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
                source: .sonarr
            )
        }
    }
}
