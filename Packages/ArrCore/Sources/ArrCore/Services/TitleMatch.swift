import Foundation

/// Title matching for library lookups.
///
/// The library tools used to match with a raw `title.lowercased().contains(q)`,
/// which fails on everything a person actually types: a missing accent
/// ("amelie"), a leading article the arr keeps and the user drops ("The
/// Godfather" vs "godfather"), punctuation ("wall-e" vs "wall e") and ordinary
/// typos. Every one of those came back as "nothing in your library matches",
/// which reads as "you don't own it" — the single most damaging wrong answer
/// this app can give.
///
/// Deliberately not a search engine: normalize hard, then rank exact → prefix →
/// contains → edit-distance. That covers the human ways of typing a title the
/// user already knows they own, and nothing else.
public enum TitleMatch {

    /// Case, accent, width and punctuation-insensitive form — articles intact.
    /// This is the space a live filter field compares in: dropping a leading
    /// article here would empty the list the moment someone types "a" or "the"
    /// on the way to a longer query.
    public static func fold(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: nil)
        // Punctuation becomes a space rather than vanishing, so "wall-e" and
        // "wall e" collapse to the same tokens instead of "walle" vs "wall e".
        let cleaned = String(folded.map { ch in
            if ch.isLetter || ch.isNumber { return ch }
            return " "
        })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// Every name one title can be found by — its own, its original-language
    /// one, its translations — folded and joined into a single haystack.
    ///
    /// Built once when the library loads, not per keystroke. That ordering is
    /// the whole point: folding is an ICU call, and a shelf of 3000 titles
    /// with ~25 aliases each is ~75k of them, which is a visibly janky filter
    /// field if it happens per keypress and free if it happens per refresh.
    ///
    /// Entries join on a newline. `fold` emits only letters, digits and
    /// spaces, so a newline is a boundary no folded query can contain, and a
    /// query therefore cannot match across two different titles.
    public static func searchIndex(_ titles: [String?]) -> String {
        var seen = Set<String>()
        return titles
            .compactMap { $0.map(fold) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    /// Substring filter over prepared `searchIndex` blobs — "leon" keeps
    /// "Léon: The Professional", "wall e" keeps "WALL·E". For incremental
    /// filter fields, where the user narrows a list they can already see;
    /// `matches` is the ranked variant, for when they're naming one they
    /// can't.
    ///
    /// Order is the caller's — a filter field must not reshuffle the grid
    /// under the cursor on every keystroke. The query folds once; the
    /// candidates were folded at index-build time.
    public static func indexedFilter<T>(
        _ candidates: [T],
        query: String,
        index: (T) -> String
    ) -> [T] {
        let folded = fold(query)
        guard !folded.isEmpty else { return candidates }
        return candidates.filter { index($0).contains(folded) }
    }

    /// `fold`, plus a leading article dropped. Everything that *ranks* titles
    /// compares in this space; nothing compares raw.
    public static func normalize(_ raw: String) -> String {
        let tokens = fold(raw).split(separator: " ").map(String.init)
        guard let first = tokens.first else { return "" }
        // Drop a leading article only when something follows it — "The Thing"
        // becomes "thing", but the film "The The" would not become nothing.
        if Self.articles.contains(first), tokens.count > 1 {
            return tokens.dropFirst().joined(separator: " ")
        }
        return tokens.joined(separator: " ")
    }

    private static let articles: Set<String> = [
        "the", "a", "an", "le", "la", "les", "der", "die", "das", "el", "los", "las",
    ]

    /// How well `query` matches `title`, both already normalized. Lower is
    /// better; nil means "not a match at all". The scale is coarse on purpose —
    /// callers sort by it, they don't display it.
    public static func score(query: String, title: String) -> Int? {
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
        // Typo tolerance last, and only for queries long enough that a couple
        // of edits still means something. One edit per 4 characters, capped —
        // otherwise short titles all match each other.
        guard query.count >= 5 else { return nil }
        let budget = min(2, query.count / 4)
        let distance = editDistance(query, title, limit: budget)
        guard distance <= budget else { return nil }
        return 4 + distance
    }

    /// Levenshtein distance, abandoned as soon as it exceeds `limit`.
    /// Bounded because it runs against every title in a 3000-item library.
    public static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
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
            // Every remaining row can only grow the distance, so a row whose
            // best cell already blew the budget can't recover.
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Best match for one title (+ optional year) among candidates.
    ///
    /// A year turns a guess into an answer for remakes — "Dune 2021" must not
    /// land on Lynch's 1984 — so an exact year beats a better title score, and
    /// a candidate whose year contradicts the query is only accepted when
    /// nothing else matches at all.
    public static func best<T>(
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

    /// Every candidate matching `query`, best first. Used by the library list
    /// tools, where the user asked for a substring rather than one title.
    public static func matches<T>(
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
