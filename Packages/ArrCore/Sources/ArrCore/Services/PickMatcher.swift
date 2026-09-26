import Foundation

/// Picks the lookup hit that IS the title a model named, instead of trusting
/// the arr's first hit — which for "The Power 2021" is The Power of the Dog and
/// for "Burning 2018" is Mississippi Burning. Nil means none of the hits is it:
/// the card is dropped and reported rather than shown as a stranger.
nonisolated enum PickMatcher {

    struct Candidate: Sendable {
        /// Display title first, then original and alternate titles.
        let titles: [String]
        let year: Int?
        let votes: Int?
    }

    static func bestIndex(title: String, year: Int?, in candidates: [Candidate]) -> Int? {
        let scored = candidates.enumerated().compactMap { index, candidate -> (index: Int, score: Int, year: Int?, weight: Double)? in
            let score = titleScore(title, candidate.titles)
            guard score > 0 else { return nil }
            return (index, score, candidate.year, log10(Double(max(0, candidate.votes ?? 0)) + 1))
        }
        guard !scored.isEmpty else { return nil }

        guard let year else {
            return scored.max { ($0.score, $0.weight, -$0.index) < ($1.score, $1.weight, -$1.index) }?.index
        }
        // Festival vs release year makes ±1 routine (Under the Skin is 2013 to
        // a critic, 2014 to TMDB), so the better-known film wins a near-tie.
        let close = scored.filter { hit in
            guard let y = hit.year, abs(y - year) <= 1 else { return false }
            return hit.score >= 2 || y == year
        }
        if let top = close.map(\.score).max() {
            return close.filter { $0.score == top }
                .max { rank($0, year) < rank($1, year) }?.index
        }
        return scored.first { $0.score >= 2 && $0.year.map { abs($0 - year) == 2 } == true }?.index
    }

    private static func rank(_ hit: (index: Int, score: Int, year: Int?, weight: Double), _ year: Int) -> (Double, Int) {
        (hit.weight - Double(abs((hit.year ?? year) - year)), -hit.index)
    }

    /// 3: display title equal · 2: original/alternate title equal ·
    /// 1: same work under a subtitle or a possessive prefix · 0: different work.
    static func titleScore(_ pick: String, _ titles: [String]) -> Int {
        let p = normalize(pick)
        guard !p.isEmpty else { return 0 }
        var best = 0
        for (index, title) in titles.enumerated() {
            let c = normalize(title)
            guard !c.isEmpty else { continue }
            if c == p {
                best = max(best, index == 0 ? 3 : 2)
            } else if normalize(head(of: title)) == p {
                best = max(best, 1)          // "Asura" → "Asura: The City of Madness"
            } else if p.count > c.count, p.hasPrefix(c) || p.hasSuffix(c),
                      Double(c.count) / Double(p.count) >= 0.6 {
                best = max(best, 1)          // "Waking Ned Devine" → "Waking Ned"
            }
        }
        return best
    }

    /// Case, diacritics, punctuation, a leading article and a trailing
    /// "(2016)" / "(US)" disambiguator all fold away: Sonarr names remakes
    /// "Crashing (2017)" and the model writes "Crashing".
    static func normalize(_ title: String) -> String {
        var t = stripDisambiguator(title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a ", "an "] where t.hasPrefix(article) {
            t.removeFirst(article.count)
            break
        }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func stripDisambiguator(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((\d{4}|[A-Za-z]{2,3})\)\s*$"#, with: "", options: .regularExpression)
    }

    /// The title before a subtitle separator (": ", " - ", " – ", " (").
    private static func head(of title: String) -> String {
        let bare = stripDisambiguator(title)
        guard let range = bare.range(of: #"\s*(:|\s-\s|\s–\s|\()"#, options: .regularExpression) else { return bare }
        return String(bare[..<range.lowerBound])
    }
}
