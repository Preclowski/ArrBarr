import Foundation

/// Whether a Discover card represents a movie or a TV show.
public enum DiscoverItemKind: String, Equatable, Sendable {
    case movie, show
}

/// The user's media-type selection in the Discover picker.
public enum DiscoverMediaSelection: String, CaseIterable, Identifiable, Sendable {
    case movie, show

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .movie: return "Movies"
        case .show:  return "Shows"
        }
    }
}

public enum DiscoverAction: Equatable, Sendable {
    /// Card represents a movie not in Radarr. Swipe-right opens the
    /// existing SearchAddPanel overlay.
    case addToRadarr
    /// Card represents a show not in Sonarr. Swipe-right opens the
    /// existing SearchAddPanel overlay (with source: .sonarr).
    case addToSonarr
    /// Card represents a title already in the library. Swipe-right opens
    /// DetailView via the existing DetailRequest pipeline.
    case openDetail(source: QueueItem.Source, arrId: Int)
}

public struct DiscoverItem: Identifiable, Equatable, Sendable {
    public let result: SearchResult
    public let action: DiscoverAction
    /// Source label for the bottom-of-card chip ("From TMDB" / "From your
    /// library" / "From AI").
    public let originLabel: Origin
    /// Whether this card represents a movie or a TV show.
    public let kind: DiscoverItemKind

    public enum Origin: String, Sendable {
        case tmdb, library, llm
    }

    public var id: String { dedupKey }

    /// Stable identity across sources. Prefer the TMDB id (foreignId)
    /// when present so a TMDB-source card and an LLM-source card for the
    /// same movie collide.
    public var dedupKey: String {
        if !result.foreignId.isEmpty {
            return "tmdb:\(result.foreignId)"
        }
        let title = result.title.lowercased()
        let year = result.year.map(String.init) ?? "?"
        return "title:\(title)|\(year)"
    }

    public init(result: SearchResult, action: DiscoverAction,
                originLabel: Origin = .tmdb, kind: DiscoverItemKind = .movie) {
        self.result = result
        self.action = action
        self.originLabel = originLabel
        self.kind = kind
    }
}

public enum DiscoverStatus: String, CaseIterable, Identifiable, Sendable {
    case any         = "Any status"
    case owned       = "Owned"
    case toDownload  = "To download"
    public var id: String { rawValue }
}

/// Standard TMDB movie genre catalog. Hardcoded because TMDB's
/// /genre/movie/list rarely changes and adding a separate network
/// fetch just for the picker is overkill.
public enum DiscoverGenre: Int, CaseIterable, Identifiable, Sendable {
    case action = 28, adventure = 12, animation = 16, comedy = 35
    case crime = 80, documentary = 99, drama = 18, family = 10751
    case fantasy = 14, history = 36, horror = 27, music = 10402
    case mystery = 9648, romance = 10749, scienceFiction = 878
    case tvMovie = 10770, thriller = 53, war = 10752, western = 37

    public var id: Int { rawValue }
    public var displayName: String {
        switch self {
        case .action: return "Action"
        case .adventure: return "Adventure"
        case .animation: return "Animation"
        case .comedy: return "Comedy"
        case .crime: return "Crime"
        case .documentary: return "Documentary"
        case .drama: return "Drama"
        case .family: return "Family"
        case .fantasy: return "Fantasy"
        case .history: return "History"
        case .horror: return "Horror"
        case .music: return "Music"
        case .mystery: return "Mystery"
        case .romance: return "Romance"
        case .scienceFiction: return "Science Fiction"
        case .tvMovie: return "TV Movie"
        case .thriller: return "Thriller"
        case .war: return "War"
        case .western: return "Western"
        }
    }
    /// Match a Radarr genre string (case-insensitive). Used by the
    /// library source to filter records whose `genres: [String]` array
    /// contains any of the selected genre names.
    public static func from(name: String) -> DiscoverGenre? {
        let n = name.lowercased()
        return Self.allCases.first { $0.displayName.lowercased() == n }
    }
}

public enum DiscoverDecade: String, CaseIterable, Identifiable, Sendable {
    case any        = "Any"
    case eighties   = "1980s"
    case nineties   = "1990s"
    case twoThousands = "2000s"
    case twoThousandTens = "2010s"
    case twoThousandTwenties = "2020s"
    public var id: String { rawValue }
    /// `nil` for `.any`, otherwise the inclusive [start, end] decade range.
    public var range: ClosedRange<Int>? {
        switch self {
        case .any: return nil
        case .eighties: return 1980...1989
        case .nineties: return 1990...1999
        case .twoThousands: return 2000...2009
        case .twoThousandTens: return 2010...2019
        case .twoThousandTwenties: return 2020...2029
        }
    }
}

public enum DiscoverRatingTier: String, CaseIterable, Identifiable, Sendable {
    case any
    case highlyRated      // vote_average >= 7.5
    case cultFavorite     // vote_count  >= 500

    public var id: String { rawValue }
    public var minRating: Double? {
        self == .highlyRated ? 7.5 : nil
    }
    public var minVoteCount: Int? {
        self == .cultFavorite ? 500 : nil
    }
}

public enum DiscoverRuntime: String, CaseIterable, Identifiable, Sendable {
    case any
    case short          // runtime < 90 minutes
    case epic           // runtime > 150 minutes

    public var id: String { rawValue }
    public var lessThan: Int? { self == .short ? 90 : nil }
    public var greaterThan: Int? { self == .epic ? 150 : nil }
}

public struct DiscoverFilter: Equatable, Sendable {
    public var decade: DiscoverDecade
    public var monitoredOnly: Bool          // legacy — keep for back-compat in tests
    public var genres: Set<DiscoverGenre>
    public var status: DiscoverStatus
    public var rating: DiscoverRatingTier
    public var runtime: DiscoverRuntime
    /// TMDB person ids extracted from LLM mood text (actors, directors).
    /// Passed as `with_people` to TMDB Discover — server-side filter only;
    /// ignored in local library matches.
    public var personIds: [Int]

    public init(decade: DiscoverDecade = .any,
                monitoredOnly: Bool = false,
                genres: Set<DiscoverGenre> = [],
                status: DiscoverStatus = .any,
                rating: DiscoverRatingTier = .any,
                runtime: DiscoverRuntime = .any,
                personIds: [Int] = []) {
        self.decade = decade
        self.monitoredOnly = monitoredOnly
        self.genres = genres
        self.status = status
        self.rating = rating
        self.runtime = runtime
        self.personIds = personIds
    }

    /// Old `matches(year:monitored:)` — thin wrapper for back-compat.
    public func matches(year: Int?, monitored: Bool?) -> Bool {
        matches(year: year, monitored: monitored, hasFile: nil, genres: nil)
    }

    public func matches(year: Int?, monitored: Bool?,
                        hasFile: Bool?, genres recordGenres: [String]?) -> Bool {
        if let range = decade.range {
            guard let y = year, range.contains(y) else { return false }
        }
        if monitoredOnly {
            guard monitored == true else { return false }
        }
        switch status {
        case .any: break
        case .owned:      if hasFile != true { return false }
        case .toDownload: if hasFile == true || monitored != true { return false }
        }
        if !genres.isEmpty {
            let names = Set((recordGenres ?? []).map { $0.lowercased() })
            let wanted = Set(genres.map { $0.displayName.lowercased() })
            if names.intersection(wanted).isEmpty { return false }
        }
        return true
    }

    /// Richer overload that also filters by runtime (minutes).
    /// Rating is handled at the TMDB source level, not here.
    public func matches(year: Int?, monitored: Bool?, hasFile: Bool?,
                        genres recordGenres: [String]?, runtime recordRuntime: Int?) -> Bool {
        if !matches(year: year, monitored: monitored, hasFile: hasFile, genres: recordGenres) {
            return false
        }
        if let lt = runtime.lessThan, let r = recordRuntime, r >= lt { return false }
        if let gt = runtime.greaterThan, let r = recordRuntime, r <= gt { return false }
        return true
    }
}
