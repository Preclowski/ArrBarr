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
/// One sort, no menu — search is keyword lookup against titles, not a
/// discovery surface. The Discover tab is where listing-style filters
/// (newest / highest-rated / by-genre) live; here every query has a
/// definite intent, and the right answer is "best title match,
/// quality-broken ties".
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
/// **Tie-breaker** inside a band: Bayesian-adjusted rating
/// ("IMDB Top 250" style), which shrinks low-vote ratings toward
/// the global mean so a 9.9-rated film with 5 votes doesn't outrank
/// an 8.0 film with 20 000. See `bayesianQuality` for the formula
/// and `m` / `C` constants. Sources that don't surface vote counts
/// (Sonarr / Lidarr / Whisparr) fall back to the raw `rating` — TVDB
/// / MusicBrainz scores are already aggregated upstream, so the
/// shrinkage isn't needed there.
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

    /// Asymmetric Bayesian-adjusted rating. Only shrinks **high**
    /// ratings toward the global mean — never lifts low ones up.
    ///
    ///     if R > C:  adjusted = (v / (v + m)) · R + (m / (v + m)) · C
    ///     else:      adjusted = R
    ///
    /// The naïve symmetric formula was rewarding bad films: a 0.0
    /// rating with a handful of votes got pulled up to ~6.5 (the
    /// global mean), which let "American Pie (1972)" — an unrated
    /// early short with the same title prefix — ride to second place
    /// behind the 1999 film. Shrinkage exists to protect against
    /// HIGH-rated low-vote outliers ("9.9 with 5 votes"); applying
    /// it both ways defeats the point.
    ///
    /// `m` = 500 (votes threshold), `C` = 6.5 (global mean). Examples:
    ///   - 9.9 / 5      → 6.53  (pulled down, was a low-trust outlier)
    ///   - 8.0 / 20_000 → 7.96  (barely moves, plenty of data)
    ///   - 7.0 / 1_000  → 6.83  (modest pull, still respected)
    ///   - 0.0 / 5      → 0.0   (no rescue from the mean)
    ///   - 5.5 / 20_000 → 5.5   (below mean, left alone)
    ///
    /// Sources without vote counts (Sonarr / Lidarr / Whisparr) skip
    /// the shrinkage and return the raw rating — those scores are
    /// already aggregated upstream (TVDB / MusicBrainz).
    static func bayesianQuality(_ result: SearchResult) -> Double {
        let R = result.rating ?? 0
        let C: Double = 6.5
        guard let votes = result.votes, votes > 0, R > C else { return R }
        let v = Double(votes)
        let m: Double = 500
        return (v / (v + m)) * R + (m / (v + m)) * C
    }

    /// Quality weight inside a tier band. Multiplies the 0…10
    /// quality range by 10 so it can outweigh small title-length
    /// differences in the prefix/word-prefix bands. Without the
    /// weight, a 0.0-rated film with a 1-char-shorter title beats a
    /// 6.7-rated film in the same band (title penalty = 1 pt/char,
    /// quality span = only 10 pt total). With ×10, a 1-point quality
    /// advantage = a 10-char title-length advantage — quality wins
    /// for any reasonable disagreement.
    ///
    /// Still capped well below the 1 000-step gap between tiers, so
    /// a strong quality boost can't lift a substring match over a
    /// prefix match — band order is preserved.
    private static let qualityWeight: Double = 10

    /// Combined sort key — higher is better. Tier-band integer
    /// dominates; weighted bayesianQuality (0…100) breaks ties inside
    /// a band and outweighs minor title-length differences.
    static func rank(_ result: SearchResult, normalizedQuery q: String) -> Double {
        Double(score(result, normalizedQuery: q))
            + bayesianQuality(result) * qualityWeight
    }

    /// Sort + cross-source merge in one pass. Caller hands in the raw
    /// per-source flatMap; we sort by relevance to the query, with
    /// Bayesian-adjusted rating as the in-tier tie-breaker. Stable
    /// w.r.t. equal-rank ties via Swift 5+'s stable `sorted(by:)`.
    static func sortedByRelevance(_ results: [SearchResult], query: String) -> [SearchResult] {
        let q = normalize(query)
        guard !q.isEmpty else { return results }
        return results.sorted { lhs, rhs in
            rank(lhs, normalizedQuery: q) > rank(rhs, normalizedQuery: q)
        }
    }
}
