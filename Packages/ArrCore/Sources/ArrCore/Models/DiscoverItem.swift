import Foundation

public enum DiscoverAction: Equatable, Sendable {
    /// Card represents a movie not in Radarr. Swipe-right opens the
    /// existing SearchAddPanel overlay.
    case addToRadarr
    /// Card represents a movie already in Radarr. Swipe-right opens
    /// DetailView via the existing DetailRequest pipeline.
    case openDetail(arrId: Int)
}

public struct DiscoverItem: Identifiable, Equatable, Sendable {
    public let result: SearchResult
    public let action: DiscoverAction
    /// Source label for the bottom-of-card chip ("From TMDB" / "From your
    /// library" / "From AI").
    public let originLabel: Origin

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

    public init(result: SearchResult, action: DiscoverAction, originLabel: Origin = .tmdb) {
        self.result = result
        self.action = action
        self.originLabel = originLabel
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

public struct DiscoverFilter: Equatable, Sendable {
    public var decade: DiscoverDecade
    public var monitoredOnly: Bool
    public init(decade: DiscoverDecade = .any, monitoredOnly: Bool = false) {
        self.decade = decade
        self.monitoredOnly = monitoredOnly
    }
    public func matches(year: Int?, monitored: Bool?) -> Bool {
        if let range = decade.range {
            guard let y = year, range.contains(y) else { return false }
        }
        if monitoredOnly {
            guard monitored == true else { return false }
        }
        return true
    }
}
