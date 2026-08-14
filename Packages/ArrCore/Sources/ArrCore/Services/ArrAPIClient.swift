import Foundation
import os

/// Minimal `/system/status` shape — just enough for `testConnection()`.
private struct ArrSystemStatus: Decodable { let version: String? }

/// Shares QueueAggregator's category so one predicate covers the whole
/// queue-refresh path in Console / `log show`.
private let arrLog = Logger(category: "QueueFetch")

/// Common HTTP+auth boilerplate shared by every *arr* REST client
/// (Sonarr/Radarr/Lidarr/Whisparr/...). Each conforming type supplies
/// its `config` and `apiBase` ("/api/v3" for Sonarr/Radarr, "/api/v1"
/// for Lidarr); the default GET/POST/DELETE helpers handle URL
/// construction, X-Api-Key header injection, and JSON decoding.
public protocol ArrAPIClient: Sendable {
    var config: ServiceConfig { get }
    /// API root path, e.g. "/api/v3" or "/api/v1".
    var apiBase: String { get }
    var http: HTTPClient { get }
    /// Product name ("Sonarr", "Radarr", …) shown in connection-test results.
    var serviceName: String { get }
}

extension ArrAPIClient {
    /// Standard auth header for every request to an arr.
    var apiHeaders: [String: String] {
        ["X-Api-Key": config.apiKey]
    }

    /// `pageSize` every client asks `/queue` for. Servarr paginates the queue
    /// and offers no "give me everything" sentinel, so this has to be a
    /// number; 1000 covers any sane install. `warnIfQueueTruncated` makes the
    /// pathological case audible instead of silently dropping rows.
    static var queuePageSize: Int { 1000 }

    /// Cap on how many per-entity side-load GETs (episode files, track files)
    /// a single queue refresh keeps in flight.
    ///
    /// `URLSession.shared` allows 6 connections per host and the poster loader
    /// competes for the same pool, so an uncapped task group over a 40-series
    /// queue doesn't fan out — it stacks 34 requests behind the first 6, long
    /// enough for the tail to hit `HTTPClient.requestTimeout`. Those failures
    /// are swallowed by `try?`, and the upgrade-diff quietly disappears from
    /// the rows. Four saturates the pool while leaving lanes for posters.
    static var maxConcurrentSideLoads: Int { 4 }

    /// Resolve display metadata for a set of entity ids: cache first, then one
    /// bounded fan-out for the misses, then write the results back.
    ///
    /// Three clients had a line-for-line copy of this, differing only in their
    /// source, entity kind and per-id fetch. The shape is the interesting part
    /// and it is identical everywhere — miss-only fetching, a bounded group so a
    /// first-run queue can't saturate the six-connections-per-host pool (see
    /// `maxConcurrentSideLoads`), and a single batched store write.
    ///
    /// `fetch` returns nil for an id it couldn't resolve; that id is simply
    /// absent from the result and the row falls back to its release name rather
    /// than the whole refresh failing.
    func resolveMetadata(
        ids: [Int],
        source: QueueItem.Source,
        kind: TitleMetadataStore.Kind,
        fetch: @Sendable @escaping (Int) async -> TitleMetadataStore.Metadata?
    ) async -> [Int: TitleMetadataStore.Metadata] {
        guard !ids.isEmpty else { return [:] }
        let baseURL = config.baseURL
        func key(_ id: Int) -> TitleMetadataStore.Key {
            TitleMetadataStore.Key(source: source, baseURL: baseURL, kind: kind, id: id)
        }

        var byId: [Int: TitleMetadataStore.Metadata] = [:]
        for (cached, value) in await TitleMetadataStore.shared.metadata(for: ids.map(key)) {
            byId[cached.id] = value
        }
        // Deliberately after the cache read, and applied again to the fresh
        // records below: which artwork wins is a property of the CURRENT media
        // server connection, not of whenever the entry happened to be cached.
        // Baking it in on write is what left queue rows on the arr's poster
        // while detail views — which resolve live — showed the server's.
        let missing = ids.filter { byId[$0] == nil }
        guard !missing.isEmpty else { return byId }

        var fresh: [TitleMetadataStore.Key: TitleMetadataStore.Metadata] = [:]
        await withTaskGroup(of: (Int, TitleMetadataStore.Metadata)?.self) { group in
            var next = 0
            func schedule() {
                guard next < missing.count else { return }
                let id = missing[next]
                next += 1
                group.addTask { await fetch(id).map { (id, $0) } }
            }
            for _ in 0 ..< min(Self.maxConcurrentSideLoads, missing.count) { schedule() }
            while let done = await group.next() {
                if let (id, metadata) = done {
                    byId[id] = metadata
                    fresh[key(id)] = metadata
                }
                schedule()
            }
        }
        if !fresh.isEmpty { await TitleMetadataStore.shared.store(fresh) }
        // The store keeps the arr's artwork; the media server's is layered on
        // here, over cached and freshly-fetched records alike.
        return byId.mapValues { $0.applyingMediaServerArtwork() }
    }

    /// Shout when the arr says its queue holds more rows than the single page
    /// we asked for returned. We deliberately don't page — a >1000-item queue
    /// is pathological — but the rows past the cut are invisible in the UI,
    /// which reads to the user as "my download vanished".
    func warnIfQueueTruncated(returned: Int, totalRecords: Int) {
        guard totalRecords > returned else { return }
        arrLog.notice(
            "\(serviceName, privacy: .public) queue truncated: showing \(returned, privacy: .public) of \(totalRecords, privacy: .public) records (pageSize=\(Self.queuePageSize, privacy: .public))"
        )
    }

    /// GET <apiBase><path> and decode the JSON body as T.
    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        let data = try await http.get(url, headers: apiHeaders)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Same as `get` but tolerates decode failures with a fallback (used by
    /// some library-listing paths that today silently return [] on decode
    /// errors to keep the UI happy). New code should prefer plain `get`.
    func getOrDefault<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], default fallback: T) async throws -> T {
        guard config.isConfigured else { return fallback }
        // Same key check every sibling makes — without it a key-less config
        // spends a round-trip to collect a 401 and then degrades to `fallback`
        // anyway, so short-circuit it here.
        guard !config.apiKey.isEmpty else { return fallback }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    /// POST a JSON body to <apiBase><path>. Returns the raw response data.
    @discardableResult
    func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)")
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await http.post(
            url,
            headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 },
            body: data
        )
    }

    /// PUT a JSON body to <apiBase><path>. Returns the raw response data.
    @discardableResult
    func put(_ path: String, query: [URLQueryItem] = [], body: [String: Any]) async throws -> Data {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await http.put(
            url,
            headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 },
            body: data
        )
    }

    /// GET <apiBase><path> as an untyped JSON object — for read-modify-write
    /// round-trips (e.g. flipping one season flag inside `/series/{id}`)
    /// where decoding into our lean structs would drop fields the PUT must
    /// carry back.
    func getRawObject(_ path: String) async throws -> [String: Any] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)")
        let data = try await http.get(url, headers: apiHeaders)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.decoding(NSError(domain: "ArrAPIClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected a JSON object at \(path)"
            ]))
        }
        return obj
    }

    /// Flip a movie's monitored flag (Radarr and its Whisparr fork share the
    /// `/movie/{id}` shape). Full-record round-trip: PUT wants the whole
    /// object back, so mutate the raw JSON rather than a strip-decoded struct.
    func setMovieMonitored(movieId: Int, monitored: Bool) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await DemoMonitorState.setMovie(movieId, monitored: monitored)
            return
        }
        var movie = try await getRawObject("/movie/\(movieId)")
        movie["monitored"] = monitored
        try await put("/movie/\(movieId)", body: movie)
    }

    /// Edit a library record (`/movie/{id}`, `/series/{id}`, `/artist/{id}`).
    /// Full-record round-trip like `setMovieMonitored`: the arrs' PUT wants the
    /// whole object back, so fetch raw JSON, overlay `fields`, PUT it back.
    ///
    /// A `rootFolderPath` change also rewrites `path` (new root + the record's
    /// existing folder name) and is sent with `moveFiles=true` so the arr
    /// relocates the files on disk — mirrors what the arrs' own edit UI does.
    func updateLibraryRecord(path recordPath: String, fields: [String: Any]) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        var record = try await getRawObject(recordPath)
        var moveFiles = false
        if let newRoot = (fields["rootFolderPath"] as? String),
           let oldRoot = record["rootFolderPath"] as? String,
           newRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) !=
               oldRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           let oldPath = record["path"] as? String,
           let folderName = oldPath.split(separator: "/").last.map(String.init) {
            let base = newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot
            record["path"] = "\(base)/\(folderName)"
            moveFiles = true
        }
        for (key, value) in fields { record[key] = value }
        try await put(recordPath,
                      query: [URLQueryItem(name: "moveFiles", value: moveFiles ? "true" : "false")],
                      body: record)
    }

    /// All custom formats defined on this arr (`/customformat`). Shared by
    /// Sonarr + Radarr (both v3); powers the chat `list_custom_formats` /
    /// `describe_format` tools.
    func fetchCustomFormats() async throws -> [ArrCustomFormatDetail] {
        if DemoMode.isActive { return DemoMocks.customFormats() }
        return try await get("/customformat")
    }

    /// All quality profiles (`/qualityprofile`). Decoded down to the
    /// per-format score table so `describe_format` can report where a
    /// custom format earns or loses points.
    func fetchQualityProfiles() async throws -> [ArrQualityProfile] {
        if DemoMode.isActive { return DemoMocks.qualityProfiles() }
        return try await get("/qualityprofile")
    }

    /// Interactive / manual search: candidate releases on the indexers for a
    /// movie / episode / album. `query` carries the keying param (movieId /
    /// episodeId / albumId). Shared by every arr (Sonarr/Radarr/Lidarr/Whisparr).
    func fetchReleases(query: [URLQueryItem]) async throws -> [Release] {
        if DemoMode.isActive {
            // Indexer searches are slow in production and the list's loading
            // state is part of what's being demoed, so don't return instantly.
            try? await Task.sleep(nanoseconds: 900_000_000)
            return DemoMocks.releases(query: query, source: demoSource)
        }
        return try await get("/release", query: query)
    }

    /// Grab a release returned by `fetchReleases` — hands it to the arr's
    /// download client. arr identifies the release by guid + indexerId.
    func grabRelease(guid: String, indexerId: Int) async throws {
        if DemoMode.isActive { try? await Task.sleep(nanoseconds: 500_000_000); return }
        _ = try await post("/release", body: ["guid": guid, "indexerId": indexerId])
    }

    /// Which arr this client is, for fixture lookup. `serviceName` is the only
    /// identity the protocol carries and it matches `Source`'s raw values
    /// one-for-one once lowercased.
    private var demoSource: QueueItem.Source {
        QueueItem.Source(rawValue: serviceName.lowercased()) ?? .radarr
    }

    /// DELETE <apiBase><path>?key=val&...
    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        // Matches `post`/`deleteQueueItem`: a missing key is a configuration
        // problem, and saying so beats surfacing the arr's bare 401.
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        _ = try await http.delete(url, headers: apiHeaders)
    }

    /// GET /system/status and report "<serviceName> <version>". Auth-gated,
    /// so a wrong API key fails here. Powers the Settings "Test" button.
    func testConnection() async throws -> String {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return DemoMocks.systemStatus(serviceName: serviceName)
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/system/status")
        let data = try await http.get(url, headers: apiHeaders)
        let status = try? JSONDecoder().decode(ArrSystemStatus.self, from: data)
        return status?.version.map { "\(serviceName) \($0)" } ?? "OK"
    }

    /// DELETE /queue/{id} — remove a queue item, optionally deleting the
    /// download from the client and/or blocklisting the release.
    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/queue/\(id)",
            query: [
                URLQueryItem(name: "removeFromClient", value: removeFromClient ? "true" : "false"),
                URLQueryItem(name: "blocklist", value: blocklist ? "true" : "false"),
            ]
        )
        _ = try await http.delete(url, headers: apiHeaders)
    }

    /// Force-grab a pending/delayed queue item now (the arr is holding it
    /// before sending to the download client). `POST /queue/grab/{id}` — no
    /// download-client involvement, so it works for items not yet in the client.
    func grabQueueItem(id: Int) async throws {
        if DemoMode.isActive { try? await Task.sleep(nanoseconds: 400_000_000); return }
        try await post("/queue/grab/\(id)", body: [:])
    }

    /// GET /health — current server health records. Decode failures degrade
    /// to [] so a quirky arr never breaks the health UI.
    func fetchHealth() async throws -> [ArrHealthRecord] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/health")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([ArrHealthRecord].self, from: data)) ?? []
    }

    /// GET /diskspace — every filesystem the server can see, with free/total
    /// bytes. Shared by all arrs (v1 and v3). Decode failures degrade to [] so a
    /// quirky server never breaks the status page.
    func fetchDiskSpace() async throws -> [DiskSpace] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/diskspace")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([DiskSpace].self, from: data)) ?? []
    }

    /// POST /command — fire an arr command (indexer searches, refreshes, …).
    /// In demo mode no real work happens; a short sleep lets the UI's
    /// spinner-fade play.
    func postCommand(_ body: [String: Any]) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return
        }
        try await post("/command", body: body)
    }

    /// True while the server has a queued or running indexer search touching
    /// this record. Asking the server is the only honest answer: `postCommand`
    /// discards the command id, and a search started by
    /// `addOptions.searchForMovie` never had a client-visible id to begin with.
    ///
    /// Never throws — a search indicator is not worth surfacing an error over,
    /// and "can't tell" degrades to "not searching", which unblocks the UI
    /// rather than wedging it.
    func isSearchRunning(entityId: Int) async -> Bool {
        if DemoMode.isActive { return false }
        let commands: [ArrCommand] = (try? await getOrDefault("/command", default: [])) ?? []
        return commands.contains { $0.isSearch(for: entityId) }
    }
}
