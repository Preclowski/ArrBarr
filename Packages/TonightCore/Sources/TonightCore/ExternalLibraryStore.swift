import Foundation
import Combine
import ArrCore
import MediaKit

/// Read-only view of the user's existing media world, keyed by TMDB id:
/// what's already OWNED (present in Plex/Jellyfin/Emby, Radarr or Sonarr)
/// and what's been WATCHED (media server play state). Connection settings
/// come straight out of ArrBarr's defaults plist — nothing is configured
/// twice, and nothing is ever written back.
@MainActor
public final class ExternalLibraryStore: ObservableObject {
    public static let shared = ExternalLibraryStore()

    /// TMDB ids of watched titles. Server entries don't distinguish movie
    /// from show ids, but TMDB's two id namespaces rarely collide within one
    /// household library — accepted for a read-only badge.
    @Published public private(set) var watchedTmdbIds: Set<Int> = []
    /// TMDB ids present anywhere: media server library, Radarr, Sonarr.
    @Published public private(set) var ownedTmdbIds: Set<Int> = []
    /// TMDB id → the artwork the media server holds: poster, backdrop and
    /// clear logo. Token-free (the credential travels in a header at fetch
    /// time), so it is safe to cache on disk next to the rest of this index.
    ///
    /// The backdrop and the logo exist nowhere else — TMDB has its own
    /// backdrops but not the one the user picked, and nobody but the server
    /// has a clear logo at all.
    @Published public private(set) var serverArtwork: [Int: Artwork] = [:]
    @Published public private(set) var sourceNames: [String] = []
    /// The same ownership, kept per source instead of pooled: the detail page
    /// answers "in Plex, not in Radarr", which the union above cannot say.
    @Published public private(set) var ownedBySource: [String: Set<Int>] = [:]
    @Published public private(set) var lastRefreshed: Date?
    @Published public private(set) var refreshing = false

    private static let cacheURL = TonightConfig.supportDirectory
        .appending(path: "external-library.json")

    /// Whether a media server (not just an arr) is connected — the artwork
    /// preference is meaningless without one.
    public var hasMediaServer: Bool { ArrBarrProfile.mediaServerConfig() != nil }

    public var isAvailable: Bool { Self.isAvailableNow }

    /// The same answer, readable from any thread: it only reads ArrBarr's
    /// defaults, never this store's state. MediaKit asks its providers
    /// whether they are configured from its own executor, and reaching the
    /// main actor from there — `MainActor.assumeIsolated` — traps.
    public nonisolated static var isAvailableNow: Bool {
        ArrBarrProfile.mediaServerConfig() != nil
            || ArrBarrProfile.service(.radarr) != nil
            || ArrBarrProfile.service(.sonarr) != nil
    }

    private init() {
        loadCache()
        MediaServerPosterAccess.shared.update(ArrBarrProfile.mediaServerConfig())
        Task { await refresh() }
    }

    public func isWatched(_ item: MediaItem) -> Bool {
        watchedTmdbIds.contains(item.tmdbId)
    }

    public func isOwned(_ item: MediaItem) -> Bool {
        ownedTmdbIds.contains(item.tmdbId)
    }

    /// The media server's own poster for a title, when it has one.
    ///
    /// This is the artwork the user actually curated — the one they recognise
    /// from Plex/Jellyfin, sometimes a custom upload, and for an obscure title
    /// often better than TMDB's. Nil for everything the server doesn't have,
    /// which is most of what the app browses.
    public func posterURL(for item: MediaItem) -> URL? {
        sized(artwork(for: item)?.poster, width: 500)
    }

    /// The backdrop the user's server holds — the art they see on their own
    /// TV, rather than TMDB's pick.
    public func backdropURL(for item: MediaItem) -> URL? {
        sized(artwork(for: item)?.backdrop, width: 1280, aspect: .wide)
    }

    /// The same backdrop, asked for at card size. A wide shelf card is 300 pt
    /// across; pulling the server's original — often a megabyte — once per
    /// card is exactly the waste this layer is supposed to catch.
    public func cardBackdropURL(for item: MediaItem) -> URL? {
        sized(artwork(for: item)?.backdrop, width: 780, aspect: .wide)
    }

    /// Ask the server to downscale. Logos are deliberately NOT sized: Plex's
    /// transcoder returns JPEG, and a clear logo without its alpha channel is
    /// a white box over the artwork.
    private func sized(_ url: URL?, width: Int,
                       aspect: MediaServerArtworkSizing.Aspect = .poster) -> URL? {
        guard let url else { return nil }
        guard let flavor = serverFlavor, let base = serverBaseURL else { return url }
        return MediaServerArtworkSizing.sized(url, flavor: flavor, baseURL: base,
                                              width: width, aspect: aspect) ?? url
    }

    private var serverFlavor: MediaServerFlavor? {
        switch ArrBarrProfile.mediaServerConfig()?.kind {
        case .plex: .plex
        case .jellyfin: .jellyfin
        case .emby: .emby
        case nil: nil
        }
    }

    private var serverBaseURL: URL? {
        ArrBarrProfile.mediaServerConfig().flatMap { URL(string: $0.baseURL) }
    }

    /// The clear logo: the title, drawn the way the film's own marketing
    /// draws it, on transparency. It is what makes a hero look like Apple TV
    /// instead of a screenshot with text over it — and only the media server
    /// has one.
    public func logoURL(for item: MediaItem) -> URL? {
        artwork(for: item)?.logo
    }

    private func artwork(for item: MediaItem) -> Artwork? {
        guard TonightConfig.shared.useServerArtwork else { return nil }
        return serverArtwork[item.tmdbId]
    }

    public func refresh() async {
        refreshing = true
        defer { refreshing = false }
        var watched = Set<Int>()
        var sources: [String] = []
        var bySource: [String: Set<Int>] = [:]
        var artwork: [Int: Artwork] = [:]

        // ArrCore's poster access resolves the auth header for server-hosted
        // artwork; nothing fetches a poster from the server until it knows
        // which server that is.
        MediaServerPosterAccess.shared.update(ArrBarrProfile.mediaServerConfig())

        if let config = ArrBarrProfile.mediaServerConfig() {
            let name = config.kind.displayName
            var ids = Set<Int>()

            // MediaKit's own sweep first: it is the only one that brings back
            // backdrops and clear logos.
            if let server = MediaStack.shared.mediaServer,
               let titles = try? await server.titles(), !titles.isEmpty {
                for (tmdbID, title) in titles {
                    ids.insert(tmdbID)
                    if title.watched { watched.insert(tmdbID) }
                    artwork[tmdbID] = title.artwork
                }
            } else if let client = MediaServerClientFactory.make(config: config),
                      let entries = try? await client.libraryIndex() {
                // Fallback: ArrCore's index. Posters only — but a library
                // that shows up with plain artwork beats one that doesn't
                // show up at all.
                for entry in entries {
                    for key in entry.externalKeys {
                        if case .tmdb(let id) = key {
                            ids.insert(id)
                            if entry.watched { watched.insert(id) }
                            if let poster = entry.posterURL {
                                artwork[id] = Artwork(poster: poster)
                            }
                        }
                    }
                }
            }
            if !ids.isEmpty {
                sources.append(name)
                bySource[name] = ids
            }
        }
        if let ids = await Self.fetchArrTmdbIds(service: .radarr, path: "/api/v3/movie") {
            sources.append("Radarr")
            bySource["Radarr"] = ids
        }
        if let ids = await Self.fetchArrTmdbIds(service: .sonarr, path: "/api/v3/series") {
            sources.append("Sonarr")
            bySource["Sonarr"] = ids
        }

        guard !sources.isEmpty else { return }
        ownedTmdbIds = bySource.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        watchedTmdbIds = watched
        sourceNames = sources
        ownedBySource = bySource
        serverArtwork = artwork
        lastRefreshed = .now
        saveCache()
    }

    /// Where to look this title up in the media server's own web app. Plex
    /// and Jellyfin both have a stable search route; a per-item deep link
    /// would need the server's internal item key, which this index does not
    /// keep — a search on the title lands in the same place.
    nonisolated static func mediaServerWebURL(title: String) -> URL? {
        guard let config = ArrBarrProfile.mediaServerConfig(),
              let base = URL(string: config.baseURL),
              let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        switch config.kind {
        case .plex:
            return URL(string: "\(base.absoluteString)/web/index.html#!/search?query=\(query)")
        case .jellyfin, .emby:
            return URL(string: "\(base.absoluteString)/web/#/search.html?query=\(query)")
        }
    }

    // MARK: - ArrBarr config import

    /// Minimal direct call — all we need is one id per library record, and
    /// ArrCore's arr clients are not public yet. Sonarr v4
    /// reports `tmdbId` alongside `tvdbId`; records without one are skipped.
    nonisolated private static func fetchArrTmdbIds(service: ServiceKind, path: String) async -> Set<Int>? {
        guard let (base, key) = ArrBarrProfile.service(service) else { return nil }
        struct Record: Decodable { let tmdbId: Int? }
        guard var components = URLComponents(url: base.appending(path: path),
                                             resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false,
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return nil }
        return Set(records.compactMap { $0.tmdbId }.filter { $0 > 0 })
    }

    // MARK: - Cache

    private struct CacheFormat: Codable {
        var watched: [Int]
        var owned: [Int]
        var sources: [String]
        var refreshedAt: Date?
        /// Written since the detail page started asking per source; an older
        /// cache simply has none until the next refresh.
        var ownedBySource: [String: [Int]]?
        /// TMDB id → media-server artwork. Absent in caches written before
        /// the app learned to prefer the server's own pictures.
        var serverArtwork: [Int: StoredArtwork]?
    }

    /// `MediaKit.Artwork` is Codable, but this file's format has to survive
    /// the layer changing shape — so the cache keeps its own three fields.
    private struct StoredArtwork: Codable {
        var poster: URL?
        var backdrop: URL?
        var logo: URL?
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(CacheFormat.self, from: data)
        else { return }
        watchedTmdbIds = Set(cache.watched)
        ownedTmdbIds = Set(cache.owned)
        sourceNames = cache.sources
        ownedBySource = (cache.ownedBySource ?? [:]).mapValues(Set.init)
        serverArtwork = (cache.serverArtwork ?? [:]).mapValues {
            Artwork(poster: $0.poster, backdrop: $0.backdrop, logo: $0.logo)
        }
        lastRefreshed = cache.refreshedAt
    }

    private func saveCache() {
        let cache = CacheFormat(watched: Array(watchedTmdbIds), owned: Array(ownedTmdbIds),
                                sources: sourceNames, refreshedAt: lastRefreshed,
                                ownedBySource: ownedBySource.mapValues(Array.init),
                                serverArtwork: serverArtwork.mapValues {
                                    StoredArtwork(poster: $0.poster, backdrop: $0.backdrop,
                                                  logo: $0.logo)
                                })
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: TonightConfig.supportDirectory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
