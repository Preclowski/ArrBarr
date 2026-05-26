import Foundation

/// Prefix-aware relevance scoring for search results. Replaces the
/// previous "trust whatever order the arr's /lookup endpoint returned"
/// behaviour, which had two visible failure modes:
///
///   - **Cross-arr ordering was alphabetical-by-enum.** When Radarr
///     and Sonarr both matched a query, Radarr always came first
///     because `QueueItem.Source.allCases` lists `.radarr` before
///     `.sonarr`. A strong Sonarr match would still sit under a
///     marginal Radarr one.
///   - **No client-side score.** A user typing "Audi" got results in
///     the arr's lookup order — usually fine for popular titles but
///     unpredictable for niche or partial matches.
///
/// We score each result against the typed query, then sort the
/// combined library/new lists by that score. Same scoring drives
/// both per-group ordering AND the cross-source merge so the
/// behaviour is consistent regardless of which result-type the
/// user is currently scoped to.
///
/// ## Scoring tiers (higher wins)
///
///   10_000 — exact title match
///    5_000+ — title prefix match (shorter titles score higher
///             within the band, so "Audi" → "Audi" beats "Audition")
///    2_000+ — any token prefix match (multi-word title; "Buck"
///             matches "Big Buck Bunny")
///    1_000+ — substring anywhere in title (earlier position wins)
///        0 — no match (filtered out before sorting in practice)
///
/// **Tie-breaker** inside a band: TMDB/primary rating + a small
/// recency bias on `year`. Without it, a 1972 release outscores a
/// 2024 one of identical title quality just because both have a 7.5
/// rating — most users searching for "Dune" expect 2021 first, not
/// 1984.
///
/// Diacritic + case insensitive throughout to match the existing
/// queue-filter behaviour ("Pożeracz" matches "pozeracz").
enum SearchRelevance {
    /// Normalize once on the caller side; folding is allocation-heavy
    /// and we'd otherwise repeat it for every result × every render.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Score a single result against a *pre-normalised* query. Returns
    /// 0 for "no match" so the caller can keep or drop based on intent
    /// (the live filter is substring-driven and shows every match;
    /// stricter call sites can filter to score > 0).
    static func score(_ result: SearchResult, normalizedQuery q: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let title = normalize(result.title)
        if title == q { return 10_000 }
        if title.hasPrefix(q) {
            // Shorter titles win the prefix band — typing "Foo" should
            // surface "Foo" before "Foo Bar Baz".
            return 5_000 - min(title.count, 999)
        }
        // Token-prefix: any whitespace-delimited word starts with q.
        // "Buck" matches "Big Buck Bunny" even though the full title
        // doesn't start with B-u-c-k. Score below the title-prefix
        // band but above plain substring so word boundaries beat
        // mid-word hits.
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
            return 2_000 - min(title.count, 999)
        }
        if let range = title.range(of: q) {
            // Earlier position in the title scores higher. Cap the
            // penalty so a 200-char title with a match at char 50
            // still beats a "no match anywhere" zero.
            let pos = title.distance(from: title.startIndex, to: range.lowerBound)
            return 1_000 - min(pos, 999)
        }
        return 0
    }

    /// Secondary signal: rating + tiny recency nudge. Returns a small
    /// Double so it can safely be added to the integer score as a
    /// continuous tie-breaker without overlapping band boundaries
    /// (max ~1 + ~0.1 ≪ the 1000-step gap between bands).
    static func tieBreaker(_ result: SearchResult) -> Double {
        let rating = (result.rating ?? 0) / 10.0           // 0…1
        let recency = max(0, Double((result.year ?? 1900) - 1900)) / 1000.0  // 0…~0.13
        return rating + recency
    }

    /// Combined sort key — higher is better. Use as a single
    /// comparable value rather than a 2-tuple to keep call sites
    /// readable (`sorted(by: { rank > rank })`).
    static func rank(_ result: SearchResult, normalizedQuery q: String) -> Double {
        Double(score(result, normalizedQuery: q)) + tieBreaker(result)
    }

    /// Sort + cross-source merge in one pass. Caller hands in the raw
    /// per-source flatMap; we sort by relevance to the query. Stable
    /// w.r.t. equal-rank ties via Swift 5+'s stable `sorted(by:)`.
    static func sortedByRelevance(_ results: [SearchResult], query: String) -> [SearchResult] {
        let q = normalize(query)
        guard !q.isEmpty else { return results }
        return results.sorted { lhs, rhs in
            rank(lhs, normalizedQuery: q) > rank(rhs, normalizedQuery: q)
        }
    }
}
