import Foundation
import MediaKit

/// The seam between the app's view model and the shared data layer.
///
/// `MediaItem` stays what the UI binds to — one flat value with a poster URL
/// and a title — while MediaKit owns identity and facts. Nothing in the app is
/// rewritten to snapshots yet: this file is the whole migration surface, so
/// each provider that moves into MediaKit lands here first and the views
/// don't notice.
public extension MediaItem {
    /// The app's `"movie-603"` id, in the layer's terms.
    var identity: MediaIdentity {
        MediaIdentity(type == .movie ? .tmdbMovie(tmdbId) : .tmdbSeries(tmdbId))
    }

    /// Build a card from whatever the layer managed to gather. Returns nil
    /// only when the snapshot has no title at all — a card with no name is
    /// not a card.
    init?(_ snapshot: MediaSnapshot) {
        guard let facts = snapshot.title else { return nil }
        let type: MediaType = snapshot.identity.kind == .series ? .tv : .movie
        guard let tmdbId = snapshot.identity.tmdbID else { return nil }
        let tmdbScore = snapshot.ratings?.scores.first { $0.service == .tmdb }
        self.init(tmdbId: tmdbId,
                  type: type,
                  title: facts.title,
                  year: facts.year,
                  // MediaKit deals in resolved URLs; MediaItem still carries
                  // TMDB's bare paths because every view builds sized URLs
                  // through `TMDBClient.imageURL`. Path extraction keeps the
                  // two honest until artwork moves over wholesale.
                  posterPath: Self.tmdbPath(snapshot.artwork?.poster),
                  backdropPath: Self.tmdbPath(snapshot.artwork?.backdrop),
                  rating: tmdbScore?.value,
                  voteCount: tmdbScore?.voteCount,
                  overview: facts.overview)
    }

    /// "https://image.tmdb.org/t/p/w500/abc.jpg" → "/abc.jpg".
    private static func tmdbPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        let last = url.lastPathComponent
        return last.isEmpty ? nil : "/\(last)"
    }
}

public extension MediaIdentity {
    /// The app's id string (`"movie-603"`), when this identity carries a TMDB
    /// id. Lets existing SwiftData rows and navigation values round-trip
    /// through the layer without a schema change.
    var tonightItemID: String? {
        guard let tmdbID else { return nil }
        return "\(kind == .series ? "tv" : "movie")-\(tmdbID)"
    }

    init?(tonightItemID: String) {
        let parts = tonightItemID.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "movie": self = .tmdbMovie(value)
        case "tv": self = .tmdbSeries(value)
        default: return nil
        }
    }
}

// MARK: - Catalog queries

public extension MediaKind {
    /// The app still speaks `MediaType`; the layer speaks `MediaKind`.
    init(_ type: MediaType) {
        self = type == .movie ? .movie : .series
    }
}

public extension DiscoverFilter {
    /// The browse filter, in the layer's terms.
    ///
    /// `libraryPresence` crosses over as a real filter rather than staying a
    /// client-side loop: the graph applies it after the library providers have
    /// spoken, which is the only place that knows the answer.
    var mediaFilter: MediaFilter {
        let presence: MediaFilter.LibraryPresence = switch libraryPresence {
        case .all: .any
        case .owned: .owned
        case .notOwned: .notOwned
        }
        return MediaFilter(
            genreIDs: genreIds,
            yearRange: yearRange,
            minRating: minRating,
            minVotes: minVotes,
            maxRuntimeMinutes: maxRuntime,
            streamingProviderIDs: providerIds,
            originalLanguage: language,
            presence: presence)
    }

    private var yearRange: ClosedRange<Int>? {
        switch (startYear, endYear) {
        case (let start?, let end?): min(start, end)...max(start, end)
        // An open end is still a range to TMDB — clamp it to something no
        // release predates / postdates rather than dropping the filter.
        case (let start?, nil): start...2100
        case (nil, let end?): 1870...end
        case (nil, nil): nil
        }
    }

    var mediaSort: MediaSort {
        switch sort {
        case .popularity: .popularity
        case .rating: .rating
        case .newest: .newest
        case .votes: .mostVoted
        }
    }

    /// The whole browse as one query.
    func catalogQuery(page: Int, region: String) -> MediaCatalogQuery {
        MediaCatalogQuery(.discover,
                          kind: MediaKind(type),
                          filter: mediaFilter,
                          sort: mediaSort,
                          page: page,
                          region: region)
    }
}
