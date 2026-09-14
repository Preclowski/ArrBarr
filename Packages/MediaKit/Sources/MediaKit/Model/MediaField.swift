import Foundation

/// What a caller wants to know. The whole point of the layer: ask for fields,
/// not for endpoints, and let the planner pick who answers.
///
/// Deliberately a CLOSED option set rather than a query language. A real
/// GraphQL-style projection would buy nothing here — there is no third-party
/// client to serve — and would cost a schema, a parser and a planner nobody
/// can debug at 1am. Adding a field is a one-line change here plus one
/// provider that claims it.
public struct MediaFieldSet: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Title, year, overview, runtime, genres — the identity card.
    public static let title = MediaFieldSet(rawValue: 1 << 0)
    /// Poster / backdrop references.
    public static let artwork = MediaFieldSet(rawValue: 1 << 1)
    /// Scores, per service, each naming its source.
    public static let ratings = MediaFieldSet(rawValue: 1 << 2)
    /// Owned / watched / play position — the user's own media world.
    public static let availability = MediaFieldSet(rawValue: 1 << 3)
    /// Cast and crew.
    public static let credits = MediaFieldSet(rawValue: 1 << 4)
    /// Where it streams, in the user's region.
    public static let streaming = MediaFieldSet(rawValue: 1 << 5)

    public static let all: MediaFieldSet = [
        .title, .artwork, .ratings, .availability, .credits, .streaming,
    ]

    /// What a poster card actually needs — the cheapest useful request, and
    /// the one a grid of 100 makes.
    public static let card: MediaFieldSet = [.title, .artwork, .ratings, .availability]

    /// Individual fields, for per-field bookkeeping (provenance, failures,
    /// cache policy, telemetry).
    public var fields: [MediaField] {
        MediaField.allCases.filter { contains($0.set) }
    }
}

/// One field, as a value — the key type for everything that reports per field.
public enum MediaField: String, Hashable, Sendable, CaseIterable, Codable {
    case title, artwork, ratings, availability, credits, streaming

    public var set: MediaFieldSet {
        switch self {
        case .title: .title
        case .artwork: .artwork
        case .ratings: .ratings
        case .availability: .availability
        case .credits: .credits
        case .streaming: .streaming
        }
    }

    /// How fast this field goes stale. The cache reads policy off this rather
    /// than off the call site, so two screens asking for the same field can't
    /// disagree about how old an answer may be.
    public var freshnessClass: FreshnessClass {
        switch self {
        case .artwork, .credits: .immutable
        case .title, .ratings, .streaming: .slow
        case .availability: .volatile
        }
    }
}

/// Cache classes, named for what they describe rather than for a duration.
public enum FreshnessClass: String, Hashable, Sendable, Codable {
    /// Effectively frozen once known — artwork paths, credits. Disk, months.
    case immutable
    /// Changes on human timescales — titles, scores, streaming windows.
    /// Disk, hours, served stale while revalidating.
    case slow
    /// Changes while you watch it — play state, queue progress. Memory only,
    /// seconds, never written to disk.
    case volatile

    public var defaultTTL: TimeInterval {
        switch self {
        case .immutable: 60 * 60 * 24 * 30
        case .slow: 60 * 60 * 6
        case .volatile: 30
        }
    }
}
