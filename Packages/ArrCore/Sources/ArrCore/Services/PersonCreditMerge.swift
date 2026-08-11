import Foundation

/// A person credit entry as the merge cares about it — both TMDB summary
/// types (movie / tv) qualify.
public protocol TMDBPersonCredit {
    var id: Int { get }
    var department: String? { get }
    var popularity: Double? { get }
    var year: Int? { get }
}
extension TMDBMovieSummary: TMDBPersonCredit {}
extension TMDBTVSummary: TMDBPersonCredit {}

/// Collapses a TMDB person-credits response (cast + crew) into one unique
/// title list plus a role line per title.
///
/// TMDB lists a title once per credit — an actor with three roles, or an
/// episode-by-episode guest, repeats the same id many times ("104 × The
/// Simpsons"), and identical duplicates also poison SwiftUI's ForEach
/// identity. Cast entries read as Actor; crew entries count only when the
/// department is Directing or Writing (producer-type credits would balloon
/// the list without saying anything a media library cares about).
public enum PersonCreditMerge {
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

    /// `credits`: one entry per unique title (first occurrence wins — TMDB
    /// lists the primary billing first). `roles`: title id → "Actor, Director"
    /// style line, roles in fixed actor→director→writer order.
    public static func merge<T: TMDBPersonCredit>(
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

    /// Popularity-desc, year-desc. TMDB returns credits unordered; popularity
    /// (TMDB's "what people are searching/watching" metric) beats voteAverage,
    /// whose top entries are niche cameos with a handful of votes.
    public static func byPopularity<T: TMDBPersonCredit>(_ credits: [T]) -> [T] {
        credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0, rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
    }
}
