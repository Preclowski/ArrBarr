import Foundation
import MediaKit

nonisolated public protocol TMDBPersonCredit {
    var id: Int { get }
    var department: String? { get }
    var popularity: Double? { get }
    var year: Int? { get }
}
extension TMDBMovieSummary: TMDBPersonCredit {}
extension TMDBTVSummary: TMDBPersonCredit {}

/// TMDB lists a title once per credit ("104 × The Simpsons"), which also breaks ForEach identity.
/// Crew counts only for Directing and Writing; producer credits would balloon the list.
nonisolated enum PersonCreditMerge {
    private enum Role: Int, CaseIterable {
        case actor, director, writer
        var label: String {
            switch self {
            case .actor: return String(localized: "person.role.actor", bundle: .module)
            case .director: return String(localized: "person.role.director", bundle: .module)
            case .writer: return String(localized: "person.role.writer", bundle: .module)
            }
        }
        init?(department: String?) {
            switch department {
            case "Directing": self = .director
            case "Writing": self = .writer
            default: return nil
            }
        }
    }

    /// First occurrence wins: TMDB lists the primary billing first.
    static func merge<T: TMDBPersonCredit>(
        cast: [T], crew: [T]
    ) -> (credits: [T], roles: [Int: String]) {
        var credits: [T] = []
        var seen = Set<Int>()
        var roles: [Int: Set<Role>] = [:]

        for entry in cast {
            roles[entry.id, default: []].insert(.actor)
            if seen.insert(entry.id).inserted { credits.append(entry) }
        }
        for entry in crew {
            guard let role = Role(department: entry.department) else { continue }
            roles[entry.id, default: []].insert(role)
            if seen.insert(entry.id).inserted { credits.append(entry) }
        }

        let lines = roles.mapValues { set in
            Role.allCases.filter(set.contains).map(\.label).joined(separator: ", ")
        }
        return (credits, lines)
    }

    /// TMDB returns credits unordered; popularity beats voteAverage, whose top entries are niche cameos.
    static func byPopularity<T: TMDBPersonCredit>(_ credits: [T]) -> [T] {
        credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0, rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
    }
}
