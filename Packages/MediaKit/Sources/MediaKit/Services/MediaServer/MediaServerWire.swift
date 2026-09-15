import Foundation

/// The slim projection row the store persists for a library; Plex's 7 MB index becomes ~500 KB of these.
public struct MediaServerIndexEntry: Sendable, Hashable, Codable {
    public let itemID: String
    public let kind: MediaKind
    public let ids: Set<MediaID>
    public let title: String
    public let year: Int?
    public let artworkPath: String?
    public let viewCount: Int
    public let lastViewedAt: Date?
    public init(itemID: String, kind: MediaKind, ids: Set<MediaID>, title: String, year: Int?, artworkPath: String?, viewCount: Int, lastViewedAt: Date?) {
        self.itemID = itemID; self.kind = kind; self.ids = ids; self.title = title; self.year = year; self.artworkPath = artworkPath; self.viewCount = viewCount; self.lastViewedAt = lastViewedAt
    }
}

public struct MediaServerLibrary: Sendable, Hashable, Codable {
    public let key: String
    public let title: String
    public let kind: MediaKind?
}

public struct MediaServerSession: Sendable, Hashable, Codable, LivePatchable {
    public let itemID: String
    public let title: String
    public let user: String?
    public let progress: Double?
    public let state: String
    public let kind: MediaKind?
    public let parentTitle: String?
    public func applying(_ change: PendingEffect.Change) -> MediaServerSession? { nil }
}

public struct MediaServerHistoryRow: Sendable, Hashable, Codable {
    public let itemID: String
    public let ids: Set<MediaID>
    public let kind: MediaKind
    public let title: String
    public let viewedAt: Date
}

public struct MediaServerIdentity: Sendable, Hashable, Codable {
    public let version: String?
    public let name: String?
    public let identifier: String?
}

public struct MediaServerUser: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
}

// Plex shapes (`MediaContainer` envelopes).

struct PlexContainer<Item: Decodable>: Decodable {
    struct Body: Decodable { let Metadata: [Item]?; let Directory: [Item]?; let version: String?; let machineIdentifier: String?; let friendlyName: String? }
    let MediaContainer: Body
}

struct PlexDirectory: Decodable { let key: String; let title: String; let type: String? }

struct PlexMetadata: Decodable {
    struct Guid: Decodable { let id: String }
    let ratingKey: String?
    let title: String?
    let type: String?
    let year: Int?
    let thumb: String?
    let viewCount: Int?
    let lastViewedAt: Int?
    let viewedAt: Int?
    let viewOffset: Int?
    let duration: Int?
    let grandparentTitle: String?
    let grandparentThumb: String?
    let Guid: [Guid]?
    /// Anonymised recordings replace these objects with scalars; read them loosely.
    let User: JSONValue?
    let Player: JSONValue?
}

// Jellyfin / Emby shapes (PascalCase).

struct JellyfinItems: Decodable { let Items: [JellyfinItem] }

struct JellyfinItem: Decodable {
    struct UserData: Decodable { let PlayCount: Int?; let LastPlayedDate: String?; let Played: Bool? }
    let Id: String
    let Name: String?
    let itemType: String?
    let ProductionYear: Int?
    let ProviderIds: [String: String]?
    let ImageTags: [String: String]?
    let UserData: UserData?
    let SeriesName: String?
    enum CodingKeys: String, CodingKey { case Id, Name, itemType = "Type", ProductionYear, ProviderIds, ImageTags, UserData, SeriesName }
}

struct JellyfinSession: Decodable {
    struct PlayState: Decodable { let PositionTicks: Int64?; let IsPaused: Bool? }
    let UserName: String?
    let NowPlayingItem: NowPlaying?
    let PlayState: PlayState?
    struct NowPlaying: Decodable {
        let Id: String; let Name: String?; let itemType: String?; let RunTimeTicks: Int64?; let SeriesName: String?
        enum CodingKeys: String, CodingKey { case Id, Name, itemType = "Type", RunTimeTicks, SeriesName }
    }
}

struct JellyfinFolder: Decodable { let Name: String; let ItemId: String?; let CollectionType: String? }
struct JellyfinInfo: Decodable { let Version: String?; let ServerName: String?; let Id: String? }
struct JellyfinUser: Decodable { let Id: String; let Name: String }
