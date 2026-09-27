import Foundation

nonisolated public enum DiscoverItemKind: String, Equatable, Sendable {
    case movie, show
}

nonisolated public enum DiscoverMediaSelection: String, CaseIterable, Identifiable, Sendable {
    case movie, show

    public var id: String { rawValue }
}

nonisolated public struct DiscoverItem: Identifiable, Equatable, Sendable {
    public let result: SearchResult
    public let kind: DiscoverItemKind
    /// Why this card is in the deck ("Because you kept Sicario"); nil is fine.
    public let reason: String?

    public var id: String { dedupKey }

    /// Prefers the TMDB id so TMDB- and LLM-sourced cards for one movie collide.
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
