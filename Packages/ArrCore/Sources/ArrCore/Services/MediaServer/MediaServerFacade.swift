import Foundation
import MediaKit

/// Plex, Jellyfin and Emby through MediaKit, in the vocabulary `MediaServerIndex` and the settings pane consume.
nonisolated struct MediaServerFacade: MediaServerClient {
    let config: MediaServerConfig

    private func context() async throws -> (gateway: ServiceGateway, service: MediaServerService) {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let gateway = await ServiceGateway.resolve()
        let instance = await gateway.adopt(mediaServer: config)
        await gateway.ready()
        guard gateway.isConfigured(instance) else { throw MediaServerError.notConfigured }
        var userID = config.userId.isEmpty ? nil : config.userId
        if userID == nil, config.kind != .plex {
            let users = try await gateway.store.read(MediaServerService(instance: instance, capabilities: gateway.kit.capabilities).users()).value
            guard let first = users.first else { throw MediaServerError.noUserResolved }
            userID = first.id
        }
        return (gateway, MediaServerService(instance: instance, capabilities: gateway.kit.capabilities, userID: userID))
    }

    private var baseURL: URL { URL(string: normalizedBaseURL)! }

    func testConnection() async throws -> MediaServerHandshake {
        let (gateway, service) = try await context()
        let identity = try await gateway.store.read(service.identity(), policy: .mustRevalidate).value
        let name = config.kind.displayName
        return MediaServerHandshake(versionLine: identity.version.map { "\(name) \($0)" } ?? name, userId: config.kind == .plex ? nil : service.userID)
    }

    /// The store and instance this config reads through, for a projection that follows the store's revisions.
    func scope() async throws -> (store: ResourceStore, instance: InstanceID) {
        let (gateway, service) = try await context()
        return (gateway.store, service.instance)
    }

    /// Every movie and series with provider ids, play state and a token-free artwork reference; `fetchedAt` is the oldest section's.
    func libraryIndex(policy: ReadPolicy) async throws -> (entries: [MediaServerEntry], fetchedAt: Date) {
        let (gateway, service) = try await context()
        // Plex indexes per section; Jellyfin/Emby answer one recursive query for every library.
        let sections: [String] = config.kind == .plex
            ? try await gateway.store.read(service.libraries(), policy: policy).value.filter { $0.kind == .movie || $0.kind == .series }.map(\.key)
            : [""]
        var entries: [MediaServerEntry] = []
        var fetchedAt = Date()
        for section in sections {
            let fetched = try await gateway.store.read(service.libraryIndex(section: section), policy: policy)
            fetchedAt = min(fetchedAt, fetched.fetchedAt)
            for row in fetched.value {
                let keys = row.ids.compactMap { Self.externalKey($0, kind: row.kind) }
                guard !keys.isEmpty else { continue }
                entries.append(MediaServerEntry(itemId: row.itemID, poster: service.artwork(for: row, baseURL: baseURL), externalKeys: keys, watched: row.watched))
            }
        }
        return (entries, fetchedAt)
    }

    func libraries() async throws -> [ArrCore.MediaServerLibrary] {
        let (gateway, service) = try await context()
        return try await gateway.store.read(service.libraries()).value.map { library in
            let kind: ArrCore.MediaServerLibrary.Kind = switch library.kind {
            case .movie: .movies
            case .series: .series
            default: .other
            }
            return ArrCore.MediaServerLibrary(id: library.key, name: library.title.isEmpty ? library.key : library.title, kind: kind)
        }
    }

    func scanLibrary(id: String) async throws {
        let (gateway, service) = try await context()
        _ = try await gateway.store.run(service.scanLibrary(section: id))
    }

    func emptyTrash(libraryId: String) async throws {
        guard config.kind == .plex else { throw MediaServerError.trashUnsupported(server: config.kind.displayName) }
        let (gateway, service) = try await context()
        _ = try await gateway.store.run(service.emptyTrash(section: libraryId))
    }

    func nowPlaying() async throws -> [ArrCore.MediaServerSession] {
        let (gateway, service) = try await context()
        let sessions = try service.decodeSessions(try await gateway.kit.pipeline.send(service.sessionsPlan()))
        return sessions.map { s in
            ArrCore.MediaServerSession(title: s.parentTitle ?? s.title, subtitle: s.parentTitle == nil ? nil : s.title, user: s.user,
                                       device: s.device, isTranscoding: s.isTranscoding, progress: s.progress)
        }
    }

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch] {
        try await recentlyWatched(limit: limit, policy: .cacheFirst)
    }

    func recentlyWatched(limit: Int, policy: ReadPolicy) async throws -> [MediaServerWatch] {
        let (gateway, service) = try await context()
        return try await gateway.store.read(service.watchHistory(limit: limit), policy: policy).value.compactMap { row in
            guard !row.title.isEmpty else { return nil }
            return MediaServerWatch(title: row.title, year: nil, kind: row.kind == .movie ? .movie : .show,
                                    watchedAt: row.viewedAt, seriesItemId: row.seriesItemID,
                                    season: row.season, episode: row.episode)
        }
    }

    /// Season number → season artwork for one series item; seasons without their own artwork are absent.
    func seasonPosters(seriesItemId: String) async throws -> [Int: ArtworkReference] {
        let (gateway, service) = try await context()
        let map = try await gateway.store.read(service.seasonArtwork(item: seriesItemId)).value
        var out: [Int: ArtworkReference] = [:]
        for (number, value) in map {
            guard let season = Int(number) else { continue }
            if config.kind == .plex {
                out[season] = ArtworkReference(url: baseURL.appendingPathComponent(value), headers: ["X-Plex-Token": .credential(service.instance)],
                                               sizing: .plexTranscode(photoPath: value), kind: .poster)
            } else {
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, var components = URLComponents(url: baseURL.appendingPathComponent("/Items/\(parts[0])/Images/Primary"), resolvingAgainstBaseURL: false) else { continue }
                components.queryItems = [URLQueryItem(name: "tag", value: parts[1])]
                guard let url = components.url else { continue }
                let header = config.kind == .jellyfin ? "Authorization" : "X-Emby-Token"
                out[season] = ArtworkReference(url: url, headers: [header: .credential(service.instance)],
                                               sizing: .jellyfinFill(itemID: parts[0], tag: parts[1]), kind: .poster)
            }
        }
        return out
    }

    private static func externalKey(_ id: MediaID, kind: MediaKind) -> MediaServerExternalKey? {
        switch id.namespace {
        case .tmdbMovie: return id.intValue.map { .tmdbMovie($0) }
        case .tmdbSeries: return id.intValue.map { .tmdbSeries($0) }
        // A movie's TVDB id numbers TVDB's movie records, which overlap its series ids; the arrs only ask TVDB for series.
        case .tvdb: return kind == .series ? id.intValue.map { .tvdb($0) } : nil
        case .imdb: return .imdb(id.value)
        default: return nil
        }
    }
}
