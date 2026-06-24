import Foundation

/// One interactive-/manual-search result from an arr's `/release` endpoint —
/// a candidate release on an indexer that the user can grab. Fields are lenient
/// (mostly optional) so the same model decodes across Sonarr/Radarr/Lidarr,
/// whose release resources differ slightly.
public struct Release: Decodable, Identifiable, Sendable {
    public let guid: String
    public let title: String
    public let indexer: String?
    public let indexerId: Int?
    public let size: Int64?
    public let seeders: Int?
    public let leechers: Int?
    /// "torrent" or "usenet" (JSON key `protocol`).
    public let proto: String?
    public let customFormatScore: Int?
    public let customFormats: [NamedRef]?
    public let quality: QualityContainer?
    public let languages: [NamedRef]?
    public let releaseGroup: String?
    public let ageHours: Double?
    public let publishDate: String?
    public let rejected: Bool?
    public let rejections: [String]?
    public let infoUrl: String?
    /// Sonarr-only: true when the release is a full-season pack (not a single
    /// episode). The `/release?seriesId&seasonNumber` endpoint returns both, so
    /// ReleaseListView prefers packs for a season search.
    public let fullSeason: Bool?

    public var id: String { guid }

    public var qualityName: String? { quality?.quality?.name }
    public var isTorrent: Bool { (proto ?? "").caseInsensitiveCompare("torrent") == .orderedSame }
    public var sizeBytes: Int64 { size ?? 0 }
    public var isRejected: Bool { rejected == true && !(rejections ?? []).isEmpty }

    /// Short protocol badge text — "Torrent" / "NZB".
    public var protocolLabel: String { isTorrent ? "Torrent" : "NZB" }

    enum CodingKeys: String, CodingKey {
        case guid, title, indexer, indexerId, size, seeders, leechers
        case proto = "protocol"
        case customFormatScore, customFormats, quality, languages
        case releaseGroup, ageHours, publishDate, rejected, rejections, infoUrl
        case fullSeason
    }

    public struct QualityContainer: Decodable, Sendable {
        public let quality: NamedRef?
    }

    public struct NamedRef: Decodable, Sendable {
        public let name: String?
    }
}

/// Identifies what to run a manual search for. Drives `ReleaseListView` —
/// `source` picks the arr client, `query` is the exact `/release` query
/// (movieId / episodeId / albumId, or a season's seriesId + seasonNumber).
public struct ManualSearchTarget: Identifiable, Hashable, Sendable {
    public let source: QueueItem.Source
    public let title: String
    public let query: [URLQueryItem]

    public init(source: QueueItem.Source, title: String, query: [URLQueryItem]) {
        self.source = source
        self.title = title
        self.query = query
    }

    public var id: String {
        source.rawValue + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    /// True for a whole-season search (seriesId + seasonNumber, no episodeId).
    /// The same `/release` endpoint also returns per-episode releases, so
    /// ReleaseListView uses this to prefer the season packs.
    public var isSeasonSearch: Bool {
        query.contains { $0.name == "seasonNumber" }
    }

    // Equatable/Hashable via `id` so we don't depend on URLQueryItem's own conformances.
    public static func == (lhs: ManualSearchTarget, rhs: ManualSearchTarget) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static func movie(source: QueueItem.Source, movieId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: source, title: title,
                           query: [URLQueryItem(name: "movieId", value: String(movieId))])
    }
    public static func episode(episodeId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .sonarr, title: title,
                           query: [URLQueryItem(name: "episodeId", value: String(episodeId))])
    }
    public static func album(albumId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .lidarr, title: title,
                           query: [URLQueryItem(name: "albumId", value: String(albumId))])
    }
    public static func season(seriesId: Int, seasonNumber: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .sonarr, title: title, query: [
            URLQueryItem(name: "seriesId", value: String(seriesId)),
            URLQueryItem(name: "seasonNumber", value: String(seasonNumber)),
        ])
    }
}
