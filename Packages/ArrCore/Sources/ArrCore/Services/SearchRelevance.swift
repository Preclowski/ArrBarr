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
///    4_000+ — multi-word query where EVERY word prefixes some word of
///             the title, in any order ("buck bunny" → "Big Buck Bunny")
///    2_000+ — any token prefix match (multi-word title; "Buck"
///             matches "Big Buck Bunny")
///    1_000+ — partial multi-word coverage, weighted by how much of the
///             query (by character count) landed — so missing "the"
///             costs far less than missing "matrix"
///    1_000  — substring anywhere in title (earlier position wins)
///        0 — no match (kept, but sinks below everything that matched)
///
/// **Modifiers**, all small enough that they reorder *inside* a band and
/// can never promote a weaker kind of match:
///
///   - Bayesian-adjusted rating ("IMDB Top 250" style, 0…100), which
///     shrinks low-vote ratings toward the global mean so a 9.9-rated
///     film with 5 votes doesn't outrank an 8.0 with 20 000.
///   - `+150` when the record is already in the user's library — typing
///     the name of something you own usually means "take me to it".
///   - `+300` when the query carried a year that matches the record's.
///   - `−0…100` for the record's position in the arr's own response,
///     which is how the upstream (TMDB / TVDB) popularity ranking gets
///     a vote. Without it that signal was thrown away entirely: the
///     ranker re-sorted on a continuous score that essentially never
///     ties, so the arr's ordering could never break through.
///
/// Diacritic-, case- and punctuation-insensitive throughout, so
/// "spiderman" reaches "Spider-Man" and "pozeracz" reaches "Pożeracz".
enum SearchRelevance {
    /// Normalize once on the caller side; folding is allocation-heavy
    /// and we'd otherwise repeat it for every result × every render.
    ///
    /// Punctuation collapses to spaces rather than being deleted, so
    /// "Spider-Man" → "spider man" (two tokens) instead of "spiderman"
    /// (one). Deleting it would make "spiderman" an exact match but
    /// break the far more common "spider man"; folding to a separator
    /// serves both, because the token-coverage band reassembles them.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let separated = folded.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        return String(separated)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
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

        // Multi-word queries get order-independent coverage scoring.
        // Single-word queries deliberately fall through to the original
        // bands below: for those, "does this word start a title word"
        // IS the coverage question, and re-answering it here would just
        // relabel the same match with a different number.
        let queryTokens = q.split(separator: " ")
        if queryTokens.count > 1 {
            let titleTokens = title.split(separator: " ")
            var matchedChars = 0
            var totalChars = 0
            for qt in queryTokens {
                totalChars += qt.count
                if titleTokens.contains(where: { $0.hasPrefix(qt) }) { matchedChars += qt.count }
            }
            if totalChars > 0 {
                if matchedChars == totalChars {
                    // Every word landed, whatever the order: "bunny big"
                    // finds "Big Buck Bunny" just as "big bunny" does.
                    return 4_000 - min(title.count, 999)
                }
                if matchedChars > 0 {
                    // Weighted by characters, not word count, so dropping
                    // "the" barely dents the score while dropping "matrix"
                    // guts it. Sits above the substring band: matching two
                    // of three real words beats a mid-word letter collision.
                    let coverage = Double(matchedChars) / Double(totalChars)
                    return 1_000 + Int(900 * coverage)
                }
            }
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
    /// A source that reports no vote count keeps its raw rating. Every
    /// arr we talk to *does* report one — Sonarr's and Lidarr's were
    /// simply never decoded, which is why series ranking used to hand
    /// an obscure 10.0 the same trust as a 20 000-vote 8.0.
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

    /// Owning something is a strong statement of interest, so an
    /// in-library record edges out an equally-good stranger. Kept above
    /// the whole quality span (100) — "I have this" beats "this is
    /// rated higher" — and far below the band gap, so it can never
    /// promote a worse title match.
    private static let libraryBoost: Double = 150

    /// A year the user actually typed is a deliberate disambiguator
    /// ("dune 2024"), so it outweighs both quality and library
    /// ownership while still staying inside its band.
    private static let yearBonus: Double = 300

    /// …and a record from a DIFFERENT year is, given an explicit year,
    /// almost certainly not the one being asked for. This one is big
    /// enough to cross bands on purpose: "dune 2024" has to beat the
    /// exact-title match on "Dune" (2021), which no in-band nudge could
    /// ever manage. Records with no year at all are left alone —
    /// unknown is not the same as wrong.
    ///
    /// Only safe because `splitYear` reads the TRAILING token only, so
    /// "2001 a space odyssey" is never mistaken for a year-qualified
    /// query and demoted to nothing.
    private static let yearMismatchPenalty: Double = 6_000

    /// How much the arr's own ordering can move a result, and how deep
    /// into the response that still applies. 2 pt per position for the
    /// first 50 gives the upstream popularity ranking the same order of
    /// influence as a full point of rating — audible, not dominant.
    private static let upstreamStep: Double = 2
    private static let upstreamDepth: Int = 50

    /// Everything applied on top of the tier score. All of it reorders
    /// *within* a band, except the year mismatch — see its constant.
    private static func modifiers(_ result: SearchResult, queryYear: Int?) -> Double {
        var m = bayesianQuality(result) * qualityWeight
        if result.inLibraryArrId != nil { m += libraryBoost }
        if let queryYear, let year = result.year {
            m += year == queryYear ? yearBonus : -yearMismatchPenalty
        }
        m -= Double(min(result.sourceRank, upstreamDepth)) * upstreamStep
        return m
    }

    /// Combined sort key — higher is better. Tier-band integer
    /// dominates; the modifiers break ties inside a band.
    static func rank(_ result: SearchResult, normalizedQuery q: String) -> Double {
        Double(score(result, normalizedQuery: q)) + modifiers(result, queryYear: nil)
    }

    // MARK: - Year disambiguation

    /// Splits a normalised query into "the words to match on" and "the
    /// year the user typed", when there is one.
    ///
    /// Two guards, both load-bearing:
    ///
    ///   - **Trailing token only.** People type the year after the title
    ///     ("dune 2024"), never before it. Scanning the whole query would
    ///     read "2001 A Space Odyssey" as a 2001 film — and since a year
    ///     mismatch is a heavy demotion, that would bury the one record
    ///     the user actually wanted.
    ///   - **Never the only token.** `1917` stays a search for the FILM
    ///     rather than an empty query with a year attached — the exact
    ///     ambiguity that made `QueryParser` refuse to parse years at all.
    static func splitYear(_ normalizedQuery: String) -> (query: String, year: Int?) {
        var tokens = normalizedQuery.split(separator: " ")
        guard tokens.count > 1, let last = tokens.last, isPlausibleYear(last) else {
            return (normalizedQuery, nil)
        }
        let year = Int(tokens.removeLast())
        return (tokens.joined(separator: " "), year)
    }

    /// 1880…(this year + 5). The upper bound is what keeps "Blade Runner
    /// 2049" intact — 2049 is not a plausible release year, so the title
    /// keeps its last word instead of being read as a year filter.
    private static func isPlausibleYear(_ token: Substring) -> Bool {
        guard token.count == 4, let n = Int(token) else { return false }
        let currentYear = Calendar.current.component(.year, from: Date())
        return n >= 1880 && n <= currentYear + 5
    }

    /// Ref-aware rank. For `.text` inputs, falls through to the
    /// string-based scoring above. For `.ref(_:)` inputs, the result
    /// either matches the ref (max score) or doesn't (zero) — there's
    /// no fuzzy middle ground for ID lookup.
    static func rank(_ result: SearchResult, against input: SearchInput) -> Double {
        switch input {
        case .text(let q):
            let (text, year) = splitYear(normalize(q))
            return Double(score(result, normalizedQuery: text))
                + modifiers(result, queryYear: year)
        case .ref(let ref):
            // ID match returns a score above any text-match tier so
            // a matching record always sorts to the top, regardless
            // of what the modifiers would contribute. Quality is
            // still added so a hypothetical "two results with the
            // same ref" tie (shouldn't happen, but parsing edges
            // exist) breaks predictably.
            return matches(result, ref) ? 100_000 + modifiers(result, queryYear: nil) : 0
        }
    }

    /// Does this record answer the id the user asked for?
    ///
    /// IMDB is the odd one out: `SearchResult.mediaRef` is TMDB/TVDB/
    /// MusicBrainz-keyed by source, so comparing it against `.imdb`
    /// was ALWAYS false and `imdb:ttN` searches came back empty no
    /// matter what the arr returned. It has to match on the record's
    /// own `imdbId` instead.
    private static func matches(_ result: SearchResult, _ ref: MediaRef) -> Bool {
        if case .imdb(let wanted) = ref {
            guard let have = result.imdbId, !have.isEmpty else { return false }
            return have.caseInsensitiveCompare(wanted) == .orderedSame
        }
        return result.mediaRef == ref
    }

    /// Sort + cross-source merge in one pass. Caller hands in the raw
    /// per-source flatMap; we sort by relevance to the input, with the
    /// in-band modifiers as tie-breakers. Stable w.r.t. equal-rank ties
    /// via Swift 5+'s stable `sorted(by:)`.
    static func sortedByRelevance(_ results: [SearchResult], input: SearchInput) -> [SearchResult] {
        switch input {
        case .text(let q):
            let normalized = normalize(q)
            guard !normalized.isEmpty else { return results }
            // Rank once per result rather than per comparison — the
            // year split and normalisation are not free, and a sort
            // calls the predicate O(n log n) times.
            return results
                .map { (result: $0, key: rank($0, against: input)) }
                .sorted { $0.key > $1.key }
                .map(\.result)
        case .ref(let ref):
            // Ref inputs: keep only matches (everything else scores
            // 0). Saves the consumer from having to filter out
            // unrelated rows that snuck in from other sources.
            //
            // Exception for IMDB: matching needs the record's own
            // `imdbId`, and not every arr/metadata combination fills it
            // in. If NOTHING in the batch carries one, the field simply
            // isn't available here — treating that as "no match" would
            // reproduce the empty screen this whole path exists to fix.
            // The arr only returned these rows for an `imdb:` term, so
            // trust its resolution and rank them normally.
            if case .imdb = ref, !results.contains(where: { $0.imdbId?.isEmpty == false }) {
                return results
                    .map { (result: $0, key: modifiers($0, queryYear: nil)) }
                    .sorted { $0.key > $1.key }
                    .map(\.result)
            }
            return results
                .map { (result: $0, key: rank($0, against: input)) }
                .filter { $0.key > 0 }
                .sorted { $0.key > $1.key }
                .map(\.result)
        }
    }

    /// String-input convenience kept for legacy call sites — wraps the
    /// query in `.text` and delegates. New code should prefer the
    /// `input:` variant so refs are recognised end-to-end.
    static func sortedByRelevance(_ results: [SearchResult], query: String) -> [SearchResult] {
        sortedByRelevance(results, input: .text(query))
    }
}
