import SwiftUI

/// Splits a queue-style title like "The Boys (2019)" into the bare
/// title and the trailing year. Used as a fallback when the arr fetch
/// hasn't returned a structured `(title, year)` pair yet — keeps the
/// hero card rendering consistent between loading and loaded states
/// (otherwise the title looked like "The Boys (2019)" while loading
/// and just "The Boys" after, because MediaHeaderCard appends `(year)`
/// itself).
func splitTitleAndYear(_ raw: String) -> (title: String, year: Int?) {
    guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s*\((19|20)\d{2}\)\s*$"#) else {
        return (raw, nil)
    }
    let ns = raw as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2 else {
        return (raw, nil)
    }
    let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    let yearRegex = try? NSRegularExpression(pattern: #"\((19|20)\d{2}\)"#)
    let yearMatch = yearRegex?.matches(in: raw, range: range).last
    let year: Int? = yearMatch.flatMap { m in
        let s = ns.substring(with: m.range).dropFirst().dropLast()
        return Int(s)
    }
    return (title, year)
}

func formatDuration(ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
