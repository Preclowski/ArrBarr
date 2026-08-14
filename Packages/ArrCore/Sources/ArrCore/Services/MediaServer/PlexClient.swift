import Foundation

/// Plex Media Server client.
///
/// Plex answers XML by default and JSON only when asked — `Accept:
/// application/json` is set for every request by
/// `MediaServerKind.authHeaders`, so everything below decodes the JSON
/// projection of the same `MediaContainer` documents the web UI uses.
///
/// The token is the one the user copies out of a "View XML" URL
/// (`X-Plex-Token`), which is how the rest of the arr ecosystem asks for it.
struct PlexClient: MediaServerClient {
    let config: MediaServerConfig
    let http: HTTPClient

    init(config: MediaServerConfig, http: HTTPClient = HTTPClient()) {
        self.config = config
        self.http = http
    }

    private var headers: [String: String] { config.kind.authHeaders(token: config.token) }

    // MARK: - Wire shapes

    private struct Container<T: Decodable>: Decodable {
        let MediaContainer: T
    }

    private struct Identity: Decodable {
        let version: String?
        let friendlyName: String?
    }

    private struct Sections: Decodable {
        let Directory: [Section]?
    }

    private struct Section: Decodable {
        let key: String
        /// "movie", "show", "artist", "photo".
        let type: String?
        let title: String?
    }

    private struct Items: Decodable {
        let Metadata: [Item]?
    }

    private struct Guid: Decodable {
        let id: String?
    }

    private struct Item: Decodable {
        let ratingKey: String?
        let type: String?
        let title: String?
        let grandparentTitle: String?
        let year: Int?
        let thumb: String?
        let viewCount: Int?
        let lastViewedAt: Int?
        let viewedAt: Int?
        /// Episode counts on a series — Plex reports no `viewCount` for shows,
        /// so "watched" means every leaf is watched.
        let leafCount: Int?
        let viewedLeafCount: Int?
        let guid: String?
        let Guid: [Guid]?
        let viewOffset: Int?
        let duration: Int?
        let User: SessionUser?
        let Player: SessionPlayer?
        let TranscodeSession: TranscodeSession?
    }

    private struct SessionUser: Decodable { let title: String? }
    private struct SessionPlayer: Decodable { let title: String?; let product: String? }
    private struct TranscodeSession: Decodable { let videoDecision: String?; let audioDecision: String? }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                   as type: T.Type) async throws -> T {
        let url = try http.url(base: normalizedBaseURL, path: path, query: query)
        let data = try await http.get(url, headers: headers)
        do {
            return try JSONDecoder().decode(Container<T>.self, from: data).MediaContainer
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    // MARK: - MediaServerClient

    func testConnection() async throws -> MediaServerHandshake {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let identity = try await get("/identity", as: Identity.self)
        let version = identity.version.map { "Plex \($0)" } ?? "Plex"
        // Plex scopes play state to the token's own account, so there is no
        // user id to resolve or store.
        return MediaServerHandshake(versionLine: version, userId: nil)
    }

    func libraryIndex() async throws -> [MediaServerEntry] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let sections = try await get("/library/sections", as: Sections.self)
        let wanted = (sections.Directory ?? []).filter {
            $0.type == "movie" || $0.type == "show"
        }
        var entries: [MediaServerEntry] = []
        for section in wanted {
            // Sections are fetched in sequence rather than fanned out: a large
            // Plex library answers `/all` slowly and in full, and three of those
            // in parallel is how you make the server swap. The index refresh is
            // a background job — latency here costs nobody anything.
            let items = try await get(
                "/library/sections/\(section.key)/all",
                query: [URLQueryItem(name: "includeGuids", value: "1")],
                as: Items.self
            )
            entries.append(contentsOf: (items.Metadata ?? []).compactMap(entry(from:)))
        }
        return entries
    }

    func scanLibraries() async throws {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let sections = try await get("/library/sections", as: Sections.self)
        for section in sections.Directory ?? [] {
            let url = try http.url(base: normalizedBaseURL, path: "/library/sections/\(section.key)/refresh")
            _ = try await http.get(url, headers: headers)
        }
    }

    func emptyTrash() async throws {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let sections = try await get("/library/sections", as: Sections.self)
        for section in sections.Directory ?? [] {
            let url = try http.url(base: normalizedBaseURL, path: "/library/sections/\(section.key)/emptyTrash")
            _ = try await http.put(url, headers: headers, body: Data())
        }
    }

    func nowPlaying() async throws -> [MediaServerSession] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let items = try await get("/status/sessions", as: Items.self)
        return (items.Metadata ?? []).map { item in
            let progress: Double? = {
                guard let offset = item.viewOffset, let duration = item.duration, duration > 0 else { return nil }
                return min(1, max(0, Double(offset) / Double(duration)))
            }()
            return MediaServerSession(
                title: item.grandparentTitle ?? item.title ?? "",
                subtitle: item.grandparentTitle == nil ? nil : item.title,
                user: item.User?.title,
                device: item.Player?.title ?? item.Player?.product,
                // A session is transcoding when Plex opened a transcode for
                // either stream; "copy" means it is only remuxing.
                isTranscoding: {
                    guard let t = item.TranscodeSession else { return false }
                    return t.videoDecision == "transcode" || t.audioDecision == "transcode"
                }(),
                progress: progress
            )
        }
    }

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let items = try await get(
            "/status/sessions/history/all",
            query: [
                URLQueryItem(name: "sort", value: "viewedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
            ],
            as: Items.self
        )
        return (items.Metadata ?? []).compactMap { item in
            // History rows for episodes name the episode in `title` and the
            // series in `grandparentTitle`; the series is what a taste signal
            // wants, so prefer it when present.
            let title = item.grandparentTitle ?? item.title
            guard let title, !title.isEmpty else { return nil }
            return MediaServerWatch(
                title: title,
                year: item.year,
                kind: item.type == "movie" ? .movie : .show,
                watchedAt: item.viewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    // MARK: - Mapping

    private func entry(from item: Item) -> MediaServerEntry? {
        guard let ratingKey = item.ratingKey, let title = item.title else { return nil }
        let kind: MediaServerItemKind = item.type == "show" ? .show : .movie

        var keys: [MediaServerExternalKey] = []
        for guid in item.Guid ?? [] {
            if let id = guid.id, let key = MediaServerGuidParser.key(from: id) { keys.append(key) }
        }
        // Fall back to the single legacy `guid` when `includeGuids` produced
        // nothing — old agent-based libraries never got the `Guid` array.
        if keys.isEmpty, let legacy = item.guid, let key = MediaServerGuidParser.key(from: legacy) {
            keys.append(key)
        }
        guard !keys.isEmpty else { return nil }

        let poster: URL? = item.thumb.flatMap { thumb in
            try? http.url(base: normalizedBaseURL, path: thumb)
        }.map { tokenized($0) }

        let watched: Bool = {
            if kind == .show {
                guard let leaves = item.leafCount, leaves > 0 else { return false }
                return (item.viewedLeafCount ?? 0) >= leaves
            }
            return (item.viewCount ?? 0) > 0
        }()

        return MediaServerEntry(
            itemId: ratingKey,
            kind: kind,
            title: title,
            year: item.year,
            posterURL: poster,
            externalKeys: keys,
            watched: watched,
            playCount: item.viewCount ?? 0,
            lastPlayed: item.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
