import Foundation

/// Whether a Discover card represents a movie or a TV show.
nonisolated public enum DiscoverItemKind: String, Equatable, Sendable {
    case movie, show
}

/// The user's media-type selection in the Discover picker.
nonisolated public enum DiscoverMediaSelection: String, CaseIterable, Identifiable, Sendable {
    case movie, show

    public var id: String { rawValue }
}

nonisolated public struct DiscoverItem: Identifiable, Equatable, Sendable {
    public let result: SearchResult
    /// Whether this card represents a movie or a TV show.
    public let kind: DiscoverItemKind
    /// One short, user-facing line saying WHY this card is in the deck
    /// ("Because you kept Sicario", "Top-rated on your shelf"). Rendered on
    /// the card when present; absence needs no explanation, so nil is fine.
    public let reason: String?

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

    public init(result: SearchResult, kind: DiscoverItemKind = .movie,
                reason: String? = nil) {
        self.result = result
        self.kind = kind
        self.reason = reason
    }
}
