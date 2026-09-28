import Foundation

/// Client-side search ranking. Bands: exact 10k > title prefix 5k > all words 4k >
/// word prefix 2k > coverage/substring 1k; modifiers only reorder inside a band.
nonisolated enum SearchRelevance {
    /// 0 means no match; callers decide whether to keep it.
    static func score(_ result: SearchResult, normalizedQuery q: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let title = TitleMatch.fold(result.title)
        if title == q { return 10_000 }
        if title.hasPrefix(q) {
            // Shorter titles win the prefix band: "Foo" before "Foo Bar Baz".
            return 5_000 - min(title.count, 999)
        }

        // Single-word queries fall through: for them word-prefix already is coverage.
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
                    return 4_000 - min(title.count, 999)
                }
                if matchedChars > 0 {
                    // Weighted by characters, so dropping "the" barely costs while dropping "matrix" guts it.
                    let coverage = Double(matchedChars) / Double(totalChars)
                    return 1_000 + Int(900 * coverage)
                }
            }
        }

        // Word boundaries beat mid-word hits.
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
            return 2_000 - min(title.count, 999)
        }
        if let range = title.range(of: q) {
            // Capped so a late match still beats no match.
            let pos = title.distance(from: title.startIndex, to: range.lowerBound)
            return 1_000 - min(pos, 999)
        }
        return 0
    }

    /// Shrinks only ratings above the mean (m = 500 votes, C = 6.5): lifting low
    /// ratings pulled 0.0-rated obscure titles up to the mean.
    static func bayesianQuality(_ result: SearchResult) -> Double {
        let R = result.rating ?? 0
        let C: Double = 6.5
        guard let votes = result.votes, votes > 0, R > C else { return R }
        let v = Double(votes)
        let m: Double = 500
        return (v / (v + m)) * R + (m / (v + m)) * C
    }

    /// ×10 lets one rating point outweigh ten characters of title length, still far below the band gap.
    private static let qualityWeight: Double = 10

    /// Above the whole quality span (100), far below the band gap.
    private static let libraryBoost: Double = 150

    /// A typed year ("dune 2024") outweighs quality and ownership.
    private static let yearBonus: Double = 300

    /// Deliberately crosses bands: "dune 2024" must beat the exact "Dune" (2021).
    /// Safe only because `splitTrailingYear` reads the trailing token alone.
    private static let yearMismatchPenalty: Double = 6_000

    /// 2 pt per position for the first 50: the upstream popularity rank weighs about one rating point.
    private static let upstreamStep: Double = 2
    private static let upstreamDepth: Int = 50

    /// All in-band, except the year mismatch penalty.
    private static func modifiers(_ result: SearchResult, queryYear: Int?) -> Double {
        var m = bayesianQuality(result) * qualityWeight
        if result.inLibraryArrId != nil { m += libraryBoost }
        if let queryYear, let year = result.year {
            m += year == queryYear ? yearBonus : -yearMismatchPenalty
        }
        m -= Double(min(result.sourceRank, upstreamDepth)) * upstreamStep
        return m
    }

    /// `.ref` inputs match exactly or score zero.
    static func rank(_ result: SearchResult, against input: SearchInput) -> Double {
        switch input {
        case .text(let q):
            let (text, year) = TitleMatch.splitTrailingYear(TitleMatch.fold(q))
            return Double(score(result, normalizedQuery: text))
                + modifiers(result, queryYear: year)
        case .ref(let ref):
            // Above every text tier; modifiers only break a (theoretical) same-ref tie.
            return matches(result, ref) ? 100_000 + modifiers(result, queryYear: nil) : 0
        }
    }

    /// IMDB must match on the record's own `imdbId`: `mediaRef` is keyed TMDB/TVDB/MusicBrainz.
    private static func matches(_ result: SearchResult, _ ref: MediaRef) -> Bool {
        if case .imdb(let wanted) = ref {
            guard let have = result.imdbId, !have.isEmpty else { return false }
            return have.caseInsensitiveCompare(wanted) == .orderedSame
        }
        return result.mediaRef == ref
    }

    /// Relies on `sorted(by:)` being stable for equal ranks.
    static func sortedByRelevance(_ results: [SearchResult], input: SearchInput) -> [SearchResult] {
        switch input {
        case .text(let q):
            let normalized = TitleMatch.fold(q)
            guard !normalized.isEmpty else { return results }
            // Rank once per result: the predicate runs O(n log n) times.
            return results
                .map { (result: $0, key: rank($0, against: input)) }
                .sorted { $0.key > $1.key }
                .map(\.result)
        case .ref(let ref):
            // Ref inputs keep only matches. IMDB exception: when no row carries an
            // `imdbId`, trust the arr's own `imdb:` resolution and rank normally.
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
}
