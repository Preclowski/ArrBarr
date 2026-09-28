import Foundation
import os
import MediaKit

/// Queue rows plus the side loads a row needs: entity details (title, poster, ids) and the existing file for the upgrade diff.
enum ArrQueueLoader {
    nonisolated private static let log = Logger(category: "QueueFetch")
    /// A live stream's failed fetch, with the revision it was published under.
    struct LiveFailure: Error {
        let underlying: any Error
        let revision: QueueRevision
    }

    struct Measured {
        let items: [QueueItem]
        let measuredAt: Date?
        /// The live stream revision these rows came from; nil for a direct store read.
        let revision: QueueRevision?
    }

    static func items(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService? = nil, baseURL: String) async throws -> [QueueItem] {
        do { return try await measuredItems(source: source, gateway: gateway, service: service, baseURL: baseURL, refresh: true).items }
        catch let failure as LiveFailure { throw failure.underlying }
    }

    /// `refresh: false` composes what the live stream last published, without asking the arr.
    static func measuredItems(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService? = nil, baseURL: String,
                              refresh: Bool) async throws -> Measured {
        await gateway.ready()
        let service = service ?? gateway.servarr(source)
        guard gateway.isConfigured(service.instance) else { throw MediaKitError.notConfigured(service.instance) }
        let store = gateway.store
        let read = try await queueRecords(source: source, gateway: gateway, service: service, refresh: refresh)
        let items = await compose(read.records, source: source, service: service, store: store, baseURL: baseURL)
        return Measured(items: items, measuredAt: read.measuredAt, revision: read.revision)
    }

    private static func compose(_ records: [ArrQueueRecord], source: QueueItem.Source, service: ServarrService, store: ResourceStore,
                                baseURL: String) async -> [QueueItem] {
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
            (r.seriesId ?? r.series?.id).flatMap { meta[$0]?.mediaServerKeys } ?? r.series?.mediaServerKeys ?? []
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

    /// The saved instance reads through its live stream; a Settings draft (another ordinal) straight from the store.
    private static func queueRecords(source: QueueItem.Source, gateway: ServiceGateway, service: ServarrService,
                                     refresh: Bool) async throws -> (records: [ArrQueueRecord], measuredAt: Date?, revision: QueueRevision?) {
        guard service.instance == source.instanceID else {
            let fetched = try await gateway.store.read(service.queue(), policy: .mustRevalidate)
            return (fetched.value.records, fetched.fetchedAt, nil)
        }
        let stream = gateway.queueStream(source)
        if refresh { await stream.refreshNow() }
        let value = stream.last()
        let revision = value.map { QueueRevision(stream: ObjectIdentifier(stream), number: $0.revision, overlay: $0.overlay) }
        if let value, let revision, let error = value.failures[service.instance] { throw LiveFailure(underlying: error, revision: revision) }
        let slice = value?.slices[service.instance]
        return (slice?.elements ?? [], slice?.measuredAt, revision)
    }

    private static func entityMeta(service: ServarrService, source: QueueItem.Source, ids: [Int], store: ResourceStore, baseURL: String) async -> [Int: ArrCompositions.EntityMeta] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int: ArrCompositions.EntityMeta] = [:]
        await withTaskGroup(of: (Int, ArrCompositions.EntityMeta?).self) { group in
            for id in ids {
                group.addTask {
                    switch source {
                    case .radarr, .whisparr:
                        guard let m = await log.attempt("queue movie metadata", { try await store.read(service.movie(id: id), priority: .background).value }) else { return (id, nil) }
                        let keys = source == .radarr ? m.mediaServerKeys : []
                        let (poster, auth) = (m.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: keys)
                        return (id, .init(title: m.title, year: m.year, slug: m.titleSlug, poster: poster, posterRequiresAuth: auth, mediaServerKeys: keys))
                    case .sonarr:
                        guard let s = await log.attempt("queue series metadata", { try await store.read(service.seriesDetails(id: id), priority: .background).value }) else { return (id, nil) }
                        let keys = s.mediaServerKeys
                        let (poster, auth) = (s.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: keys)
                        return (id, .init(title: s.title, year: s.year, slug: s.titleSlug, poster: poster, posterRequiresAuth: auth, mediaServerKeys: keys))
                    case .lidarr:
                        guard let a = await log.attempt("queue album metadata", { try await store.read(service.album(id: id), priority: .background).value }) else { return (id, nil) }
                        let (poster, auth) = a.coverURL(baseURL: baseURL)
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

    static func history(source: QueueItem.Source, gateway: ServiceGateway, baseURL: String, page: Int, pageSize: Int, entityId: Int?) async throws -> HistoryPage {
        await gateway.ready()
        let service = gateway.servarr(source)
        guard gateway.isConfigured(service.instance) else { throw MediaKitError.notConfigured(service.instance) }
        let resource = entityId.map { service.historyFor(entityID: $0, pageSize: pageSize) } ?? service.history(page: page, pageSize: pageSize)
        let result = try await gateway.store.read(resource, policy: page == 1 ? .staleWhileRevalidate : .cacheFirst).value
        let items = result.records.compactMap { ArrCompositions.history($0, source: source, baseURL: baseURL) }
        return HistoryPage(items: items, hasMore: page * pageSize < (result.totalRecords ?? 0))
    }
}
