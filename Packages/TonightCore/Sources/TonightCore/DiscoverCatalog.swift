import Foundation

// MARK: - Decades

/// One decade of releases. The Discover page draws a row of these and each
/// one opens the regular browse grid pinned to its years, so a decade is a
/// browse page like any other rather than a section of its own.
public struct Decade: Identifiable, Hashable, Sendable {
    public let start: Int

    public var id: Int { start }
    public var years: ClosedRange<Int> { start...(start + 9) }
    /// "1980s" — the same shape the award year chips have always used.
    public var displayName: String { "\(start)s" }

    public init(start: Int) { self.start = start }
}

public enum Decades {
    /// Newest first, from the decade we are in back to the 1950s. Earlier
    /// than that TMDB has too little with a poster on it to fill a grid.
    public static var all: [Decade] {
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        return stride(from: now / 10 * 10, through: 1950, by: -10).map(Decade.init(start:))
    }

    /// The decades as navigation values for one kind — what the Discover row
    /// is made of.
    public static func refs(for type: MediaType) -> [DecadeRef] {
        all.map { DecadeRef(start: $0.start, type: type) }
    }
}

// MARK: - Navigation values

/// Where a Discover tile leads. Each of these is a `navigationDestination`
/// registered by `RootView`; all four resolve to a library view — the same
/// grid/table the Movies and Series sections draw.

/// One genre's browse page.
public struct GenreRef: Identifiable, Hashable, Sendable {
    public let id: Int
    public let type: MediaType
    public init(id: Int, type: MediaType) {
        self.id = id
        self.type = type
    }
    public var displayName: String { Genres.displayName(for: id, type: type) }
}

/// One decade's browse page.
public struct DecadeRef: Identifiable, Hashable, Sendable {
    public let start: Int
    public let type: MediaType
    public var id: Int { start }
    public init(start: Int, type: MediaType) {
        self.start = start
        self.type = type
    }
    public var decade: Decade { Decade(start: start) }
    public var displayName: String { decade.displayName }
}

/// One award's winners page.
public struct AwardRef: Hashable, Sendable {
    public let awardId: String
    public init(awardId: String) { self.awardId = awardId }
    public var award: Award? { Awards.award(id: awardId) }
}
