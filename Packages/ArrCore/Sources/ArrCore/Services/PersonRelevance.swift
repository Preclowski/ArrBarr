import Foundation

/// Ranks TMDB people for a text query — the "which person did they mean"
/// decision, kept apart from `SearchRelevance` (which scores title matches;
/// the two scales aren't comparable, which is why person results live in their
/// own section rather than interleaved with titles).
///
/// Score = how much of the query the name covers (order-free, punctuation
/// folded — reusing `SearchRelevance.normalize`) weighted by the person's TMDB
/// popularity, with a nudge for actors over crew.
enum PersonRelevance {
    static func score(person: TMDBPerson, normalizedQuery q: String) -> Double {
        let name = SearchRelevance.normalize(person.name)
        let qTokens = q.split(separator: " ").map(String.init)
        guard !qTokens.isEmpty else { return 0 }
        let nTokens = name.split(separator: " ").map(String.init)
        guard !nTokens.isEmpty else { return 0 }

        let matched = qTokens.filter { qt in nTokens.contains { $0 == qt || $0.hasPrefix(qt) } }.count
        let coverage = Double(matched) / Double(qTokens.count)
        guard coverage > 0 else { return 0 }

        var s = coverage * 100 + log(1 + (person.popularity ?? 0))
        if name == q { s += 50 }                                  // exact full-name match
        if person.knownForDepartment == "Acting" { s += 5 }
        return s
    }

    /// People sorted best-first, dropping non-matches.
    static func rank(_ people: [TMDBPerson], query: String) -> [TMDBPerson] {
        let q = SearchRelevance.normalize(query)
        return people
            .map { ($0, score(person: $0, normalizedQuery: q)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// Whether `person` is a confident enough match to headline a "Starring X"
    /// section in an all-scope search: every query token covered by the name,
    /// a real (not incidental-namesake) popularity, and a query long enough to
    /// mean it. Deliberately conservative — "Alien" must not surface a person.
    static func isConfidentHeadliner(_ person: TMDBPerson, query: String) -> Bool {
        let q = SearchRelevance.normalize(query)
        // ≥4 chars keeps common short words ("tom", "the") from headlining a
        // whole Starring section; ≥8 popularity keeps incidental namesakes out.
        guard q.count >= 4 else { return false }
        let qTokens = q.split(separator: " ").map(String.init)
        let nTokens = SearchRelevance.normalize(person.name).split(separator: " ").map(String.init)
        guard !qTokens.isEmpty, !nTokens.isEmpty else { return false }
        let allMatched = qTokens.allSatisfy { qt in nTokens.contains { $0.hasPrefix(qt) } }
        return allMatched && (person.popularity ?? 0) >= 8
    }

    /// Whether the query reads as somebody's **full name** — at least two
    /// tokens, every one of them covering a distinct token of the name.
    ///
    /// This is the unambiguous case, so it carries no popularity floor and no
    /// filmography requirement: "rhea seehorn" can only mean the person, and a
    /// TV-only actor with a thin movie list is still exactly who was asked
    /// for. `isConfidentHeadliner` keeps guarding the ambiguous single-token
    /// queries, where a popularity floor is what stops "alien" or "hanks" from
    /// dragging a namesake into a title search.
    static func isFullNameMatch(_ person: TMDBPerson, query: String) -> Bool {
        let qTokens = SearchRelevance.normalize(query).split(separator: " ").map(String.init)
        guard qTokens.count >= 2 else { return false }
        var remaining = SearchRelevance.normalize(person.name).split(separator: " ").map(String.init)
        guard remaining.count >= qTokens.count else { return false }
        for qt in qTokens {
            guard let hit = remaining.firstIndex(where: { $0.hasPrefix(qt) }) else { return false }
            remaining.remove(at: hit)
        }
        return true
    }
}
