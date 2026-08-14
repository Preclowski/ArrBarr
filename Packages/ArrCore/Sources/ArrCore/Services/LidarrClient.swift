import Foundation

public actor LidarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let apiBase = "/api/v1"
    public let serviceName = "Lidarr"
    public let http = HTTPClient()

    private struct CachedTrackFiles { let files: [LidarrTrackFile]; let expiry: Date }
    private var trackFileCache: [Int: CachedTrackFiles] = [:]
    /// See `SonarrClient.episodeFileCacheTTL` — same reasoning, same trade.
    private let trackFileCacheTTL: TimeInterval = 15 * 60

    init(config: ServiceConfig) {
        self.config = config
    }

    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/queue",
            query: [
                URLQueryItem(name: "pageSize", value: String(Self.queuePageSize)),
                // No `includeArtist` / `includeAlbum`: Servarr embeds the whole
                // artist and album in every row, on every poll, and `unify`
                // keeps four fields out of them. Measured on a 77-row queue,
                // that was ~1 MB per poll to learn names that change about
                // never. `TitleMetadataStore` holds them instead; the ids the
                // join needs (`albumId`, `artistId`) are top-level on the queue
                // resource and arrive without any include.
                //
                // `includeUnknownArtistItems` is a different thing and stays:
                // without it, downloads Lidarr can't map to a library artist
                // vanish from the queue entirely.
                URLQueryItem(name: "includeUnknownArtistItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let page: ArrQueuePage<LidarrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        warnIfQueueTruncated(returned: page.records.count, totalRecords: page.totalRecords)
        let baseURL = config.baseURL

        // Lidarr's /queue doesn't embed the on-disk files, so side-load the
        // album's track files (one call per album, cached, at most
        // `maxConcurrentSideLoads` in flight) and hand them to `unify` — the
        // album equivalent of Sonarr's per-series episode-file map. An album
        // with files on disk is an upgrade; its tracks aggregate into the
        // existing-file diff.
        let albumIds = Array(Set(page.records.compactMap { $0.album?.id ?? $0.albumId }.filter { $0 > 0 }))
        // Resolved alongside the track files rather than before them: neither
        // depends on the other, and both are usually pure cache hits.
        async let metaMap = resolveAlbumMetadata(ids: albumIds, baseURL: baseURL)
        var fileMap: [Int: [LidarrTrackFile]] = [:]
        await withTaskGroup(of: (Int, [LidarrTrackFile]).self) { group in
            var next = 0
            while next < min(Self.maxConcurrentSideLoads, albumIds.count) {
                let aid = albumIds[next]
                group.addTask { (aid, (try? await self.fetchTrackFiles(albumId: aid)) ?? []) }
                next += 1
            }
            // Each completion frees a slot — top the group back up so exactly
            // `maxConcurrentSideLoads` requests stay in flight until we run out.
            for await (aid, files) in group {
                fileMap[aid] = files
                if next < albumIds.count {
                    let nextId = albumIds[next]
                    group.addTask { (nextId, (try? await self.fetchTrackFiles(albumId: nextId)) ?? []) }
                    next += 1
                }
            }
        }
        let meta = await metaMap
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap, meta: meta) }
    }

    /// Album display metadata for these ids: cache first, one bulk call for the
    /// misses. Returns whatever it could resolve — a miss is not an error, it
    /// degrades the row to its release name rather than failing the refresh.
    private func resolveAlbumMetadata(
        ids: [Int], baseURL: String
    ) async -> [Int: TitleMetadataStore.Metadata] {
        guard !ids.isEmpty else { return [:] }
        func key(_ id: Int) -> TitleMetadataStore.Key {
            TitleMetadataStore.Key(source: .lidarr, baseURL: baseURL, kind: .album, id: id)
        }
        var byId: [Int: TitleMetadataStore.Metadata] = [:]
        for (k, v) in await TitleMetadataStore.shared.metadata(for: ids.map(key)) {
            byId[k.id] = v
        }
        let missing = ids.filter { byId[$0] == nil }
        guard !missing.isEmpty else { return byId }

        var fresh: [TitleMetadataStore.Key: TitleMetadataStore.Metadata] = [:]
        // Chunked because the ids go in the query string: a pathological queue
        // would otherwise build a URL long enough for the arr's reverse proxy
        // to reject it.
        for chunk in missing.chunked(into: 50) {
            guard let albums = try? await fetchAlbums(ids: chunk) else { continue }
            for album in albums {
                let metadata = Self.metadata(from: album, baseURL: baseURL)
                byId[album.id] = metadata
                fresh[key(album.id)] = metadata
            }
        }
        if !fresh.isEmpty { await TitleMetadataStore.shared.store(fresh) }
        return byId
    }

    private func fetchAlbums(ids: [Int]) async throws -> [LidarrAlbum] {
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/album",
            query: ids.map { URLQueryItem(name: "albumIds", value: String($0)) }
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([LidarrAlbum].self, from: data)) ?? []
    }

    /// The album cover is the row's artwork; the artist image stands in when the
    /// album has none. Resolved here, on write, so `unify` never re-derives it.
    private static func metadata(
        from album: LidarrAlbum, baseURL: String
    ) -> TitleMetadataStore.Metadata {
        var (poster, auth) = album.images?
            .posterURL(baseURL: baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false)
        if poster == nil {
            (poster, auth) = album.artist?.images?
                .posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false)
        }
        return TitleMetadataStore.Metadata(
            title: album.title,
            secondary: album.artist?.artistName,
            slug: album.foreignAlbumId,
            posterURL: poster,
            posterRequiresAuth: auth
        )
    }

    func fetchTrackFiles(albumId: Int) async throws -> [LidarrTrackFile] {
        if DemoMode.isActive { return DemoMocks.lidarrTrackFiles(albumId: albumId) }
        if let cached = trackFileCache[albumId], cached.expiry > Date() {
            return cached.files
        }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/trackfile",
            query: [URLQueryItem(name: "albumId", value: String(albumId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        let files = (try? JSONDecoder().decode([LidarrTrackFile].self, from: data)) ?? []
        trackFileCache[albumId] = CachedTrackFiles(
            files: files,
            expiry: Date().addingTimeInterval(trackFileCacheTTL)
        )
        return files
    }

    func fetchCalendar() async throws -> [UpcomingItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let records: [LidarrCalendarRecord]
        do {
            records = try JSONDecoder().decode([LidarrCalendarRecord].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        let baseURL = config.baseURL
        return records.compactMap { Self.unifyCalendar($0, baseURL: baseURL) }
    }

    func fetchHistory() async throws -> [HistoryItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/history",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: "50"),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
                URLQueryItem(name: "includeArtist", value: "true"),
                URLQueryItem(name: "includeAlbum", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)
        let page: ArrQueuePage<LidarrHistoryRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<LidarrHistoryRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        return page.records.compactMap { r in
            guard let dateStr = r.date, let date = parseArrDate(dateStr) else { return nil }
            let eventType = HistoryItem.EventType.parse(r.eventType)
            // Lidarr logs one `trackFileImported` row per track; tie the rows
            // of one download+album together so history can show the album
            // once. The subtitle is already the album title, so no override.
            var groupHint: HistoryItem.GroupHint?
            if eventType == .imported, let albumId = r.albumId,
               let batch = r.downloadId ?? r.sourceTitle {
                groupHint = .init(key: "\(batch)|album-\(albumId)")
            }
            return HistoryItem(
                id: "lidarr-h-\(r.id)",
                source: .lidarr,
                date: date,
                eventType: eventType,
                title: r.artist?.artistName ?? r.sourceTitle ?? "Unknown",
                subtitle: r.album?.title,
                sourceTitle: r.sourceTitle,
                quality: r.quality?.name,
                customFormats: (r.customFormats ?? []).map(\.name),
                customFormatScore: r.customFormatScore ?? 0,
                groupHint: groupHint
            )
        }
    }

    func fetchAlbumDetails(id: Int) async throws -> LidarrAlbumDetail {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let demo = await DemoMonitorState.apply(album: DemoMocks.lidarrAlbumDetail(id: id)) { return demo }
            throw HTTPError.decoding(NSError(domain: "demo", code: 404))
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "/api/v1/album/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(LidarrAlbumDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
    }

    func fetchTracks(albumId: Int) async throws -> [LidarrTrackDetail] {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return DemoMocks.lidarrTracks(albumId: albumId)
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/track",
            query: [URLQueryItem(name: "albumId", value: String(albumId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([LidarrTrackDetail].self, from: data)) ?? []
    }

    /// Artist-level record for `LidarrArtistView` — the surface search
    /// results and the post-add navigation land on (Lidarr's addable
    /// entity is the artist, not an album).
    func fetchArtistDetails(id: Int) async throws -> LidarrArtistDetail {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let demo = DemoMocks.lidarrArtistDetail(id: id) { return demo }
            throw HTTPError.decoding(NSError(domain: "demo", code: 404))
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "/api/v1/artist/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(LidarrArtistDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
    }

    func fetchAllArtists() async throws -> [LidarrLibraryRecord] {
        if DemoMode.isActive { return DemoMocks.lidarrLibrary() }
        guard config.isConfigured else { return [] }
        guard !config.apiKey.isEmpty else { return [] }
        let url = try http.url(base: config.baseURL, path: "/api/v1/artist")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([LidarrLibraryRecord].self, from: data)) ?? []
    }

    /// List albums of a specific artist. Slim shape via
    /// `LidarrAlbumListRecord` — enough for chat to filter by type/year
    /// and pick targets to monitor/search without paying for full detail.
    func fetchArtistAlbums(artistId: Int) async throws -> [LidarrAlbumListRecord] {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return DemoMocks.lidarrArtistAlbums(artistId: artistId)
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v1/album",
            query: [URLQueryItem(name: "artistId", value: String(artistId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([LidarrAlbumListRecord].self, from: data)) ?? []
    }

    /// Flip monitoring on a single album. Lidarr's PUT requires the
    /// full album object; the lean approach (POST `/api/v1/album/monitor`
    /// with a list) was deprecated. Fetch detail, mutate, put back.
    /// One round-trip more than ideal, but keeps the call payload-safe.
    func setAlbumMonitored(albumId: Int, monitored: Bool) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await DemoMonitorState.setAlbum(albumId, monitored: monitored)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        // Fetch existing record raw — we don't strip-decode, we forward
        // the object straight back with the one field toggled, so Lidarr
        // sees the full shape it expects.
        let getURL = try http.url(base: config.baseURL, path: "/api/v1/album/\(albumId)")
        let getData = try await http.get(getURL, headers: apiHeaders)
        guard var json = try JSONSerialization.jsonObject(with: getData) as? [String: Any] else {
            throw HTTPError.decoding(NSError(domain: "ArrBarr.Lidarr.setAlbumMonitored", code: 0))
        }
        json["monitored"] = monitored
        let putURL = try http.url(base: config.baseURL, path: "/api/v1/album/\(albumId)")
        let body = try JSONSerialization.data(withJSONObject: json)
        _ = try await http.put(putURL, headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 }, body: body)
    }

    /// Trigger an indexer search for a single album. Mirrors Sonarr's
    /// `EpisodeSearch` / Radarr's `MoviesSearch` — same /command path.
    func searchAlbum(albumId: Int) async throws {
        try await postCommand([
            "name": "AlbumSearch",
            "albumIds": [albumId],
        ])
    }

    /// Internal rather than private for the same reason as `unify`: this is
    /// where every field on an Upcoming album row is decided, and the tests
    /// pin it directly.
    static func unifyCalendar(_ r: LidarrCalendarRecord, baseURL: String) -> UpcomingItem? {
        guard let dateStr = r.releaseDate, let date = parseArrDate(dateStr) else { return nil }

        let artistName = r.artist?.artistName
        let title = artistName.map { "\($0) — \(r.title)" } ?? r.title
        // Try album cover first, fall back to artist image.
        var (poster, auth) = (r.images?.posterURL(baseURL: baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false))
        if poster == nil {
            (poster, auth) = (r.artist?.images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false))
        }

        // An album is "downloaded" when every track has a file — the same
        // completeness rule the Library tab applies to Lidarr entries.
        // (`hasFile: false` used to be hardcoded, so Upcoming never showed
        // the library badge / Downloaded chip for music.)
        let tracks = r.statistics?.trackCount ?? 0
        let trackFiles = r.statistics?.trackFileCount ?? 0
        return UpcomingItem(
            id: "lidarr-cal-\(r.id)",
            source: .lidarr,
            title: title,
            subtitle: nil,
            airDate: date,
            releaseType: "Album",
            hasFile: tracks > 0 && trackFiles >= tracks,
            overview: r.overview,
            posterURL: poster,
            posterRequiresAuth: auth,
            entityId: r.id,
            // Only when the arr actually knows the tracklist. An unreleased
            // album often has none yet, and "0 tracks" would be a claim the
            // data doesn't support.
            trackCount: tracks > 0 ? tracks : nil
        )
    }

    /// Wire record -> `QueueItem`. Internal rather than private so
    /// `QueueUnificationTests` can pin it: this is where every displayed field
    /// on a queue row is decided, and nothing else in the suite reaches it.
    static func unify(
        _ r: LidarrQueueRecord,
        baseURL: String,
        fileMap: [Int: [LidarrTrackFile]],
        meta: [Int: TitleMetadataStore.Metadata] = [:]
    ) -> QueueItem {
        let total = clampedBytes(r.size)
        let left = clampedBytes(r.sizeleft)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        // Store first, embedded objects second. The embedded path is dead in the
        // queue (the request no longer asks for it) but is kept rather than
        // deleted: it is still how history rows arrive, and it makes a metadata
        // miss degrade to "slightly worse" instead of "wrong".
        let albumId = r.album?.id ?? r.albumId
        let cached = albumId.flatMap { meta[$0] }
        let artistName = cached?.secondary ?? r.artist?.artistName ?? r.album?.artist?.artistName
        let albumTitle = cached?.title ?? r.album?.title ?? r.title ?? "Unknown"
        let displayTitle = artistName.map { "\($0) — \(albumTitle)" } ?? albumTitle
        var poster = cached?.posterURL
        var posterAuth = cached?.posterRequiresAuth ?? false
        if poster == nil {
            (poster, posterAuth) = (r.album?.images?.posterURL(baseURL: baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false))
        }
        if poster == nil {
            (poster, posterAuth) = (r.artist?.images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false))
        }

        // An album on disk is N track files, so there's no single "existing
        // file" the way a movie/episode has one — aggregate the album's tracks
        // into album-level diff fields (total size, representative quality /
        // score / formats). Having any files means this grab is an upgrade.
        // `existingFileName` stays nil: an album has no one old name (same as
        // a season pack, whose summary card also can't name a single file).
        let existing = (r.album?.id ?? r.albumId).flatMap { fileMap[$0] } ?? []
        let existingRep = existing.max(by: { ($0.size ?? 0) < ($1.size ?? 0) })
        let existingTotalSize = existing.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return QueueItem(
            id: "lidarr-\(r.id)",
            source: .lidarr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            indexer: r.indexer,
            title: displayTitle,
            subtitle: nil,
            releaseName: r.title,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState, trackedStatus: r.trackedDownloadStatus),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            isUpgrade: !existing.isEmpty,
            existingCustomFormats: (existingRep?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: existingRep?.customFormatScore,
            existingQuality: existingRep?.quality?.name,
            existingSize: existingTotalSize > 0 ? existingTotalSize : nil,
            existingFileName: nil,
            contentSlug: cached?.slug ?? r.album?.foreignAlbumId,
            entityId: r.album?.id ?? r.albumId,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            statusMessages: r.statusMessages.flattenToLines()
        )
    }
}
