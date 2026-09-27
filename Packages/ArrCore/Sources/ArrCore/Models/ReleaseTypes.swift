import Foundation

/// One interactive-/manual-search result from an arr's `/release` endpoint —
/// a candidate release on an indexer that the user can grab. Fields are lenient
/// (mostly optional) so the same model decodes across Sonarr/Radarr/Lidarr,
/// whose release resources differ slightly.
nonisolated public struct Release: Codable, Identifiable, Sendable {
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
    /// ReleaseListView tags each row with what it actually covers.
    public let fullSeason: Bool?
    /// Sonarr-only: the season this release belongs to, and the episodes it
    /// carries (empty / absent on a pack). Drives the row's scope badge.
    public let seasonNumber: Int?
    public let episodeNumbers: [Int]?
    /// Indexer flags (freeleech and friends). Sonarr v4 sends names; older
    /// builds send a bitfield, which we decode to nothing rather than guess at
    /// a mapping — a wrong "Freeleech" badge is worse than none.
    public let indexerFlags: [String]?

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
        case fullSeason, seasonNumber, episodeNumbers, indexerFlags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guid = try c.decode(String.self, forKey: .guid)
        title = try c.decode(String.self, forKey: .title)
        indexer = try c.decodeIfPresent(String.self, forKey: .indexer)
        indexerId = try c.decodeIfPresent(Int.self, forKey: .indexerId)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        seeders = try c.decodeIfPresent(Int.self, forKey: .seeders)
        leechers = try c.decodeIfPresent(Int.self, forKey: .leechers)
        proto = try c.decodeIfPresent(String.self, forKey: .proto)
        customFormatScore = try c.decodeIfPresent(Int.self, forKey: .customFormatScore)
        customFormats = try c.decodeIfPresent([NamedRef].self, forKey: .customFormats)
        quality = try c.decodeIfPresent(QualityContainer.self, forKey: .quality)
        languages = try c.decodeIfPresent([NamedRef].self, forKey: .languages)
        releaseGroup = try c.decodeIfPresent(String.self, forKey: .releaseGroup)
        ageHours = try c.decodeIfPresent(Double.self, forKey: .ageHours)
        publishDate = try c.decodeIfPresent(String.self, forKey: .publishDate)
        rejected = try c.decodeIfPresent(Bool.self, forKey: .rejected)
        rejections = try c.decodeIfPresent([String].self, forKey: .rejections)
        infoUrl = try c.decodeIfPresent(String.self, forKey: .infoUrl)
        fullSeason = try c.decodeIfPresent(Bool.self, forKey: .fullSeason)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumbers = try c.decodeIfPresent([Int].self, forKey: .episodeNumbers)
        indexerFlags = try? c.decodeIfPresent([String].self, forKey: .indexerFlags)
    }

    nonisolated public struct QualityContainer: Codable, Sendable {
        public let quality: NamedRef?
    }

    nonisolated public struct NamedRef: Codable, Sendable {
        public let name: String?
    }
}

/// Row-level answers the manual-search list needs from a release: what the
/// file covers and what to print as its name.
nonisolated public extension Release {
    /// What one release covers. `.episodes` carries its own already-formatted
    /// label ("E04", "E01–05"); `.pack` is localised by the view.
    enum Scope: Sendable, Equatable { case pack, episodes(String) }

    /// nil when the search has no such axis — a movie, or a single episode.
    var scope: Scope? {
        if fullSeason == true { return .pack }
        let numbers = (episodeNumbers ?? []).sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        let start = String(format: "E%02d", first)
        return .episodes(first == last ? start : start + "–" + String(format: "%02d", last))
    }

    /// The release name minus the leading series name and `SxxExx` marker —
    /// both already on screen (the header and the scope badge), and both
    /// eating the width where the tokens that actually differ live. Falls back
    /// to the raw title whenever the marker isn't where we expect it.
    var shortTitle: String {
        guard let marker = title.range(of: "[Ss][0-9]{1,3}([Ee][0-9]{1,4})*(-?[Ee][0-9]{1,4})*",
                                       options: .regularExpression) else { return title }
        let rest = title[marker.upperBound...].drop { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" }
        return rest.count >= 8 ? String(rest) : title
    }

    /// The indexer's name as a human would say it. Indexers synced from
    /// Prowlarr arrive in the *arr named "NZBgeek (Prowlarr)" — the suffix says
    /// how the *arr learned about it, which is nobody's business on a button.
    var indexerName: String? {
        guard let indexer, !indexer.isEmpty else { return nil }
        return Release.strippingProwlarrSuffix(indexer)
    }

    /// The fallback spelling when Prowlarr can't be asked: the *arr's label
    /// without the one suffix we can remove without guessing.
    static func strippingProwlarrSuffix(_ name: String) -> String {
        guard let suffix = name.range(of: " (Prowlarr)", options: [.caseInsensitive, .backwards, .anchored],
                                      range: name.index(name.endIndex, offsetBy: -min(11, name.count))..<name.endIndex)
        else { return name }
        return String(name[name.startIndex..<suffix.lowerBound])
    }

    /// Indexer flags worth a badge. Only the name form is trusted — see the
    /// property's note.
    var flagLabels: [String] { (indexerFlags ?? []).filter { !$0.isEmpty } }
}

/// Identifies what to run a manual search for. Drives `ReleaseListView` —
/// `source` picks the arr client, `query` is the exact `/release` query
/// (movieId / episodeId / albumId, or a season's seriesId + seasonNumber).
nonisolated public struct ManualSearchTarget: Identifiable, Hashable, Sendable {
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
    /// ReleaseListView offers a packs-only filter for these.
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
