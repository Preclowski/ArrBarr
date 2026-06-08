import Foundation

/// Hands the chat empty state a few poster URLs from the user's existing
/// library so the Quiz card can show a fanned deck of *their* titles instead
/// of a flat icon. We only keep `remoteUrl` (public TMDB/TVDB) posters so the
/// deck renders with `apiKey: nil` and reuses anything already in `ImageCache`.
///
/// The result is memoised process-wide: the first empty-state appearance does
/// one library fetch, every later one reads the cached sample. A single
/// in-flight task is shared so two near-simultaneous callers don't double-fetch.
@MainActor
public enum LibraryPosterSampler {
    private static var cache: [URL] = []
    private static var inFlight: Task<[URL], Never>?

    /// Cached sample if we already have one, else `nil` — lets a view show
    /// posters instantly on re-entry without awaiting.
    public static var cached: [URL]? { cache.isEmpty ? nil : cache }

    public static func sample(configStore: ConfigStore, max: Int = 8) async -> [URL] {
        if !cache.isEmpty { return cache }
        if let inFlight { return await inFlight.value }
        let task = Task { await fetch(configStore: configStore, max: max) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if !result.isEmpty { cache = result }
        return result
    }

    private static func fetch(configStore: ConfigStore, max: Int) async -> [URL] {
        var urls: [URL] = []
        if configStore.radarr.isConfigured,
           let movies = try? await RadarrClient(config: configStore.radarr).fetchAllMovies() {
            for rec in movies {
                let (url, needsAuth) = (rec.images ?? []).posterURL(baseURL: configStore.radarr.baseURL)
                if let url, !needsAuth { urls.append(url) }
            }
        }
        if configStore.sonarr.isConfigured,
           let series = try? await SonarrClient(config: configStore.sonarr).fetchAllSeries() {
            for rec in series {
                let (url, needsAuth) = (rec.images ?? []).posterURL(baseURL: configStore.sonarr.baseURL)
                if let url, !needsAuth { urls.append(url) }
            }
        }
        return Array(urls.shuffled().prefix(max))
    }
}
