import Foundation
import MediaKit

nonisolated public struct RadarrClient: MovieArrClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .radarr

    init(config: ServiceConfig) { self.config = config }

    func fetchCredits(movieId: Int) async throws -> [ArrCredit] { try await read { $0.credits(movieID: movieId) } }
    func lookupMovies(term: String) async throws -> [ArrMovie] { try await read { $0.lookupMovies(term: term) } }
    /// Inline alternate titles when the library carries them; otherwise the dedicated endpoint.
    func alternateTitleMap(for movies: [ArrMovie]) async -> [Int: [String]] {
        var inline: [Int: [String]] = [:]
        for movie in movies {
            guard let id = movie.id else { continue }
            let titles = (movie.alternateTitles ?? []).compactMap(\.title).filter { !$0.isEmpty }
            if !titles.isEmpty { inline[id] = titles }
        }
        if !inline.isEmpty { return inline }
        guard let rows = try? await read({ $0.alternateTitles() }) else { return [:] }
        var out: [Int: [String]] = [:]
        for row in rows {
            guard let id = row.movieId, id > 0, let title = row.title, !title.isEmpty else { continue }
            out[id, default: []].append(title)
        }
        return out
    }
}
