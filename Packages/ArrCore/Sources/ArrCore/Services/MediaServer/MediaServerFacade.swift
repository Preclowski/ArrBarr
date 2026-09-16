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

    func libraryIndex() async throws -> [MediaServerEntry] {
        let (gateway, service) = try await context()
        // Plex indexes per section; Jellyfin/Emby answer one recursive query for every library.
        let sections: [String] = config.kind == .plex
            ? try await gateway.store.read(service.libraries()).value.filter { $0.kind == .movie || $0.kind == .series }.map(\.key)
            : [""]
        var entries: [MediaServerEntry] = []
        for section in sections {
            let rows = try await gateway.store.read(service.libraryIndex(section: section)).value
            for row in rows {
                let keys = row.ids.compactMap(Self.externalKey)
                guard !keys.isEmpty else { continue }
                let poster = service.artwork(for: row, baseURL: baseURL)?.url
                entries.append(MediaServerEntry(itemId: row.itemID, posterURL: poster, externalKeys: keys, watched: row.watched))
            }
        }
        return entries
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
        let (gateway, service) = try await context()
        return try await gateway.store.read(service.watchHistory(limit: limit)).value.compactMap { row in
            guard !row.title.isEmpty else { return nil }
            return MediaServerWatch(title: row.title, year: nil, kind: row.kind == .movie ? .movie : .show, watchedAt: row.viewedAt)
        }
    }

    func seasonPosters(seriesItemId: String) async throws -> [Int: URL] {
        let (gateway, service) = try await context()
        let map = try await gateway.store.read(service.seasonArtwork(item: seriesItemId)).value
        var out: [Int: URL] = [:]
        for (number, value) in map {
            guard let season = Int(number) else { continue }
            if config.kind == .plex {
                out[season] = baseURL.appendingPathComponent(value)
            } else {
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, var components = URLComponents(url: baseURL.appendingPathComponent("/Items/\(parts[0])/Images/Primary"), resolvingAgainstBaseURL: false) else { continue }
                components.queryItems = [URLQueryItem(name: "tag", value: parts[1])]
                if let url = components.url { out[season] = url }
            }
        }
        return out
    }

    private static func externalKey(_ id: MediaID) -> MediaServerExternalKey? {
        switch id.namespace {
        case .tmdbMovie, .tmdbSeries: return id.intValue.map { .tmdb($0) }
        case .tvdb: return id.intValue.map { .tvdb($0) }
        case .imdb: return .imdb(id.value)
        default: return nil
        }
    }
}
