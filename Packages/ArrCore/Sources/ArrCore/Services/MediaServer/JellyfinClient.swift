import Foundation

/// Jellyfin **and** Emby.
///
/// Jellyfin is a fork of Emby and the endpoints ArrBarr touches never
/// diverged: `/System/Info`, `/Users`, `/Users/{id}/Items`, `/Sessions` and
/// `/Library/Refresh` behave the same on both. The only real difference is the
/// auth header, and that already lives on `MediaServerKind`, so one type serves
/// both rather than a subclass that would differ by nothing.
struct JellyfinClient: MediaServerClient {
    let config: MediaServerConfig
    let http: HTTPClient

    init(config: MediaServerConfig, http: HTTPClient = HTTPClient()) {
        self.config = config
        self.http = http
    }

    private var headers: [String: String] { config.kind.authHeaders(token: config.token) }

    // MARK: - Wire shapes

    private struct SystemInfo: Decodable {
        let Version: String?
    }

    private struct User: Decodable {
        let Id: String?
        let Policy: Policy?
        struct Policy: Decodable {
            let IsAdministrator: Bool?
            let IsDisabled: Bool?
        }
    }

    private struct ItemsPage: Decodable {
        let Items: [Item]?
    }

    private struct Item: Decodable {
        let Id: String?
        let Name: String?
        let SeriesName: String?
        /// The wire key is `Type`, which Swift reserves — hence the rename.
        let itemType: String?
        let ProductionYear: Int?
        let ProviderIds: [String: String]?
        let ImageTags: [String: String]?
        let UserData: UserData?

        enum CodingKeys: String, CodingKey {
            case Id, Name, SeriesName, ProductionYear, ProviderIds, ImageTags, UserData
            case itemType = "Type"
        }

        struct UserData: Decodable {
            let Played: Bool?
            let PlayCount: Int?
            let LastPlayedDate: String?
        }
    }

    private struct Session: Decodable {
        let UserName: String?
        let DeviceName: String?
        let Client: String?
        let NowPlayingItem: Item?
        let TranscodingInfo: TranscodingInfo?

        struct TranscodingInfo: Decodable {
            let IsVideoDirect: Bool?
            let IsAudioDirect: Bool?
        }
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                   as type: T.Type) async throws -> T {
        let url = try http.url(base: normalizedBaseURL, path: path, query: query)
        let data = try await http.get(url, headers: headers)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    // MARK: - MediaServerClient

    func testConnection() async throws -> MediaServerHandshake {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let info = try await get("/System/Info", as: SystemInfo.self)
        let name = config.kind.displayName
        let version = info.Version.map { "\(name) \($0)" } ?? name
        return MediaServerHandshake(versionLine: version, userId: try await resolveUserId())
    }

    /// Which user's play state to read.
    ///
    /// An API key on Jellyfin / Emby is not tied to an account, so the server
    /// cannot answer "who am I". Prefer the first enabled administrator (the
    /// account whoever pastes a dashboard API key is nearly always using),
    /// falling back to the first enabled user at all. Stored in the config so
    /// the choice is stable and the user never types a GUID.
    private func resolveUserId() async throws -> String? {
        let users = try await get("/Users", as: [User].self)
        let enabled = users.filter { $0.Policy?.IsDisabled != true }
        let admin = enabled.first { $0.Policy?.IsAdministrator == true }
        return (admin ?? enabled.first)?.Id
    }

    /// The user id to query with — the stored one, or a freshly resolved one
    /// when the config predates the connection test.
    private func currentUserId() async throws -> String {
        if !config.userId.isEmpty { return config.userId }
        guard let resolved = try await resolveUserId() else {
            throw MediaServerError.noUserResolved
        }
        return resolved
    }

    func libraryIndex() async throws -> [MediaServerEntry] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let userId = try await currentUserId()
        let page = try await get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                // ProviderIds is the join key; UserData is the watch state.
                // Nothing else is asked for — the default projection on a large
                // library is megabytes of media-stream detail we'd throw away.
                URLQueryItem(name: "Fields", value: "ProviderIds"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            ],
            as: ItemsPage.self
        )
        return (page.Items ?? []).compactMap(entry(from:))
    }

    func scanLibraries() async throws {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let url = try http.url(base: normalizedBaseURL, path: "/Library/Refresh")
        _ = try await http.post(url, headers: headers, body: Data())
    }

    func emptyTrash() async throws {
        // Neither server has a trash to empty — items vanish from the library
        // when their files do, at the next scan. Surfaced as an explicit
        // "unsupported" so Settings can hide the button instead of offering one
        // that always fails.
        throw MediaServerError.unsupported(
            action: String(localized: "emptying the trash", bundle: .module),
            server: config.kind.displayName
        )
    }

    func nowPlaying() async throws -> [MediaServerSession] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let sessions = try await get("/Sessions", as: [Session].self)
        return sessions.compactMap { session in
            guard let item = session.NowPlayingItem, let name = item.Name else { return nil }
            let isEpisode = item.itemType == "Episode"
            return MediaServerSession(
                title: isEpisode ? (item.SeriesName ?? name) : name,
                subtitle: isEpisode ? name : nil,
                user: session.UserName,
                device: session.DeviceName ?? session.Client,
                // TranscodingInfo is present only while transcoding; a stream
                // that is direct in both tracks is a remux, not a transcode.
                isTranscoding: {
                    guard let t = session.TranscodingInfo else { return false }
                    return t.IsVideoDirect != true || t.IsAudioDirect != true
                }(),
                // Position is reported in ticks, but the runtime isn't part of
                // the projection we request, so there is no denominator to make
                // a fraction from. Reported as unknown rather than guessed.
                progress: nil
            )
        }
    }

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch] {
        guard config.isConfigured else { throw MediaServerError.notConfigured }
        let userId = try await currentUserId()
        let page = try await get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
                URLQueryItem(name: "Filters", value: "IsPlayed"),
                URLQueryItem(name: "SortBy", value: "DatePlayed"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableImages", value: "false"),
            ],
            as: ItemsPage.self
        )
        return (page.Items ?? []).compactMap { item in
            let isEpisode = item.itemType == "Episode"
            // Episodes stand in for their series: "watched Severance" is the
            // useful taste signal, "watched S02E04" is noise.
            guard let title = isEpisode ? item.SeriesName : item.Name, !title.isEmpty else { return nil }
            return MediaServerWatch(
                title: title,
                year: item.ProductionYear,
                kind: isEpisode ? .show : .movie,
                watchedAt: item.UserData?.LastPlayedDate.flatMap(Self.parseDate)
            )
        }
    }

    // MARK: - Mapping

    /// Jellyfin serialises dates as ISO-8601 with fractional seconds; Emby
    /// sometimes omits them. Both parsers are tried rather than assuming.
    static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func entry(from item: Item) -> MediaServerEntry? {
        guard let id = item.Id, let name = item.Name else { return nil }
        let keys = MediaServerGuidParser.keys(fromProviderIds: item.ProviderIds ?? [:])
        guard !keys.isEmpty else { return nil }

        let poster: URL? = {
            guard let tag = item.ImageTags?["Primary"] else { return nil }
            guard let url = try? http.url(
                base: normalizedBaseURL,
                path: "/Items/\(id)/Images/Primary",
                query: [URLQueryItem(name: "tag", value: tag)]
            ) else { return nil }
            return tokenized(url)
        }()

        return MediaServerEntry(
            itemId: id,
            kind: item.itemType == "Series" ? .show : .movie,
            title: name,
            year: item.ProductionYear,
            posterURL: poster,
            externalKeys: keys,
            watched: item.UserData?.Played ?? false,
            playCount: item.UserData?.PlayCount ?? 0,
            lastPlayed: item.UserData?.LastPlayedDate.flatMap(Self.parseDate)
        )
    }
}
