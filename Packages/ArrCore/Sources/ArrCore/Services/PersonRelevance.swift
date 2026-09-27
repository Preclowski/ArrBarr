import Foundation
import MediaKit

/// Kept apart from `SearchRelevance`: the two scales aren't comparable, so people get their own section.
/// Score = query coverage of the name weighted by TMDB popularity, nudged for actors and directors.
nonisolated enum PersonRelevance {
    static func score(person: TMDBPerson, normalizedQuery q: String) -> Double {
        let name = TitleMatch.fold(person.name)
        let qTokens = q.split(separator: " ").map(String.init)
        guard !qTokens.isEmpty else { return 0 }
        let nTokens = name.split(separator: " ").map(String.init)
        guard !nTokens.isEmpty else { return 0 }

        let matched = qTokens.filter { qt in nTokens.contains { $0 == qt || $0.hasPrefix(qt) } }.count
        let coverage = Double(matched) / Double(qTokens.count)
        guard coverage > 0 else { return 0 }

        var s = coverage * 100 + log(1 + (person.popularity ?? 0))
        if name == q { s += 50 }
        // Actor and director rank equally: "villeneuve" should reach Denis Villeneuve as directly as "hanks" Tom Hanks.
        if person.knownForDepartment == TMDBDepartment.acting || person.isDirector { s += 5 }
        return s
    }

    static func rank(_ people: [TMDBPerson], query: String) -> [TMDBPerson] {
        let q = TitleMatch.fold(query)
        return people
            .map { ($0, score(person: $0, normalizedQuery: q)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// Deliberately conservative — "Alien" must not surface a person.
    static func isConfidentHeadliner(_ person: TMDBPerson, query: String) -> Bool {
        let q = TitleMatch.fold(query)
        // ≥4 chars keeps short words ("tom", "the") from headlining; ≥8 popularity keeps incidental namesakes out.
        guard q.count >= 4 else { return false }
        let qTokens = q.split(separator: " ").map(String.init)
        let nTokens = TitleMatch.fold(person.name).split(separator: " ").map(String.init)
        guard !qTokens.isEmpty, !nTokens.isEmpty else { return false }
        let allMatched = qTokens.allSatisfy { qt in nTokens.contains { $0.hasPrefix(qt) } }
        return allMatched && (person.popularity ?? 0) >= 8
    }

    /// At least two tokens, each covering a distinct name token. Unambiguous, so no popularity floor:
    /// "rhea seehorn" can only mean the person.
    static func isFullNameMatch(_ person: TMDBPerson, query: String) -> Bool {
        let qTokens = TitleMatch.fold(query).split(separator: " ").map(String.init)
        guard qTokens.count >= 2 else { return false }
        var remaining = TitleMatch.fold(person.name).split(separator: " ").map(String.init)
        guard remaining.count >= qTokens.count else { return false }
        for qt in qTokens {
            guard let hit = remaining.firstIndex(where: { $0.hasPrefix(qt) }) else { return false }
            remaining.remove(at: hit)
        }
        return true
    }
}

nonisolated public extension TMDBPerson {
    /// "Starring X" reads wrong for someone who directed the titles.
    var filmographyCaptionKey: String {
        isDirector ? "search.directedBy" : "search.starring"
    }
}
