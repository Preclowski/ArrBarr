import Foundation
import MediaKit

nonisolated public struct RadarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .radarr
    public let serviceName = "Radarr"

    init(config: ServiceConfig) { self.config = config }

    func fetchQueue() async throws -> [QueueItem] {
        let c = try await context()
        return try await ArrQueueLoader.items(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchCalendar() async throws -> [UpcomingItem] {
        let c = try await context()
        return try await ArrQueueLoader.upcoming(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }

    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail { try await read(RadarrMovieDetail.self) { $0.movie(id: id) } }
    func fetchMovieFile(movieId: Int) async throws -> ArrFile? { try await read([ArrFile].self) { $0.movieFiles([movieId]) }.first }
    func fetchCredits(movieId: Int) async throws -> [ArrCore.ArrCredit] { try await read([ArrCore.ArrCredit].self) { $0.credits(movieID: movieId) } }
    func searchMovie(movieId: Int) async throws { try await run { $0.search(.movies([movieId])) } }
    func lookupMovies(term: String) async throws -> [RadarrLookupRecord] { try await read([RadarrLookupRecord].self) { $0.lookupMovies(term: term) } }
    /// `revalidate: false` serves whatever the on-disk store holds and says so
    /// in `isStale`, refreshing behind the caller — what the Library's first
    /// paint of a session wants.
    func fetchAllMovies(revalidate: Bool = true) async throws -> [RadarrLibraryRecord] {
        try await fetchAllMoviesFetched(revalidate: revalidate).value
    }

    func fetchAllMoviesFetched(revalidate: Bool = true) async throws -> Fetched<[RadarrLibraryRecord]> {
        try await readCacheFirst([RadarrLibraryRecord].self, revalidate: revalidate) { $0.movies() }
    }

    /// Inline alternate titles when the library carries them; otherwise the dedicated endpoint.
    func alternateTitleMap(for movies: [RadarrLibraryRecord]) async -> [Int: [String]] {
        var inline: [Int: [String]] = [:]
        for movie in movies {
            guard let id = movie.id else { continue }
            let titles = (movie.alternateTitles ?? []).compactMap(\.title).filter { !$0.isEmpty }
            if !titles.isEmpty { inline[id] = titles }
        }
        if !inline.isEmpty { return inline }
        guard let rows = try? await read([ArrCore.ArrAlternateTitle].self, { $0.alternateTitles() }) else { return [:] }
        var out: [Int: [String]] = [:]
        for row in rows {
            guard let id = row.movieId, id > 0, let title = row.title, !title.isEmpty else { continue }
            out[id, default: []].append(title)
        }
        return out
    }
}

nonisolated func parseArrDate(_ string: String) -> Date? {
    ArrDateParser.shared.parse(string)
}

/// Servarr dates come zoned, zoneless, or date-only; the memo keeps the row mappers cheap.
nonisolated private final class ArrDateParser: @unchecked Sendable {
    static let shared = ArrDateParser()
    private let lock = NSLock()
    private let zonedFractional = ISO8601DateFormatter()
    private let zoned = ISO8601DateFormatter()
    private let zoneless = ISO8601DateFormatter()
    private let dateOnly = ISO8601DateFormatter()
    private var dateOnlyZone: TimeZone
    private var memo: [String: Date?] = [:]
    private static let memoLimit = 2_048

    private init() {
        zonedFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        zoned.formatOptions = [.withInternetDateTime]
        zoneless.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        zoneless.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.formatOptions = [.withFullDate]
        dateOnlyZone = Calendar.current.timeZone
        dateOnly.timeZone = dateOnlyZone
    }

    func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let zone = Calendar.current.timeZone
        if zone != dateOnlyZone {
            dateOnlyZone = zone
            dateOnly.timeZone = zone
            memo.removeAll(keepingCapacity: true)
        }
        if let hit = memo[string] { return hit }
        let parsed = zonedFractional.date(from: string) ?? zoned.date(from: string) ?? zoneless.date(from: string) ?? dateOnly.date(from: string)
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[string] = parsed
        return parsed
    }
}

nonisolated func clampedBytes(_ value: Double?) -> Int64 {
    guard let value, value > 0 else { return 0 }
    guard value < Double(Int64.max) else { return Int64.max }
    return Int64(value)
}

nonisolated func parseProtocol(_ raw: String?) -> QueueItem.DownloadProtocol {
    switch raw?.lowercased() {
    case "usenet", "usenetdownloadprotocol": return .usenet
    case "torrent", "torrentdownloadprotocol": return .torrent
    default: return .unknown
    }
}

nonisolated func parseStatus(arrStatus: String?, trackedState: String?, trackedStatus: String? = nil) -> QueueItem.Status {
    let status = arrStatus?.lowercased()
    if status == "paused" { return .paused }
    func resolve() -> QueueItem.Status {
        if let tracked = trackedState?.lowercased() {
            switch tracked {
            case "downloading": return .downloading
            case "downloadfailed", "downloadfailedpending", "failedpending", "failed", "importfailed": return .failed
            case "importing", "importpending": return trackedStatus?.lowercased() == "warning" ? .warning : .importing
            case "imported": return .completed
            case "importblocked", "ignored": return .warning
            default: break
            }
        }
        switch status {
        case "downloading": return .downloading
        case "queued", "delay": return .queued
        case "completed": return .completed
        case "warning": return .warning
        case "failed": return .failed
        default: return .unknown
        }
    }
    let resolved = resolve()
    if resolved == .completed, trackedStatus?.lowercased() == "error" { return .failed }
    return resolved
}
