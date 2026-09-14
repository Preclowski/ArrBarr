import Foundation

/// One title as the user's media server knows it.
public struct MediaServerTitle: Sendable, Hashable {
    public let itemID: String
    public let title: String
    public let year: Int?
    public let ids: Set<MediaID>
    public let artwork: Artwork
    public let watched: Bool
    /// 0…1 when the server reports a resume point.
    public let playProgress: Double?

    public var tmdbID: Int? {
        for id in ids {
            switch id {
            case .tmdbMovie(let value), .tmdbSeries(let value): return value
            default: continue
            }
        }
        return nil
    }
}

/// Plex / Jellyfin / Emby as a field provider.
///
/// It answers `.artwork` and `.availability` for titles the user actually
/// has, and it is the only source in the app for two of the three pictures:
/// the arrs and TMDB have posters, but the **backdrop** the user chose and
/// the **clear logo** the server scraped exist nowhere else. That logo is
/// what turns a hero from "image with a title typed over it" into the Apple
/// TV look.
///
/// It works from one library sweep rather than a lookup per title: a grid of
/// a hundred posters must not be a hundred requests to the LAN box, and the
/// server hands over its whole index in one call anyway.
public actor MediaServerProvider: MediaProvider {
    public nonisolated let id: ProviderID
    public nonisolated let supplies: MediaFieldSet = [.artwork, .availability]
    /// The user's own hardware: nothing is cheaper except the cache.
    public nonisolated let cost = ProviderCost.local

    private let flavor: MediaServerFlavor
    private let baseURL: URL?
    private let token: String?
    private let userID: String?
    private let transport: HTTPTransport
    private let telemetry: MediaTelemetry?

    private var index: [Int: MediaServerTitle] = [:]
    private var indexedAt: Date?
    private var indexing: Task<Void, Never>?
    /// How long a library sweep stands before it is worth doing again.
    /// Artwork changes when the user edits it in Plex — rare, and never
    /// urgent.
    private let indexTTL: TimeInterval = 60 * 30

    public init(flavor: MediaServerFlavor,
                baseURL: URL?,
                token: String?,
                userID: String? = nil,
                transport: HTTPTransport = URLSessionTransport(),
                telemetry: MediaTelemetry? = nil) {
        self.id = ProviderID(flavor.rawValue)
        self.flavor = flavor
        self.baseURL = baseURL
        self.token = token
        self.userID = userID
        self.transport = transport
        self.telemetry = telemetry
    }

    public nonisolated var isConfigured: Bool {
        baseURL != nil && !(token ?? "").isEmpty
    }

    public nonisolated func canAnswer(_ identity: MediaIdentity) -> Bool {
        identity.tmdbID != nil
    }

    /// One sweep answers the whole library, so a page costs nothing extra.
    public nonisolated var answersFromIndex: Bool { true }

    /// Availability is this provider's outright — it is the only thing that
    /// knows what was *watched*. Its artwork outranks TMDB's, but only ever
    /// for titles it holds; for everything else it answers nothing at all.
    public nonisolated func precedence(for field: MediaField) -> Int {
        switch field {
        case .availability: 120
        case .artwork: 110
        default: 0
        }
    }

    public func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        var fragment = MediaFragment(identity: identity)
        let wanted = answerable(fields)
        guard !wanted.isEmpty, let tmdbID = identity.tmdbID else { return fragment }
        try await refreshIndexIfNeeded()
        guard let title = index[tmdbID] else {
            // Not in the library. `availability` still gets an answer — "no"
            // from the source that would know is worth recording; artwork
            // does not, so TMDB's wins by default.
            if wanted.contains(.availability) {
                fragment.availability = Availability(owned: false, watched: false)
            }
            return fragment
        }

        var identity = identity
        for id in title.ids { identity.insert(id) }
        identity.insert(.server(flavor, title.itemID))
        fragment = MediaFragment(identity: identity)

        if wanted.contains(.artwork) { fragment.artwork = title.artwork }
        if wanted.contains(.availability) {
            fragment.availability = Availability(owned: true,
                                                 watched: title.watched,
                                                 playProgress: title.playProgress,
                                                 sources: [flavor.displayName])
        }
        return fragment
    }

    // MARK: - The library sweep

    /// Everything the server holds, keyed by TMDB id. Public because the app
    /// keeps its own index for the poster grid, which cannot await a provider
    /// per card.
    public func titles() async throws -> [Int: MediaServerTitle] {
        try await refreshIndexIfNeeded()
        return index
    }

    public func invalidateIndex() {
        indexedAt = nil
    }

    private func refreshIndexIfNeeded() async throws {
        if let indexedAt, Date().timeIntervalSince(indexedAt) < indexTTL, !index.isEmpty { return }
        // One sweep at a time, however many callers arrive together.
        if let indexing {
            await indexing.value
            return
        }
        let task = Task { await sweep() }
        indexing = task
        await task.value
        indexing = nil
    }

    private func sweep() async {
        guard isConfigured else { return }
        await telemetry?.record(.init(kind: .request, provider: id, identity: "library",
                                      fields: [.artwork, .availability], note: "library sweep"))
        do {
            let titles = switch flavor {
            case .plex: try await plexTitles()
            case .jellyfin, .emby: try await jellyfinTitles()
            }
            var built: [Int: MediaServerTitle] = [:]
            for title in titles {
                guard let tmdbID = title.tmdbID else { continue }
                built[tmdbID] = title
            }
            index = built
            indexedAt = Date()
            await telemetry?.record(.init(kind: .response, provider: id,
                                          identity: "library", fields: [.artwork, .availability],
                                          note: "\(built.count) titles"))
        } catch {
            await telemetry?.record(.init(kind: .failure, provider: id,
                                          identity: "library", fields: [.artwork, .availability],
                                          note: "\(error)"))
        }
    }

    private func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard let baseURL else { return nil }
        var components = URLComponents(url: baseURL.appending(path: path),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The token never rides in the URL: these responses carry artwork
        // paths that get cached and persisted, and a rotated token in a
        // query string would poison every one of them.
        switch flavor {
        case .plex:
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        case .jellyfin, .emby:
            request.setValue("MediaBrowser Token=\"\(token ?? "")\"",
                             forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let started = Date()
        let response = try await transport.send(request)
        await telemetry?.record(.init(kind: response.isSuccess ? .response : .failure,
                                      provider: id, identity: "library",
                                      fields: [.artwork, .availability],
                                      duration: Date().timeIntervalSince(started),
                                      bytes: response.data.count,
                                      note: "HTTP \(response.status)"))
        guard response.isSuccess else {
            throw response.status == 401 ? MediaError.unauthorized(id) : MediaError.unreachable(id)
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw MediaError.decoding(id, "\(error)")
        }
    }

    /// Absolute URL for a server-relative artwork path. Token-free on purpose
    /// — the fetcher adds the header.
    private func artworkURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty, let baseURL else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: baseURL.absoluteString.trimmingSuffix("/") + path)
    }

    // MARK: - Plex

    private func plexTitles() async throws -> [MediaServerTitle] {
        guard let sectionsRequest = request(path: "/library/sections") else {
            throw MediaError.notConfigured(id)
        }
        let sections = try await send(sectionsRequest, as: PlexSections.self)
        var titles: [MediaServerTitle] = []
        for section in sections.mediaContainer?.directory ?? []
        where section.type == "movie" || section.type == "show" {
            guard let key = section.key,
                  let request = request(path: "/library/sections/\(key)/all",
                                        query: [URLQueryItem(name: "includeGuids", value: "1")])
            else { continue }
            let page = try await send(request, as: PlexItems.self)
            for item in page.mediaContainer?.metadata ?? [] {
                guard let ratingKey = item.ratingKey else { continue }
                var ids = Set<MediaID>()
                for guid in item.guid ?? [] {
                    if let id = Self.plexGuid(guid.id, isShow: section.type == "show") {
                        ids.insert(id)
                    }
                }
                // Older servers put a single guid on the item itself.
                if ids.isEmpty, let single = item.guidString,
                   let id = Self.plexGuid(single, isShow: section.type == "show") {
                    ids.insert(id)
                }
                guard !ids.isEmpty else { continue }
                let logo = (item.image ?? []).first { $0.type == "clearLogo" }?.url
                let progress: Double? = {
                    guard let offset = item.viewOffset, let duration = item.duration,
                          duration > 0 else { return nil }
                    return min(1, Double(offset) / Double(duration))
                }()
                titles.append(MediaServerTitle(
                    itemID: ratingKey,
                    title: item.title ?? "",
                    year: item.year,
                    ids: ids,
                    artwork: Artwork(poster: artworkURL(item.thumb),
                                     backdrop: artworkURL(item.art),
                                     logo: artworkURL(logo)),
                    watched: (item.viewCount ?? 0) > 0,
                    playProgress: progress))
            }
        }
        return titles
    }

    /// "tmdb://603", "tvdb://81189", "imdb://tt0133093" — and the legacy
    /// `com.plexapp.agents.themoviedb://603?lang=en` shape.
    static func plexGuid(_ raw: String?, isShow: Bool) -> MediaID? {
        guard let raw else { return nil }
        let value = raw.split(separator: "?").first.map(String.init) ?? raw
        func suffix(after marker: String) -> String? {
            guard let range = value.range(of: marker) else { return nil }
            let rest = String(value[range.upperBound...])
            return rest.isEmpty ? nil : rest
        }
        if let tmdb = suffix(after: "tmdb://") ?? suffix(after: "themoviedb://"),
           let number = Int(tmdb.split(separator: "/").first.map(String.init) ?? tmdb) {
            return isShow ? .tmdbSeries(number) : .tmdbMovie(number)
        }
        if let tvdb = suffix(after: "tvdb://") ?? suffix(after: "thetvdb://"),
           let number = Int(tvdb.split(separator: "/").first.map(String.init) ?? tvdb) {
            return .tvdb(number)
        }
        if let imdb = suffix(after: "imdb://") ?? suffix(after: "imdb.com/title/") {
            return .imdb(imdb.split(separator: "/").first.map(String.init) ?? imdb)
        }
        return nil
    }

    private struct PlexSections: Decodable {
        struct Container: Decodable {
            let directory: [Section]?
            enum CodingKeys: String, CodingKey { case directory = "Directory" }
        }
        struct Section: Decodable {
            let key: String?
            let type: String?
        }
        let mediaContainer: Container?
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private struct PlexItems: Decodable {
        struct Container: Decodable {
            let metadata: [Item]?
            enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
        }
        struct Guid: Decodable { let id: String? }
        struct Image: Decodable {
            let type: String?
            let url: String?
        }
        struct Item: Decodable {
            let ratingKey: String?
            let title: String?
            let year: Int?
            let thumb: String?
            let art: String?
            let viewCount: Int?
            let viewOffset: Int?
            let duration: Int?
            let guid: [Guid]?
            let guidString: String?
            let image: [Image]?
            enum CodingKeys: String, CodingKey {
                case ratingKey, title, year, thumb, art, viewCount, viewOffset, duration
                case guid = "Guid"
                case guidString = "guid"
                case image = "Image"
            }
        }
        let mediaContainer: Container?
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    // MARK: - Jellyfin / Emby

    private func jellyfinTitles() async throws -> [MediaServerTitle] {
        // The user-scoped path is what carries play state; without a user id
        // the artwork still comes through and `watched` is simply unknown.
        let path = userID.map { "/Users/\($0)/Items" } ?? "/Items"
        guard let request = request(path: path, query: [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Fields", value: "ProviderIds,ProductionYear"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ]) else { throw MediaError.notConfigured(id) }

        let page = try await send(request, as: JellyfinItems.self)
        return (page.items ?? []).compactMap { item -> MediaServerTitle? in
            guard let itemID = item.id else { return nil }
            var ids = Set<MediaID>()
            let isSeries = item.type == "Series"
            if let tmdb = item.providerIds?.value(for: "tmdb").flatMap(Int.init) {
                ids.insert(isSeries ? .tmdbSeries(tmdb) : .tmdbMovie(tmdb))
            }
            if let tvdb = item.providerIds?.value(for: "tvdb").flatMap(Int.init) {
                ids.insert(.tvdb(tvdb))
            }
            if let imdb = item.providerIds?.value(for: "imdb") { ids.insert(.imdb(imdb)) }
            guard !ids.isEmpty else { return nil }

            func image(_ kind: String, tag: String?) -> URL? {
                guard let tag else { return nil }
                return artworkURL("/Items/\(itemID)/Images/\(kind)?tag=\(tag)")
            }
            return MediaServerTitle(
                itemID: itemID,
                title: item.name ?? "",
                year: item.productionYear,
                ids: ids,
                artwork: Artwork(poster: image("Primary", tag: item.imageTags?["Primary"]),
                                 backdrop: image("Backdrop/0", tag: item.backdropImageTags?.first),
                                 logo: image("Logo", tag: item.imageTags?["Logo"])),
                watched: item.userData?.played ?? false,
                playProgress: item.userData?.playedPercentage.map { $0 / 100 })
        }
    }

    private struct JellyfinItems: Decodable {
        struct Item: Decodable {
            struct UserData: Decodable {
                let played: Bool?
                let playedPercentage: Double?
                enum CodingKeys: String, CodingKey {
                    case played = "Played"
                    case playedPercentage = "PlayedPercentage"
                }
            }
            /// Jellyfin spells the keys "Tmdb"/"Imdb", Emby "TmdbId" — match
            /// case-insensitively on the prefix instead of guessing.
            struct ProviderIDs: Decodable {
                let raw: [String: String]
                init(from decoder: Decoder) throws {
                    raw = (try? [String: String](from: decoder)) ?? [:]
                }
                func value(for key: String) -> String? {
                    raw.first { $0.key.lowercased().hasPrefix(key) }?.value
                }
            }
            let id: String?
            let name: String?
            let type: String?
            let productionYear: Int?
            let providerIds: ProviderIDs?
            let imageTags: [String: String]?
            let backdropImageTags: [String]?
            let userData: UserData?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case type = "Type"
                case productionYear = "ProductionYear"
                case providerIds = "ProviderIds"
                case imageTags = "ImageTags"
                case backdropImageTags = "BackdropImageTags"
                case userData = "UserData"
            }
        }
        let items: [Item]?
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }
}

public extension MediaServerFlavor {
    var displayName: String {
        switch self {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var copy = self
        while copy.hasSuffix(suffix) { copy.removeLast(suffix.count) }
        return copy
    }
}

/// Server-side downscaling for artwork URLs.
///
/// Worth the special-casing: a media server stores the original, and a 150 pt
/// poster card pulling a 600 KB file — once per card in a grid — is the kind
/// of waste this layer exists to find. Both families resize on request, so a
/// card can cost tens of kilobytes instead.
///
/// Pure and static: the app builds these URLs in a poster accessor that has no
/// provider instance to hand, and a sized URL must be derivable from the raw
/// one alone.
public enum MediaServerArtworkSizing {
    /// The shape of the artwork being asked for. Plex fits the image inside a
    /// BOX, so the box has to have roughly the right shape: asking for a
    /// 16:9 backdrop inside a poster-shaped box makes Plex fit by height and
    /// hand back a much larger picture than was asked for — measured at 120 KB
    /// against 56 KB for the same backdrop.
    public enum Aspect: Sendable {
        /// 2:3, the poster.
        case poster
        /// 16:9, backdrops and wide cards.
        case wide

        func height(for width: Int) -> Int {
            switch self {
            case .poster: Int(Double(width) * 1.5)
            case .wide: Int(Double(width) * 9 / 16)
            }
        }
    }

    /// `width` is a box the image is fitted into, never a stretch: both
    /// servers preserve the aspect ratio inside it, and neither upscales.
    /// Returns nil when the URL is not the server's own — a TMDB poster must
    /// never be rewritten into a Plex transcode.
    ///
    /// Clear logos are deliberately never passed through here: Plex's
    /// transcoder answers in JPEG, and a logo without its alpha channel is a
    /// white slab over the artwork.
    public static func sized(_ url: URL, flavor: MediaServerFlavor,
                             baseURL: URL?, width: Int,
                             aspect: Aspect = .poster) -> URL? {
        guard let baseURL, owns(url, baseURL: baseURL) else { return nil }
        switch flavor {
        case .plex:
            // Plex resizes through a transcoder that takes the original
            // image's own path as a parameter, so the item path moves from
            // the URL into `url=`. `upscale=0` keeps a small source small.
            var path = url.path()
            if let query = url.query(), !query.isEmpty { path += "?\(query)" }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            components.path = "/photo/:/transcode"
            components.queryItems = [
                URLQueryItem(name: "width", value: String(width)),
                URLQueryItem(name: "height", value: String(aspect.height(for: width))),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "upscale", value: "0"),
                URLQueryItem(name: "url", value: path),
            ]
            return components.url
        case .jellyfin, .emby:
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            var items = components.queryItems ?? []
            guard !items.contains(where: { $0.name == "maxWidth" }) else { return url }
            items.append(URLQueryItem(name: "maxWidth", value: String(width)))
            components.queryItems = items
            return components.url
        }
    }

    /// Same host, port and scheme. Compared that way rather than on the whole
    /// prefix because the user's base URL may carry a reverse-proxy path.
    static func owns(_ url: URL, baseURL: URL) -> Bool {
        url.host()?.lowercased() == baseURL.host()?.lowercased()
            && url.port == baseURL.port
            && url.scheme?.lowercased() == baseURL.scheme?.lowercased()
    }
}
