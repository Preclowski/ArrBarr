import Foundation

/// One service, four flavours. Every method is synchronous and builds its plan from the capability index.
public struct ServarrService: Sendable {
    public let instance: InstanceID
    public let profile: ServarrProfile
    private let capabilities: CapabilityIndex

    public init(instance: InstanceID, profile: ServarrProfile, capabilities: CapabilityIndex) {
        self.instance = instance; self.profile = profile; self.capabilities = capabilities
    }

    // MARK: - Plans

    private func plan(_ operation: String, method: String = "GET", path: String, values: [String: String] = [:], query: [(String, String)] = [],
                      body: HTTPRequest.Body = .none, priority: RequestPriority = .interactive, timeout: Duration = .seconds(15)) -> RequestPlan {
        RequestPlan(instance: instance, operation: operation, method: method, pathTemplate: profile.apiBase + path, pathValues: values,
                    query: query.map { .init($0.0, $0.1) }, body: body, auth: .header("X-Api-Key"), priority: priority, timeout: timeout)
    }

    private var entityTag: (Int) -> InvalidationTag { { .entity(instance, profile.entityKind, $0) } }
    private func tag(_ c: CollectionName) -> InvalidationTag { .collection(c, instance) }

    // MARK: - Resources

    public func status() -> Resource<ArrSystemStatus> {
        .json(plan("testConnection", path: "/system/status"), tags: [.capabilities(instance), tag(.status)], freshness: .reference)
    }

    public func health() -> Resource<[ArrHealth]> { .json(plan("fetchHealth", path: "/health"), tags: [tag(.health)], freshness: .live) }
    public func diskSpace() -> Resource<[ArrDiskSpace]> { .json(plan("fetchDiskSpace", path: "/diskspace"), tags: [tag(.health)], freshness: .live) }

    /// The live pump; never a store row.
    public func queuePlan() -> RequestPlan {
        plan("fetchQueue", path: "/queue", query: [("pageSize", "1000"), (profile.queueIncludeFlag, "true")], priority: .background)
    }

    public func queue() -> Resource<ArrPage<ArrQueueRecord>> { .json(queuePlan(), tags: [tag(.queue)], freshness: .volatile) }

    public func calendar(start: Date, end: Date) -> Resource<[ArrCalendarRecord]> {
        var query = [("start", Self.day(start)), ("end", Self.day(end)), ("unmonitored", "true")]
        if let key = profile.calendarIncludeKey { query.append((key, "true")) }
        return .json(plan("fetchCalendar", path: "/calendar", query: query), tags: [tag(.calendar)], freshness: .warm)
    }

    public func history(page: Int = 1, pageSize: Int = 50) -> Resource<ArrPage<ArrHistoryRecord>> {
        .json(plan("fetchHistory", path: "/history", query: historyQuery(page: page, pageSize: pageSize)), tags: [tag(.history)], freshness: .warm)
    }

    public func historyFor(entityID: Int, pageSize: Int = 50) -> Resource<ArrPage<ArrHistoryRecord>> {
        let operation = "fetchHistoryFor" + (profile.kind == .lidarr ? "Album" : profile.entityNoun.capitalized)
        let query = historyQuery(page: 1, pageSize: pageSize) + [(profile.historyIDsKey, String(entityID))]
        return .json(plan(operation, path: "/history", query: query), tags: [tag(.history), entityTag(entityID)], freshness: .warm)
    }

    private func historyQuery(page: Int, pageSize: Int) -> [(String, String)] {
        [("page", String(page)), ("pageSize", String(pageSize)), ("sortKey", "date"), ("sortDirection", "descending")] + profile.historyIncludeKeys.map { ($0, "true") }
    }

    public func movies() -> Resource<[ArrMovie]> {
        .json(plan("fetchAllMovies", path: "/movie"), tags: [tag(.library)], freshness: .warm, harvest: { $0.flatMap(harvestMovie) })
    }
    public func series() -> Resource<[ArrSeries]> {
        .json(plan("fetchAllSeries", path: "/series"), tags: [tag(.library)], freshness: .warm, harvest: { $0.flatMap(harvestSeries) })
    }
    public func artists() -> Resource<[ArrArtist]> {
        .json(plan("fetchAllArtists", path: "/artist"), tags: [tag(.library)], freshness: .warm, harvest: { $0.flatMap(harvestArtist) })
    }

    public func movie(id: Int) -> Resource<ArrMovie> {
        .json(plan("fetchMovieDetails", path: "/movie/{id}", values: ["id": String(id)]), tags: [entityTag(id), tag(.library)], freshness: .reference, harvest: harvestMovie)
    }
    public func seriesDetails(id: Int) -> Resource<ArrSeries> {
        .json(plan("fetchSeriesDetails", path: "/series/{id}", values: ["id": String(id)]), tags: [entityTag(id), tag(.library)], freshness: .reference, harvest: harvestSeries)
    }
    public func artist(id: Int) -> Resource<ArrArtist> {
        .json(plan("fetchArtistDetails", path: "/artist/{id}", values: ["id": String(id)]), tags: [entityTag(id), tag(.library)], freshness: .reference, harvest: harvestArtist)
    }
    public func album(id: Int) -> Resource<ArrAlbum> {
        .json(plan("fetchAlbumDetails", path: "/album/{id}", values: ["id": String(id)]), tags: [.entity(instance, .album, id)], freshness: .reference, harvest: harvestAlbum)
    }

    /// Radarr/Whisparr: one request per 25 ids. Sonarr/Lidarr have no batch endpoint: one request per parent through the limiter.
    public var files: BatchResource<Int, ArrFile> {
        let fileNoun = profile.fileNoun, parentKey = profile.fileParentKey, service = self
        if profile.entityKind == .movie {
            return BatchResource(.chunked(max: 25, make: { ids in
                let query = ids.map { (parentKey, String($0)) }
                return .json(service.plan("fetchMovieFile", path: "/" + fileNoun, query: query), tags: Set(ids.map(service.entityTag)), freshness: .reference)
            }, identify: { $0.movieId }))
        }
        let kind: MediaKind = profile.kind == .lidarr ? .album : .series
        let operation = profile.kind == .lidarr ? "fetchTrackFiles" : "fetchEpisodeFileMap"
        return BatchResource(.perKey(make: { parent in
            .json(service.plan(operation, path: "/" + fileNoun, query: [(parentKey, String(parent))]), tags: [.entity(service.instance, kind, parent)], freshness: .reference)
        }))
    }

    /// The batch strategies as plain resources, for callers that read one parent or one id list at a time.
    public func movieFiles(_ ids: [Int]) -> Resource<[ArrFile]> {
        guard case let .chunked(_, make, _) = files.strategy else { return filesOf(parent: ids.first ?? 0) }
        return make(ids)
    }

    public func filesOf(parent: Int) -> Resource<[ArrFile]> {
        switch files.strategy {
        case let .perKey(make): return make(parent)
        case let .chunked(_, make, _): return make([parent])
        }
    }

    public func episodes(seriesID: Int) -> Resource<[ArrEpisode]> {
        .json(plan("fetchEpisodes", path: "/episode", query: [("seriesId", String(seriesID))]), tags: [entityTag(seriesID)], freshness: .reference)
    }
    public func albums(artistID: Int) -> Resource<[ArrAlbum]> {
        .json(plan("fetchArtistAlbums", path: "/album", query: [("artistId", String(artistID))]), tags: [entityTag(artistID)], freshness: .reference)
    }
    public func tracks(albumID: Int) -> Resource<[ArrTrack]> {
        .json(plan("fetchTracks", path: "/track", query: [("albumId", String(albumID))]), tags: [.entity(instance, .album, albumID)], freshness: .reference)
    }
    public func credits(movieID: Int) -> Resource<[ArrCredit]> {
        .json(plan("fetchCredits", path: "/credit", query: [("movieId", String(movieID))]), tags: [entityTag(movieID)], freshness: .archival)
    }
    public func alternateTitles() -> Resource<[ArrAlternateTitle]> {
        .json(plan("alternateTitleMap", path: "/alttitle"), tags: [tag(.library)], freshness: .archival)
    }

    public func qualityProfiles() -> Resource<[ArrQualityProfile]> { .json(plan("fetchQualityProfiles", path: "/qualityprofile"), tags: [tag(.profiles)], freshness: .reference) }
    public func metadataProfiles() -> Resource<[ArrMetadataProfile]> { .json(plan("search.fetchMetadataProfiles", path: "/metadataprofile"), tags: [tag(.profiles)], freshness: .reference) }
    public func rootFolders() -> Resource<[ArrRootFolder]> { .json(plan("search.fetchRootFolders", path: "/rootfolder"), tags: [tag(.profiles)], freshness: .reference) }
    public func customFormats() -> Resource<[ArrCustomFormatDetail]> { .json(plan("fetchCustomFormats", path: "/customformat"), tags: [tag(.profiles)], freshness: .reference) }
    public func downloadClients() -> Resource<[ArrDownloadClient]> { .json(plan("fetchDownloadClients", path: "/downloadclient"), tags: [tag(.profiles)], freshness: .reference) }
    public func commands() -> Resource<[ArrCommand]> { .json(plan("isSearchRunning", path: "/command"), tags: [tag(.commands)], freshness: .live) }

    public func lookupMovies(term: String) -> Resource<[ArrMovie]> {
        .json(plan("search.lookup", path: "/movie/lookup", query: [("term", term)]), tags: [tag(.lookup)], freshness: .live, harvest: { $0.flatMap(harvestMovie) })
    }
    public func lookupSeries(term: String) -> Resource<[ArrSeries]> {
        .json(plan("search.lookup", path: "/series/lookup", query: [("term", term)]), tags: [tag(.lookup)], freshness: .live, harvest: { $0.flatMap(harvestSeries) })
    }
    public func lookupArtists(term: String) -> Resource<[ArrArtist]> {
        .json(plan("search.lookup", path: "/artist/lookup", query: [("term", term)]), tags: [tag(.lookup)], freshness: .live)
    }
    public func lidarrSearch(term: String) -> Resource<[ArrSearchRecord]> {
        .json(plan("search.lookup", path: "/search", query: [("term", term)]), tags: [tag(.lookup)], freshness: .live)
    }

    /// Volatile with a 60 s TTL: indexers are queried on every miss.
    public func releases(_ target: ReleaseTarget) -> Resource<[ArrRelease]> {
        .json(plan("fetchReleases", path: "/release", query: target.query, timeout: .seconds(120)), tags: [], freshness: .volatile, ttl: .seconds(60))
    }

    // MARK: - Commands

    private func command(_ name: String, invalidates: Set<InvalidationTag>, effects: [PendingEffect] = [], tracking: Command.Tracking? = nil,
                         run: @escaping @Sendable (CommandContext) async throws -> CommandReceipt) -> Command {
        Command(name: OperationID(instance.kind, name), instance: instance, invalidates: invalidates, effects: effects, tracking: tracking, run: run)
    }

    public func deleteQueueItem(id: Int, removeFromClient: Bool, blocklist: Bool) -> Command {
        let p = plan("deleteQueueItem", method: "DELETE", path: "/queue/{id}", values: ["id": String(id)],
                     query: [("removeFromClient", String(removeFromClient)), ("blocklist", String(blocklist))])
        return command("deleteQueueItem", invalidates: [tag(.queue), tag(.history)],
                       effects: [PendingEffect(elementID: String(id), instance: instance, change: .removed)]) { ctx in
            let r = try await ctx.send(p)
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: r.body))
        }
    }

    public func grabQueueItem(id: Int) -> Command {
        let p = plan("grabQueueItem", method: "POST", path: "/queue/grab/{id}", values: ["id": String(id)], body: .bytes(Data("{}".utf8), contentType: "application/json"))
        return command("grabQueueItem", invalidates: [tag(.queue)],
                       effects: [PendingEffect(elementID: String(id), instance: instance, change: .status("downloading"))]) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    /// Turns a release's `indexerId` into a name a human recognises.
    public func indexers() -> Resource<[ArrIndexerDefinition]> {
        .json(plan("indexers", path: "/indexer"), tags: [tag(.profiles)], freshness: .reference, ttl: .seconds(3600))
    }

    public func grabRelease(guid: String, indexerID: Int) -> Command {
        let p = plan("grabRelease", method: "POST", path: "/release", body: try! RequestBuilder.json(["guid": JSONValue.string(guid), "indexerId": .number(Double(indexerID))]), timeout: .seconds(120))
        return command("grabRelease", invalidates: [tag(.queue)]) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    public enum SearchTarget: Sendable {
        case movies([Int]), series(Int), season(seriesID: Int, season: Int), episodes([Int]), albums([Int]), artist(Int)
    }

    public func search(_ target: SearchTarget) -> Command {
        var body: [String: JSONValue]
        let operation: String
        var tags: Set<InvalidationTag> = [tag(.commands)]
        switch target {
        case let .movies(ids): body = ["name": .string("MoviesSearch"), "movieIds": .array(ids.map { .number(Double($0)) })]; operation = "searchMovie"; ids.forEach { tags.insert(entityTag($0)) }
        case let .series(id): body = ["name": .string("SeriesSearch"), "seriesId": .number(Double(id))]; operation = "searchSeries"; tags.insert(entityTag(id))
        case let .season(id, n): body = ["name": .string("SeasonSearch"), "seriesId": .number(Double(id)), "seasonNumber": .number(Double(n))]; operation = "searchSeason"; tags.insert(entityTag(id))
        case let .episodes(ids): body = ["name": .string("EpisodeSearch"), "episodeIds": .array(ids.map { .number(Double($0)) })]; operation = "searchEpisodes"
        case let .albums(ids): body = ["name": .string("AlbumSearch"), "albumIds": .array(ids.map { .number(Double($0)) })]; operation = "searchAlbum"; ids.forEach { tags.insert(.entity(instance, .album, $0)) }
        case let .artist(id): body = ["name": .string("ArtistSearch"), "artistId": .number(Double(id))]; operation = "searchArtist"; tags.insert(entityTag(id))
        }
        return postCommand(operation: operation, body: body, invalidates: tags)
    }

    private func postCommand(operation: String, body: [String: JSONValue], invalidates: Set<InvalidationTag>) -> Command {
        let p = plan(operation, method: "POST", path: "/command", body: try! RequestBuilder.json(JSONValue.object(body)))
        return command(operation, invalidates: invalidates, tracking: .arrCommand(timeout: .seconds(600))) { ctx in
            let r = try await ctx.send(p)
            let json = try? await ctx.decode(JSONValue.self, from: r, operation: p.operation)
            return CommandReceipt(acceptedAt: ctx.clock.now, trackingID: json?["id"]?.intValue)
        }
    }

    /// GET → flip → PUT, echoing every unmodelled field.
    public func setMonitored(entityID: Int, _ monitored: Bool) -> Command {
        let operation = "set\(profile.entityNoun.capitalized)Monitored"
        return readModifyWrite(operation: operation, noun: profile.entityNoun, id: entityID, invalidates: [entityTag(entityID), tag(.library), tag(.calendar)]) { envelope in
            envelope.set("monitored", .bool(monitored))
        }
    }

    public func setAlbumMonitored(albumID: Int, _ monitored: Bool) -> Command {
        readModifyWrite(operation: "setAlbumMonitored", noun: "album", id: albumID, invalidates: [.entity(instance, .album, albumID), tag(.calendar)]) { $0.set("monitored", .bool(monitored)) }
    }

    public func setEpisodesMonitored(ids: [Int], _ monitored: Bool) -> Command {
        let body = try! RequestBuilder.json(["episodeIds": JSONValue.array(ids.map { .number(Double($0)) }), "monitored": .bool(monitored)])
        let p = plan("setEpisodesMonitored", method: "PUT", path: "/episode/monitor", body: body)
        return command("setEpisodesMonitored", invalidates: [tag(.calendar), tag(.library)]) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    /// Sonarr 5 has a season endpoint; Sonarr 3/4 cascade only on a transition, hence the double PUT.
    public func setSeasonMonitored(seriesID: Int, season: Int, _ monitored: Bool) -> Command {
        let service = self
        return command("setSeasonMonitored", invalidates: [entityTag(seriesID), tag(.calendar)]) { ctx in
            if ctx.capabilities.has(.servarrSeasonEndpointV5, service.instance) {
                let body = try RequestBuilder.json(["seasonNumber": JSONValue.number(Double(season)), "monitored": .bool(monitored)])
                let p = RequestPlan(instance: service.instance, operation: "setSeasonMonitored", method: "PUT", pathTemplate: "/api/v5/series/{id}/season",
                                    pathValues: ["id": String(seriesID)], body: body, auth: .header("X-Api-Key"))
                do {
                    _ = try await ctx.send(p)
                    return CommandReceipt(acceptedAt: ctx.clock.now)
                } catch let error as MediaKitError {
                    guard case let .rejected(_, status, _) = error, status == 404 || status == 405 else { throw error }
                    await ctx.demote(.servarrSeasonEndpointV5, for: service.instance)
                }
            }
            for value in [!monitored, monitored] {
                let get = service.plan("setSeasonMonitored", path: "/series/{id}", values: ["id": String(seriesID)])
                var envelope = try await ctx.decode(ArrRecordEnvelope<ArrSeries>.self, from: try await ctx.send(get), operation: get.operation)
                guard case var .array(seasons)? = envelope["seasons"] else { throw MediaKitError.decoding(get.operation, detail: "no seasons") }
                seasons = seasons.map { s in
                    guard case var .object(o) = s, o["seasonNumber"]?.intValue == season else { return s }
                    o["monitored"] = .bool(value)
                    return .object(o)
                }
                envelope.set("seasons", .array(seasons))
                let put = service.plan("setSeasonMonitored", method: "PUT", path: "/series/{id}", values: ["id": String(seriesID)], body: try RequestBuilder.json(envelope))
                _ = try await ctx.send(put)
            }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    public func add(_ payload: ArrAddPayload) -> Command {
        let operation = "search.add" + (profile.kind == .lidarr ? "Artist" : profile.entityNoun.capitalized)
        let p = plan(operation, method: "POST", path: "/" + profile.entityNoun, body: try! RequestBuilder.json(payload))
        return command(operation, invalidates: [tag(.library), tag(.calendar), tag(.lookup)]) { ctx in
            let r = try await ctx.send(p)
            let json = try? await ctx.decode(JSONValue.self, from: r, operation: p.operation)
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: r.body), trackingID: json?["id"]?.intValue)
        }
    }

    /// Lidarr: `GET /search` for the album, then POST the matching row with the add fields merged in.
    public func addAlbum(foreignAlbumID: String, term: String, payload: ArrAddPayload) -> Command {
        let search = plan("search.addAlbum", path: "/search", query: [("term", term)])
        let service = self
        return command("search.addAlbum", invalidates: [tag(.library), tag(.calendar), tag(.lookup)]) { ctx in
            let rows = try await ctx.decode([JSONValue].self, from: try await ctx.send(search), operation: search.operation)
            guard case var .object(album)? = rows.first(where: { $0["foreignId"]?.stringValue == foreignAlbumID })?["album"] else {
                throw MediaKitError.rejected(service.instance, status: 404, serverMessage: "album not found in search")
            }
            album["monitored"] = .bool(payload.monitored)
            album["addOptions"] = .object(["searchForNewAlbum": .bool(payload.addOptions?.searchForMissingAlbums ?? false)])
            var artist = album["artist"] ?? .object([:])
            if case var .object(a) = artist {
                a["qualityProfileId"] = .number(Double(payload.qualityProfileId))
                a["metadataProfileId"] = .number(Double(payload.metadataProfileId ?? 1))
                a["rootFolderPath"] = .string(payload.rootFolderPath)
                a["monitored"] = .bool(true)
                a["addOptions"] = .object(["monitor": .string(payload.addOptions?.monitor ?? "none"), "searchForMissingAlbums": .bool(false)])
                artist = .object(a)
            }
            album["artist"] = artist
            let post = service.plan("search.addAlbum", method: "POST", path: "/album", body: try RequestBuilder.json(JSONValue.object(album)))
            let r = try await ctx.send(post)
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: r.body))
        }
    }

    public func settings(entityID: Int) -> Resource<ArrRecordSettings> {
        .json(plan("fetchLibraryRecord", path: "/\(profile.entityNoun)/{id}", values: ["id": String(entityID)]), tags: [entityTag(entityID)], freshness: .volatile)
    }

    /// Writes the non-nil fields over the current record; a changed root folder moves the files along.
    public func updateSettings(entityID: Int, _ settings: ArrRecordSettings) -> Command {
        let service = self
        let noun = profile.entityNoun
        return command("updateLibraryRecord", invalidates: [entityTag(entityID), tag(.library), tag(.calendar)]) { ctx in
            let get = service.plan("fetchLibraryRecord", path: "/\(noun)/{id}", values: ["id": String(entityID)])
            var envelope = try await ctx.decode(ArrRecordEnvelope<ArrRecordSettings>.self, from: try await ctx.send(get), operation: get.operation)
            let movedPath = settings.movedPath(from: envelope.known)
            envelope.known.merge(settings)
            if let movedPath { envelope.known.path = movedPath }
            let put = service.plan("updateLibraryRecord", method: "PUT", path: "/\(noun)/{id}", values: ["id": String(entityID)],
                                   query: [("moveFiles", String(movedPath != nil))], body: try RequestBuilder.json(envelope))
            let r = try await ctx.send(put)
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: r.body))
        }
    }

    public func delete(entityID: Int, deleteFiles: Bool, addImportExclusion: Bool) -> Command {
        let p = plan("deleteLibraryRecord", method: "DELETE", path: "/\(profile.entityNoun)/{id}", values: ["id": String(entityID)],
                     query: [("deleteFiles", String(deleteFiles)), ("addImportExclusion", String(addImportExclusion)), ("addImportListExclusion", String(addImportExclusion))])
        return command("deleteLibraryRecord", invalidates: [tag(.library), entityTag(entityID), tag(.calendar)]) { ctx in
            _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    private func readModifyWrite(operation: String, noun: String, id: Int, invalidates: Set<InvalidationTag>,
                                 edit: @escaping @Sendable (inout ArrRecordEnvelope<JSONValue>) -> Void) -> Command {
        let service = self
        return command(operation, invalidates: invalidates) { ctx in
            let get = service.plan(operation, path: "/\(noun)/{id}", values: ["id": String(id)])
            var envelope = try await ctx.decode(ArrRecordEnvelope<JSONValue>.self, from: try await ctx.send(get), operation: get.operation)
            edit(&envelope)
            let put = service.plan(operation, method: "PUT", path: "/\(noun)/{id}", values: ["id": String(id)], body: try RequestBuilder.json(envelope))
            let r = try await ctx.send(put)
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: r.body))
        }
    }

    // MARK: - Artwork and identity

    private var harvestMovie: @Sendable (ArrMovie) -> [Crosswalk] {
        let instance = self.instance
        return { movie in
            guard let id = movie.id else { return [] }
            return ExternalIDParsing.servarrIDs(tmdbId: movie.tmdbId, imdbId: movie.imdbId, tvdbId: nil, foreignId: nil, kind: .movie)
                .map { Crosswalk(from: .arr(instance, id), to: $0, kind: .movie, confidence: .asserted, source: .arrRecord, fetchedAt: Date()) }
        }
    }
    private var harvestSeries: @Sendable (ArrSeries) -> [Crosswalk] {
        let instance = self.instance
        return { series in
            guard let id = series.id else { return [] }
            return ExternalIDParsing.servarrIDs(tmdbId: series.tmdbId, imdbId: series.imdbId, tvdbId: series.tvdbId, foreignId: nil, kind: .series)
                .map { Crosswalk(from: .arr(instance, id), to: $0, kind: .series, confidence: .asserted, source: .arrRecord, fetchedAt: Date()) }
        }
    }
    private var harvestArtist: @Sendable (ArrArtist) -> [Crosswalk] {
        let instance = self.instance
        return { artist in
            guard let id = artist.id else { return [] }
            return ExternalIDParsing.servarrIDs(tmdbId: nil, imdbId: nil, tvdbId: nil, foreignId: artist.foreignArtistId, kind: .artist)
                .map { Crosswalk(from: .arr(instance, id), to: $0, kind: .artist, confidence: .asserted, source: .arrRecord, fetchedAt: Date()) }
        }
    }
    private var harvestAlbum: @Sendable (ArrAlbum) -> [Crosswalk] {
        let instance = self.instance
        return { album in
            guard let id = album.id else { return [] }
            return ExternalIDParsing.servarrIDs(tmdbId: nil, imdbId: nil, tvdbId: nil, foreignId: album.foreignAlbumId, kind: .album)
                .map { Crosswalk(from: .arr(instance, id), to: $0, kind: .album, confidence: .asserted, source: .arrRecord, fetchedAt: Date()) }
        }
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash).year().month().day())
    }
}

/// What an interactive search runs for: the `/release` query of each arr.
public enum ReleaseTarget: Hashable, Sendable {
    case movie(Int), episode(Int), album(Int), season(seriesID: Int, season: Int)

    var query: [(String, String)] {
        switch self {
        case let .movie(id): [("movieId", String(id))]
        case let .episode(id): [("episodeId", String(id))]
        case let .album(id): [("albumId", String(id))]
        case let .season(seriesID, season): [("seriesId", String(seriesID)), ("seasonNumber", String(season))]
        }
    }
}
