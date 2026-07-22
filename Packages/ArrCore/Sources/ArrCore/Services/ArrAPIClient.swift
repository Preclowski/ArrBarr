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

    /// All custom formats defined on this arr (`/customformat`). Shared by
    /// Sonarr + Radarr (both v3); powers the chat `list_custom_formats` /
    /// `describe_format` tools.
    func fetchCustomFormats() async throws -> [ArrCustomFormatDetail] {
        try await get("/customformat")
    }

    /// All quality profiles (`/qualityprofile`). Decoded down to the
    /// per-format score table so `describe_format` can report where a
    /// custom format earns or loses points.
    func fetchQualityProfiles() async throws -> [ArrQualityProfile] {
        try await get("/qualityprofile")
    }

    /// Interactive / manual search: candidate releases on the indexers for a
    /// movie / episode / album. `query` carries the keying param (movieId /
    /// episodeId / albumId). Shared by every arr (Sonarr/Radarr/Lidarr/Whisparr).
    func fetchReleases(query: [URLQueryItem]) async throws -> [Release] {
        try await get("/release", query: query)
    }

    /// Grab a release returned by `fetchReleases` — hands it to the arr's
    /// download client. arr identifies the release by guid + indexerId.
    func grabRelease(guid: String, indexerId: Int) async throws {
        _ = try await post("/release", body: ["guid": guid, "indexerId": indexerId])
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
