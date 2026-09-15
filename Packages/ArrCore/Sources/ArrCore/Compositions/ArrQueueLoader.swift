import Foundation
import MediaKit

/// Queue rows plus the side loads a row needs: entity details (title, poster, ids) and the existing file for the upgrade diff.
enum ArrQueueLoader {
    static func items(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService? = nil, baseURL: String) async throws -> [QueueItem] {
        await gateway.ready()
        let service = service ?? gateway.servarr(source)
        guard gateway.isConfigured(service.instance) else { throw MediaKitError.notConfigured(service.instance) }
        let store = gateway.store
        let records = try await store.read(service.queue(), policy: .mustRevalidate).value.records
        let entityIDs = Array(Set(records.compactMap { ArrCompositions.entityID(of: $0, source: source) }.filter { $0 > 0 }))
        async let metaTask = entityMeta(service: service, source: source, ids: entityIDs, store: store, baseURL: baseURL)
        async let filesTask = store.batch(service.files, keys: entityIDs, priority: .background)
        let meta = await metaTask
        var files: [Int: [MediaKit.ArrFile]] = [:]
        for (id, result) in await filesTask { if case let .success(rows) = result { files[id] = rows } }
        guard source == .sonarr else {
            return records.map { ArrCompositions.queueItem($0, source: source, baseURL: baseURL, files: files, meta: meta) }
        }
        // Sonarr keys files by series; the row wants its episode file, found by id across the series' files.
        files = Dictionary(grouping: files.values.flatMap { $0 }, by: { $0.seriesId ?? 0 })
        let packs = ArrCompositions.seasonPackSeasons(records)
        func keys(_ r: ArrQueueRecord) -> [MediaServerExternalKey] {
            (r.seriesId ?? r.series?.id).flatMap { meta[$0]?.mediaServerKeys } ?? ArrCompositions.keys(series: r.series)
        }
        for r in records where packs[r.downloadId ?? ""] != nil {
            let k = keys(r)
            if !k.isEmpty { await MediaServerIndex.shared.loadSeasonPosters(for: k) }
        }
        return records.map { r in
            let seasonPoster = (r.downloadId.flatMap { packs[$0] }).flatMap { MediaServerIndex.shared.seasonPosterURL(for: keys(r), season: $0) }
            return ArrCompositions.queueItem(r, source: source, baseURL: baseURL, files: files, meta: meta, seasonPoster: seasonPoster)
        }
    }

    private static func entityMeta(service: ServarrService, source: QueueItem.Source, ids: [Int], store: ResourceStore, baseURL: String) async -> [Int: ArrCompositions.EntityMeta] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int: ArrCompositions.EntityMeta] = [:]
        await withTaskGroup(of: (Int, ArrCompositions.EntityMeta?).self) { group in
            for id in ids {
                group.addTask {
                    switch source {
                    case .radarr, .whisparr:
                        guard let m = try? await store.read(service.movie(id: id), priority: .background).value else { return (id, nil) }
                        let keys = source == .radarr ? ArrCompositions.keys(movie: m) : []
                        let (poster, auth) = ArrCompositions.posterURL(m.images, baseURL: baseURL, keys: keys)
                        return (id, .init(title: m.title, year: m.year, slug: m.titleSlug, poster: poster, posterRequiresAuth: auth, mediaServerKeys: keys))
                    case .sonarr:
                        guard let s = try? await store.read(service.seriesDetails(id: id), priority: .background).value else { return (id, nil) }
                        let keys = ArrCompositions.keys(series: s)
                        let (poster, auth) = ArrCompositions.posterURL(s.images, baseURL: baseURL, keys: keys)
                        return (id, .init(title: s.title, year: s.year, slug: s.titleSlug, poster: poster, posterRequiresAuth: auth, mediaServerKeys: keys))
                    case .lidarr:
                        guard let a = try? await store.read(service.album(id: id), priority: .background).value else { return (id, nil) }
                        var (poster, auth) = ArrCompositions.posterURL(a.images, baseURL: baseURL, coverTypes: ["cover", "poster"])
                        if poster == nil { (poster, auth) = ArrCompositions.posterURL(a.artist?.images, baseURL: baseURL, coverTypes: ["poster", "cover"]) }
                        return (id, .init(title: a.title, secondary: a.artist?.artistName, slug: a.foreignAlbumId, poster: poster, posterRequiresAuth: auth))
                    }
                }
            }
            for await (id, meta) in group { if let meta { out[id] = meta } }
        }
        return out
    }

    static func upcoming(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService? = nil, baseURL: String, policy: ReadPolicy = .staleWhileRevalidate) async throws -> [UpcomingItem] {
        await gateway.ready()
        let service = service ?? gateway.servarr(source)
        guard gateway.isConfigured(service.instance) else { throw MediaKitError.notConfigured(service.instance) }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let records = try await gateway.store.read(service.calendar(start: now, end: end), policy: policy).value
        return records.compactMap { ArrCompositions.upcoming($0, source: source, baseURL: baseURL) }
    }

    static func history(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService? = nil, baseURL: String, page: Int, pageSize: Int, entityId: Int?) async throws -> HistoryPage {
        await gateway.ready()
        let service = service ?? gateway.servarr(source)
        guard gateway.isConfigured(service.instance) else { throw MediaKitError.notConfigured(service.instance) }
        let resource = entityId.map { service.historyFor(entityID: $0, pageSize: pageSize) } ?? service.history(page: page, pageSize: pageSize)
        let result = try await gateway.store.read(resource, policy: page == 1 ? .staleWhileRevalidate : .cacheFirst).value
        let items = result.records.compactMap { ArrCompositions.history($0, source: source, baseURL: baseURL) }
        return HistoryPage(items: items, hasMore: page * pageSize < (result.totalRecords ?? 0))
    }
}
