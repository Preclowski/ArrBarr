import Foundation

// Shared shapes. One record family per resource; the flavour decides which embedded entity is present.

public struct ArrPage<Record: Codable & Sendable>: Codable, Sendable {
    public let page: Int?
    public let pageSize: Int?
    public let totalRecords: Int?
    public let records: [Record]
}

public struct ArrCustomFormat: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let name: String
}

public struct ArrQuality: Codable, Equatable, Sendable, Hashable {
    public struct Name: Codable, Equatable, Sendable, Hashable { public let name: String?; public let resolution: Int? }
    public let quality: Name?
    public var name: String? { quality?.name }
}

public struct ArrImage: Codable, Equatable, Sendable, Hashable {
    public let coverType: String?
    public let url: String?
    public let remoteUrl: String?
}

public struct ArrStatusMessage: Codable, Equatable, Sendable, Hashable {
    public let title: String?
    public let messages: [String]?
}

public struct ArrLanguage: Codable, Equatable, Sendable, Hashable { public let id: Int?; public let name: String? }

public struct ArrRatings: Codable, Equatable, Sendable, Hashable {
    public struct Value: Codable, Equatable, Sendable, Hashable { public let value: Double?; public let votes: Int? }
    public let tmdb: Value?
    public let imdb: Value?
    public let metacritic: Value?
    public let rottenTomatoes: Value?
    /// Sonarr and Lidarr put the value at the top level.
    public let value: Double?
    public let votes: Int?
}

public struct ArrFile: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let movieId: Int?
    public let seriesId: Int?
    public let albumId: Int?
    public let customFormats: [ArrCustomFormat]?
    public let customFormatScore: Int?
    public let quality: ArrQuality?
    public let size: Int64?
    public let relativePath: String?
    public let path: String?
    public let releaseGroup: String?
    public let languages: [ArrLanguage]?
    public let mediaInfo: MediaInfo?

    public struct MediaInfo: Codable, Equatable, Sendable, Hashable {
        public let audioCodec: String?
        public let audioChannels: Double?
        public let videoCodec: String?
        public let resolution: String?
        public let runTime: String?
        public let audioLanguages: String?
        public let subtitles: String?
    }
}

public struct ArrStatistics: Codable, Equatable, Sendable, Hashable {
    public let episodeCount: Int?
    public let episodeFileCount: Int?
    public let totalEpisodeCount: Int?
    public let seasonCount: Int?
    public let albumCount: Int?
    public let trackCount: Int?
    public let trackFileCount: Int?
    public let totalTrackCount: Int?
    public let sizeOnDisk: Int64?
    public let percentOfEpisodes: Double?
}

public struct ArrSeason: Codable, Equatable, Sendable, Hashable {
    public let seasonNumber: Int
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let statistics: ArrStatistics?
}

public struct ArrAlternateTitle: Codable, Equatable, Sendable, Hashable {
    public let title: String?
    public let movieId: Int?
}

// Entities: library rows, lookup rows and the objects embedded in queue/history/calendar all share these.

public struct ArrMovie: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let tmdbId: Int?
    public let imdbId: String?
    public let foreignId: String?
    public let title: String
    public let originalTitle: String?
    public let sortTitle: String?
    public let titleSlug: String?
    public let year: Int?
    public let overview: String?
    public let runtime: Int?
    public let status: String?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let hasFile: Bool?
    public let isAvailable: Bool?
    public let minimumAvailability: String?
    public let qualityProfileId: Int?
    public let rootFolderPath: String?
    public let path: String?
    public let folderName: String?
    public let sizeOnDisk: Int64?
    public let added: String?
    public let inCinemas: String?
    public let digitalRelease: String?
    public let physicalRelease: String?
    public let certification: String?
    public let studio: String?
    public let genres: [String]?
    public let tags: [Int]?
    public let images: [ArrImage]?
    public let ratings: ArrRatings?
    public let movieFile: ArrFile?
    public let movieFileId: Int?
    public let alternateTitles: [ArrAlternateTitle]?
    public let youTubeTrailerId: String?
    public let collection: Collection?
    public let lastSearchTime: String?

    public struct Collection: Codable, Equatable, Sendable, Hashable { public let title: String?; public let tmdbId: Int? }
}

public struct ArrSeries: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let tvdbId: Int?
    public let tmdbId: Int?
    public let imdbId: String?
    public let title: String
    public let sortTitle: String?
    public let titleSlug: String?
    public let year: Int?
    public let overview: String?
    public let runtime: Int?
    public let status: String?
    public let network: String?
    public let seriesType: String?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let qualityProfileId: Int?
    public let rootFolderPath: String?
    public let path: String?
    public let sizeOnDisk: Int64?
    public let added: String?
    public let firstAired: String?
    public let nextAiring: String?
    public let previousAiring: String?
    public let certification: String?
    public let genres: [String]?
    public let tags: [Int]?
    public let images: [ArrImage]?
    public let ratings: ArrRatings?
    public let statistics: ArrStatistics?
    /// `var` with the seasons' own `monitored`: a detail screen flips one before Sonarr confirms.
    public var seasons: [ArrSeason]?
    public let alternateTitles: [ArrAlternateTitle]?
}

public struct ArrEpisode: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let seriesId: Int?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let title: String?
    public let airDate: String?
    public let airDateUtc: String?
    public let overview: String?
    public let hasFile: Bool?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let episodeFileId: Int?
    public let runtime: Int?
    public let finaleType: String?
    public let series: ArrSeries?

    /// A stand-in from coordinates known before the record arrives (a queue row); every other field is unknown.
    public init(placeholderSeason seasonNumber: Int?, episode episodeNumber: Int?) {
        id = 0; seriesId = nil; self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; title = nil
        airDate = nil; airDateUtc = nil; overview = nil; hasFile = nil; monitored = nil; episodeFileId = nil
        runtime = nil; finaleType = nil; series = nil
    }
}

public struct ArrArtist: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let foreignArtistId: String?
    public let artistName: String?
    public let sortName: String?
    public let disambiguation: String?
    public let overview: String?
    public let status: String?
    public let artistType: String?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let qualityProfileId: Int?
    public let metadataProfileId: Int?
    public let rootFolderPath: String?
    public let path: String?
    public let added: String?
    public let genres: [String]?
    public let tags: [Int]?
    public let images: [ArrImage]?
    public let ratings: ArrRatings?
    public let statistics: ArrStatistics?
}

public struct ArrAlbum: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: Int?
    public let foreignAlbumId: String?
    public let artistId: Int?
    public let title: String
    public let disambiguation: String?
    public let overview: String?
    public let albumType: String?
    public let releaseDate: String?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let anyReleaseOk: Bool?
    public let qualityProfileId: Int?
    public let duration: Int?
    public let genres: [String]?
    public let images: [ArrImage]?
    public let ratings: ArrRatings?
    public let statistics: ArrStatistics?
    public let artist: ArrArtist?
}

public struct ArrTrack: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let albumId: Int?
    public let trackNumber: String?
    public let absoluteTrackNumber: Int?
    public let mediumNumber: Int?
    public let title: String?
    public let duration: Int?
    public let hasFile: Bool?
    public let trackFileId: Int?
}

/// Queue rows across the four flavours; the embedded entity matches the flavour.
public struct ArrQueueRecord: Codable, Equatable, Sendable, Hashable, LivePatchable {
    public let id: Int
    public let movieId: Int?
    public let seriesId: Int?
    public let episodeId: Int?
    public let seasonNumber: Int?
    public let artistId: Int?
    public let albumId: Int?
    public let title: String?
    public var status: String?
    public let trackedDownloadStatus: String?
    public let trackedDownloadState: String?
    public let downloadId: String?
    public let downloadClient: String?
    public let indexer: String?
    public let `protocol`: String?
    public let size: Double?
    public let sizeleft: Double?
    public let timeleft: String?
    public let estimatedCompletionTime: String?
    public let added: String?
    public let customFormats: [ArrCustomFormat]?
    public let customFormatScore: Int?
    public let quality: ArrQuality?
    public let languages: [ArrLanguage]?
    public let statusMessages: [ArrStatusMessage]?
    public let errorMessage: String?
    public let outputPath: String?
    public let movie: ArrMovie?
    public let series: ArrSeries?
    public let episode: ArrEpisode?
    public let artist: ArrArtist?
    public let album: ArrAlbum?

    public func applying(_ change: PendingEffect.Change) -> ArrQueueRecord? {
        guard case let .status(value) = change else { return nil }
        var copy = self
        copy.status = value
        return copy
    }

    public var liveAliases: [String] { downloadId.map { [$0.lowercased()] } ?? [] }

    /// A grabbed pending release (no download id yet) comes back under a new queue id, tracking the same title.
    public func succeeds(_ gone: ArrQueueRecord) -> Bool {
        guard gone.downloadId?.isEmpty ?? true, !(downloadId?.isEmpty ?? true) else { return false }
        return movieId == gone.movieId && episodeId == gone.episodeId && albumId == gone.albumId && seriesId == gone.seriesId
            && (movieId ?? episodeId ?? albumId) != nil
    }
}

public struct ArrHistoryRecord: Codable, Equatable, Sendable, Hashable {
    public let id: Int
    public let movieId: Int?
    public let seriesId: Int?
    public let episodeId: Int?
    public let artistId: Int?
    public let albumId: Int?
    public let trackId: Int?
    public let sourceTitle: String?
    public let downloadId: String?
    public let date: String?
    public let eventType: String?
    public let quality: ArrQuality?
    public let customFormats: [ArrCustomFormat]?
    public let customFormatScore: Int?
    public let languages: [ArrLanguage]?
    public let data: [String: JSONValue]?
    public let movie: ArrMovie?
    public let series: ArrSeries?
    public let episode: ArrEpisode?
    public let artist: ArrArtist?
    public let album: ArrAlbum?
}

/// Radarr answers with movies, Sonarr with episodes (+ series), Lidarr with albums (+ artist).
public struct ArrCalendarRecord: Codable, Equatable, Sendable, Hashable {
    public let id: Int
    public let title: String?
    public let year: Int?
    public let overview: String?
    public let hasFile: Bool?
    /// `var`: a detail screen flips it optimistically before the arr confirms.
    public var monitored: Bool?
    public let images: [ArrImage]?
    public let runtime: Int?
    public let genres: [String]?
    public let status: String?
    public let ratings: ArrRatings?
    public let qualityProfileId: Int?
    public let certification: String?
    public let titleSlug: String?
    public let tmdbId: Int?
    public let imdbId: String?
    public let inCinemas: String?
    public let digitalRelease: String?
    public let physicalRelease: String?
    public let movieFile: ArrFile?
    public let seriesId: Int?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let airDate: String?
    public let airDateUtc: String?
    public let episodeFileId: Int?
    public let finaleType: String?
    public let series: ArrSeries?
    public let artistId: Int?
    public let foreignAlbumId: String?
    public let releaseDate: String?
    public let albumType: String?
    public let artist: ArrArtist?
    public let statistics: ArrStatistics?
}

public struct ArrHealth: Codable, Equatable, Sendable, Hashable {
    public let source: String?
    public let type: String?
    public let message: String?
    public let wikiUrl: String?
}

public struct ArrDiskSpace: Codable, Equatable, Sendable, Hashable {
    public let path: String?
    public let label: String?
    public let freeSpace: Int64?
    public let totalSpace: Int64?
}

public struct ArrSystemStatus: Codable, Equatable, Sendable, Hashable {
    public let appName: String?
    public let instanceName: String?
    public let version: String?
    public let branch: String?
    public let osName: String?
    public let startTime: String?
}

public struct ArrCommand: Codable, Equatable, Sendable, Hashable {
    public struct Body: Codable, Equatable, Sendable, Hashable {
        public let movieIds: [Int]?
        public let movieId: Int?
        public let seriesId: Int?
        public let seasonNumber: Int?
        public let episodeIds: [Int]?
        public let albumIds: [Int]?
        public let albumId: Int?
        public let artistId: Int?
    }
    public let id: Int?
    public let name: String?
    public let commandName: String?
    public let status: String?
    public let started: String?
    public let body: Body?

    public var isRunning: Bool { ["queued", "started", "running"].contains((status ?? "").lowercased()) }
}

public struct ArrQualityProfile: Codable, Equatable, Sendable, Hashable, Identifiable {
    public struct FormatItem: Codable, Equatable, Sendable, Hashable { public let format: Int; public let name: String?; public let score: Int }
    public let id: Int
    public let name: String
    public let upgradeAllowed: Bool?
    public let cutoff: Int?
    public let formatItems: [FormatItem]?
}

public struct ArrMetadataProfile: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
}

public struct ArrRootFolder: Codable, Equatable, Sendable, Hashable {
    public let id: Int?
    public let path: String?
    public let accessible: Bool?
    public let freeSpace: Int64?
}

public struct ArrCustomFormatDetail: Codable, Equatable, Sendable, Hashable {
    public struct Specification: Codable, Equatable, Sendable, Hashable {
        public struct Field: Codable, Equatable, Sendable, Hashable { public let name: String?; public let value: JSONValue? }
        public let name: String?
        public let implementation: String?
        public let implementationName: String?
        public let negate: Bool?
        public let required: Bool?
        public let fields: [Field]?
    }
    public let id: Int
    public let name: String
    public let specifications: [Specification]?
}

public struct ArrDownloadClient: Codable, Equatable, Sendable, Hashable {
    public struct Field: Codable, Equatable, Sendable, Hashable { public let name: String?; public let value: JSONValue? }
    public let id: Int?
    public let name: String?
    public let implementation: String?
    public let `protocol`: String?
    public let enable: Bool?
    public let priority: Int?
    public let fields: [Field]?
}

public struct ArrCredit: Codable, Equatable, Sendable, Hashable {
    public let personName: String?
    public let personTmdbId: Int?
    public let character: String?
    public let order: Int?
    public let type: String?
    public let department: String?
    public let job: String?
    public let images: [ArrImage]?
}

public struct ArrRelease: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let guid: String
    public let title: String
    public let indexer: String?
    public let indexerId: Int?
    public let size: Int64?
    public let seeders: Int?
    public let leechers: Int?
    public let age: Int?
    public let ageHours: Double?
    public let publishDate: String?
    public let `protocol`: String?
    public let quality: ArrQuality?
    public let customFormatScore: Int?
    public let customFormats: [ArrCustomFormat]?
    public let rejected: Bool?
    public let rejections: [String]?
    public let approved: Bool?
    public let infoUrl: String?
    public let downloadUrl: String?
    public let languages: [ArrLanguage]?
    public let releaseGroup: String?
    /// Sonarr: a full-season pack, and the season and episodes a release carries.
    public let fullSeason: Bool?
    public let seasonNumber: Int?
    public let episodeNumbers: [Int]?
    /// Names on Sonarr v4, a bitfield on older builds.
    public let indexerFlags: JSONValue?

    public var id: String { guid }
    /// Only the name form: a bitfield has no mapping worth guessing at.
    public var indexerFlagNames: [String] { indexerFlags?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty } ?? [] }
}

/// Lidarr `GET /search` rows: either an artist or an album.
public struct ArrSearchRecord: Codable, Equatable, Sendable, Hashable {
    public let foreignId: String?
    public let artist: ArrArtist?
    public let album: ArrAlbum?
}

/// Add payloads keep the spellings Servarr expects (`firstSeason`, `latestSeason`, ...).
public struct ArrAddOptions: Codable, Equatable, Sendable, Hashable {
    public var searchForMovie: Bool?
    public var searchForMissingEpisodes: Bool?
    public var searchForMissingAlbums: Bool?
    public var monitor: String?
    public init(searchForMovie: Bool? = nil, searchForMissingEpisodes: Bool? = nil, searchForMissingAlbums: Bool? = nil, monitor: String? = nil) {
        self.searchForMovie = searchForMovie; self.searchForMissingEpisodes = searchForMissingEpisodes
        self.searchForMissingAlbums = searchForMissingAlbums; self.monitor = monitor
    }
}

public struct ArrAddPayload: Codable, Equatable, Sendable {
    public var title: String?
    public var tmdbId: Int?
    public var tvdbId: Int?
    public var foreignArtistId: String?
    public var foreignAlbumId: String?
    /// Whisparr scenes without a TMDB id.
    public var foreignId: String?
    public var artistName: String?
    public var year: Int?
    public var titleSlug: String?
    public var images: [ArrImage]?
    public var seasons: [ArrSeason]?
    public var qualityProfileId: Int
    public var metadataProfileId: Int?
    public var rootFolderPath: String
    public var monitored: Bool
    /// Radarr/Whisparr take the monitor mode at the top level; Sonarr and Lidarr in `addOptions`.
    public var monitor: String?
    public var minimumAvailability: String?
    public var seriesType: String?
    public var seasonFolder: Bool?
    public var tags: [Int]?
    public var addOptions: ArrAddOptions?

    public init(qualityProfileId: Int, rootFolderPath: String, monitored: Bool = true) {
        self.qualityProfileId = qualityProfileId; self.rootFolderPath = rootFolderPath; self.monitored = monitored
    }
}

/// Typed read-modify-write: the fields MediaKit models plus everything else, echoed back on PUT.
/// The settings the Edit form reads and writes on a movie, series or artist; nil means "leave as is".
public struct ArrRecordSettings: Codable, Equatable, Sendable {
    public var qualityProfileId: Int?
    public var metadataProfileId: Int?
    public var minimumAvailability: String?
    public var seriesType: String?
    public var monitorNewItems: String?
    public var seasonFolder: Bool?
    public var rootFolderPath: String?
    public var path: String?

    public init(qualityProfileId: Int? = nil, metadataProfileId: Int? = nil, minimumAvailability: String? = nil, seriesType: String? = nil,
                monitorNewItems: String? = nil, seasonFolder: Bool? = nil, rootFolderPath: String? = nil) {
        self.qualityProfileId = qualityProfileId; self.metadataProfileId = metadataProfileId
        self.minimumAvailability = minimumAvailability; self.seriesType = seriesType
        self.monitorNewItems = monitorNewItems; self.seasonFolder = seasonFolder; self.rootFolderPath = rootFolderPath
    }

    mutating func merge(_ edit: ArrRecordSettings) {
        qualityProfileId = edit.qualityProfileId ?? qualityProfileId
        metadataProfileId = edit.metadataProfileId ?? metadataProfileId
        minimumAvailability = edit.minimumAvailability ?? minimumAvailability
        seriesType = edit.seriesType ?? seriesType
        monitorNewItems = edit.monitorNewItems ?? monitorNewItems
        seasonFolder = edit.seasonFolder ?? seasonFolder
        rootFolderPath = edit.rootFolderPath ?? rootFolderPath
    }

    /// The record's folder under the new root, when this edit changes the root.
    func movedPath(from current: ArrRecordSettings) -> String? {
        let slash = CharacterSet(charactersIn: "/")
        guard let newRoot = rootFolderPath, let oldRoot = current.rootFolderPath,
              newRoot.trimmingCharacters(in: slash) != oldRoot.trimmingCharacters(in: slash),
              let folder = current.path?.split(separator: "/").last else { return nil }
        return (newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot) + "/" + folder
    }
}

public struct ArrRecordEnvelope<Known: Codable & Sendable>: Codable, Sendable {
    public var known: Known
    public var extra: [String: JSONValue]
    /// Top-level edits applied last, so `set("monitored", .bool(true))` wins over both.
    public var overrides: [String: JSONValue] = [:]

    public init(from decoder: any Decoder) throws {
        known = try Known(from: decoder)
        extra = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        let knownData = try WireCodec.encoder.encode(known)
        guard case var .object(merged)? = try? WireCodec.decoder.decode(JSONValue.self, from: knownData) else { return }
        for (k, v) in extra where merged[k] == nil || merged[k] == .null { merged[k] = v }
        for (k, v) in overrides { merged[k] = v }
        try JSONValue.object(merged).encode(to: encoder)
    }

    public mutating func set(_ key: String, _ value: JSONValue) { overrides[key] = value }
    public subscript(key: String) -> JSONValue? { overrides[key] ?? extra[key] }
}

extension Array where Element == ArrImage {
    /// Prefers a remote URL of the requested cover types, in order.
    public func url(coverTypes: [String]) -> URL? {
        for type in coverTypes {
            if let image = first(where: { ($0.coverType ?? "").lowercased() == type.lowercased() }),
               let raw = image.remoteUrl ?? image.url, let url = URL(string: raw) { return url }
        }
        return nil
    }
}

/// An indexer as configured *in the arr* (`/indexer`). ArrBarr reads two things
/// from it: the id a release carries, and the `baseUrl` field, whose path holds
/// the Prowlarr indexer id when the indexer was synced from Prowlarr
/// ("http://prowlarr:9696/14/api").
public struct ArrIndexerDefinition: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String?
    public let fields: [Field]?

    public struct Field: Codable, Sendable {
        public let name: String?
        public let value: JSONValue?
    }

    /// The Prowlarr-side id, when this indexer came from Prowlarr.
    public var prowlarrIndexerID: Int? {
        guard let base = fields?.first(where: { $0.name == "baseUrl" }),
              case let .string(url)? = base.value,
              let components = URLComponents(string: url) else { return nil }
        // …/{id}/api — the only numeric path segment Prowlarr puts there.
        let segments = components.path.split(separator: "/")
        guard segments.count >= 2, segments.last == "api", let id = Int(segments[segments.count - 2]) else { return nil }
        return id
    }
}
