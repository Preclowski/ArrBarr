import Foundation

/// Poster URLs from the user's library for the chat's Quiz card. Only `remoteUrl` posters,
/// so the deck renders with `apiKey: nil`. Memoised process-wide with one shared in-flight task.
public enum LibraryPosterSampler {
    private static var cache: [URL] = []
    private static var inFlight: Task<[URL], Never>?

    public static var cached: [URL]? { cache.isEmpty ? nil : cache }

    /// Samples and prefetches at launch so the deck is there on first open.
    /// No-op when the chat tab isn't available.
    public static func warmUp(configStore: ConfigStore) {
        guard configStore.aiConfigured else { return }
        Task {
            let urls = await sample(configStore: configStore)
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = await PosterStore.shared.image(for: url, tier: .card) }
                }
            }
        }
    }

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
           let movies = try? await configStore.radarrClient.fetchAllMovies() {
            for rec in movies {
                let (url, needsAuth) = (rec.images ?? []).posterURL(baseURL: configStore.radarr.baseURL, mediaServerKeys: rec.mediaServerKeys)
                if let url, !needsAuth { urls.append(url) }
            }
        }
        if configStore.sonarr.isConfigured,
           let series = try? await configStore.sonarrClient.fetchAllSeries() {
            for rec in series {
                let (url, needsAuth) = (rec.images ?? []).posterURL(baseURL: configStore.sonarr.baseURL, mediaServerKeys: rec.mediaServerKeys)
                if let url, !needsAuth { urls.append(url) }
            }
        }
        return Array(urls.shuffled().prefix(max))
    }
}
