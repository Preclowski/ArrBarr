import Foundation
import SwiftData

/// A saved title: one row per TMDB title the user has touched (listed or
/// watched). Carries a metadata snapshot so lists render offline.
@Model
public final class SavedTitle {
    /// "movie-603" — matches `MediaItem.id`.
    @Attribute(.unique) public var key: String
    public var tmdbId: Int
    public var typeRaw: String
    public var title: String
    public var year: Int?
    public var posterPath: String?
    public var backdropPath: String?
    public var rating: Double?
    public var overview: String?
    public var addedAt: Date
    public var watchedAt: Date?
    public var lists: [WatchList]

    public init(item: MediaItem) {
        self.key = item.id
        self.tmdbId = item.tmdbId
        self.typeRaw = item.type.rawValue
        self.title = item.title
        self.year = item.year
        self.posterPath = item.posterPath
        self.backdropPath = item.backdropPath
        self.rating = item.rating
        self.overview = item.overview
        self.addedAt = .now
        self.watchedAt = nil
        self.lists = []
    }

    public var mediaType: MediaType { MediaType(rawValue: typeRaw) ?? .movie }

    public var mediaItem: MediaItem {
        MediaItem(tmdbId: tmdbId, type: mediaType, title: title, year: year,
                  posterPath: posterPath, backdropPath: backdropPath,
                  rating: rating, voteCount: nil, overview: overview)
    }
}

@Model
public final class WatchList {
    public var name: String
    public var symbol: String
    public var createdAt: Date
    @Relationship(inverse: \SavedTitle.lists) public var titles: [SavedTitle]

    public init(name: String, symbol: String = "list.and.film") {
        self.name = name
        self.symbol = symbol
        self.createdAt = .now
        self.titles = []
    }
}

public enum Library {
    /// Explicit store URL in Application Support — never the default
    /// container path, so the database survives every rebuild of an
    /// ad-hoc-signed binary.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([SavedTitle.self, WatchList.self, QuizVerdict.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try? FileManager.default.createDirectory(
                at: TonightConfig.supportDirectory, withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: TonightConfig.storeURL)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Fetch-or-create the row for a title.
    public static func savedTitle(for item: MediaItem, in context: ModelContext) -> SavedTitle {
        let key = item.id
        let predicate = #Predicate<SavedTitle> { $0.key == key }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            return existing
        }
        let fresh = SavedTitle(item: item)
        context.insert(fresh)
        return fresh
    }

    public static func existingTitle(for item: MediaItem, in context: ModelContext) -> SavedTitle? {
        let key = item.id
        let predicate = #Predicate<SavedTitle> { $0.key == key }
        return try? context.fetch(FetchDescriptor(predicate: predicate)).first
    }

    /// Drop rows that are neither listed nor watched — a toggle that ended in
    /// "off everywhere" should not leave junk behind.
    public static func pruneIfOrphaned(_ title: SavedTitle, in context: ModelContext) {
        guard title.lists.isEmpty, title.watchedAt == nil else { return }
        context.delete(title)
    }
}
