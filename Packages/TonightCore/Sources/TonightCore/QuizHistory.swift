import Foundation
import SwiftData

/// One Quiz verdict: a card the user swiped, and which way. Written on every
/// swipe and removed again by undo. Nothing reads it yet — it is the record
/// a taste-driven feed will learn from later.
@Model
public final class QuizVerdict {
    /// "movie-603" — matches `MediaItem.id`.
    public var key: String
    public var tmdbId: Int
    public var typeRaw: String
    public var title: String
    public var year: Int?
    public var posterPath: String?
    public var backdropPath: String?
    public var rating: Double?
    public var voteCount: Int?
    public var overview: String?
    public var genreIds: [Int] = []
    public var liked: Bool
    public var decidedAt: Date

    public init(item: MediaItem, liked: Bool, decidedAt: Date = .now) {
        self.key = item.id
        self.tmdbId = item.tmdbId
        self.typeRaw = item.type.rawValue
        self.title = item.title
        self.year = item.year
        self.posterPath = item.posterPath
        self.backdropPath = item.backdropPath
        self.rating = item.rating
        self.voteCount = item.voteCount
        self.overview = item.overview
        self.genreIds = item.genreIds
        self.liked = liked
        self.decidedAt = decidedAt
    }

    public var mediaType: MediaType { MediaType(rawValue: typeRaw) ?? .movie }

    public var mediaItem: MediaItem {
        MediaItem(tmdbId: tmdbId, type: mediaType, title: title, year: year,
                  posterPath: posterPath, backdropPath: backdropPath,
                  rating: rating, voteCount: voteCount, overview: overview,
                  genreIds: genreIds)
    }
}

public extension QuizVerdict {
    /// Append a verdict for a swipe.
    static func log(_ item: MediaItem, liked: Bool, in context: ModelContext) {
        context.insert(QuizVerdict(item: item, liked: liked))
        try? context.save()
    }

    /// Drop the newest verdict for a title — the undo counterpart of `log`.
    static func undoLast(_ item: MediaItem, in context: ModelContext) {
        let key = item.id
        var descriptor = FetchDescriptor<QuizVerdict>(
            predicate: #Predicate { $0.key == key },
            sortBy: [SortDescriptor(\.decidedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = try? context.fetch(descriptor).first else { return }
        context.delete(last)
        try? context.save()
    }
}
