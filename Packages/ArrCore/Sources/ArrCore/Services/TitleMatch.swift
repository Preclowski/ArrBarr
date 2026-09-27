import Foundation

/// Title matching for library lookups: normalize hard, then rank exact → prefix →
/// contains → edit-distance. A false "not in your library" is the most damaging wrong answer.
nonisolated enum TitleMatch {

    /// Articles intact: dropping them here would empty a live filter the moment
    /// someone types "a" or "the"; relevance ranking needs them too.
    static func fold(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: nil)
        // Punctuation becomes a space, so "wall-e" and "wall e" give the same tokens.
        let cleaned = String(folded.map { ch in
            if ch.isLetter || ch.isNumber { return ch }
            return " "
        })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// Built once per library load, not per keystroke: 3000 titles × ~25 aliases of ICU folding.
    /// Joined on a newline, which `fold` never emits, so a query can't match across titles.
    static func searchIndex(_ titles: [String?]) -> String {
        var seen = Set<String>()
        return titles
            .compactMap { $0.map(fold) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    /// Substring filter over `searchIndex` blobs; `matches` is the ranked variant.
    /// Order is the caller's: a filter field must not reshuffle the grid on every keystroke.
    static func indexedFilter<T>(
        _ candidates: [T],
        query: String,
        index: (T) -> String
    ) -> [T] {
        let folded = fold(query)
        guard !folded.isEmpty else { return candidates }
        return candidates.filter { index($0).contains(folded) }
    }

    /// `fold` minus a leading article; not for relevance ranking, where `fold` is the right space.
    static func normalize(_ raw: String) -> String {
        let tokens = fold(raw).split(separator: " ").map(String.init)
        guard let first = tokens.first else { return "" }
        // Only when something follows: "The The" must not become nothing.
        if Self.articles.contains(first), tokens.count > 1 {
            return tokens.dropFirst().joined(separator: " ")
        }
        return tokens.joined(separator: " ")
    }

    private static let articles: Set<String> = [
        "the", "a", "an", "le", "la", "les", "der", "die", "das", "el", "los", "las",
    ]

    // MARK: - Year disambiguation

    /// Trailing token only ("2001 A Space Odyssey" is not a 2001 film), and never
    /// the only token (`1917` stays a search for the film).
    static func splitTrailingYear(_ foldedQuery: String) -> (query: String, year: Int?) {
        var tokens = foldedQuery.split(separator: " ")
        guard tokens.count > 1, let last = tokens.last, isPlausibleYear(last) else {
            return (foldedQuery, nil)
        }
        let year = Int(tokens.removeLast())
        return (tokens.joined(separator: " "), year)
    }

    /// The upper bound keeps "Blade Runner 2049" intact.
    static func isPlausibleYear(_ token: some StringProtocol) -> Bool {
        guard token.count == 4, let n = Int(token) else { return false }
        let currentYear = Calendar.current.component(.year, from: Date())
        return n >= 1880 && n <= currentYear + 5
    }

    /// Lower is better, nil = no match. Coarse on purpose: callers sort by it, never display it.
    static func score(query: String, title: String) -> Int? {
        guard !query.isEmpty, !title.isEmpty else { return nil }
        if query == title { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        // Token-level prefix: "matrix reload" finds "the matrix reloaded".
        let queryTokens = query.split(separator: " ")
        let titleTokens = title.split(separator: " ")
        if !queryTokens.isEmpty,
           queryTokens.allSatisfy({ qt in titleTokens.contains(where: { $0.hasPrefix(qt) }) }) {
            return 3
        }
        // One edit per 4 characters, capped, else short titles all match each other.
        guard query.count >= 5 else { return nil }
        let budget = min(2, query.count / 4)
        let distance = editDistance(query, title, limit: budget)
        guard distance <= budget else { return nil }
        return 4 + distance
    }

    /// Bounded because it runs against every title in a 3000-item library.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// An exact year beats a better title score ("Dune 2021" must not land on 1984); a
    /// contradicting year is accepted only when nothing else matches.
    static func best<T>(
        query: String,
        year: Int?,
        candidates: [T],
        title: (T) -> String,
        year candidateYear: (T) -> Int?
    ) -> T? {
        let normalizedQuery = normalize(query)
        var bestItem: T?
        var bestRank: (yearPenalty: Int, score: Int)?
        for candidate in candidates {
            guard let score = score(query: normalizedQuery, title: normalize(title(candidate))) else { continue }
            let penalty: Int = {
                guard let year, let candidateYear = candidateYear(candidate) else { return 1 }
                if candidateYear == year { return 0 }
                // ±1 absorbs the usual festival-vs-release-year disagreement.
                return abs(candidateYear - year) <= 1 ? 1 : 2
            }()
            let rank = (yearPenalty: penalty, score: score)
            if bestRank == nil || rank < bestRank! {
                bestRank = rank
                bestItem = candidate
            }
        }
        return bestItem
    }

    static func matches<T>(
        query: String,
        candidates: [T],
        title: (T) -> String
    ) -> [T] {
        let normalizedQuery = normalize(query)
        return candidates
            .compactMap { candidate -> (T, Int)? in
                guard let score = score(query: normalizedQuery, title: normalize(title(candidate))) else { return nil }
                return (candidate, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}
