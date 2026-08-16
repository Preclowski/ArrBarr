import Foundation

/// A run of chat text, either shown plainly or hidden behind a spoiler.
public enum ChatSpoilerSegment: Equatable, Sendable {
    case text(String)
    case spoiler(String)
}

/// Parses the lightweight spoiler markup the assistant may emit: text wrapped
/// in double pipes — `||hidden||` — is a spoiler the UI redacts until tapped.
///
/// The markers must hug their body: `||twist||` is a spoiler, `a || b` is not.
/// That rule is load-bearing, not cosmetic. Redacted text renders as invisible
/// glyphs, so a false positive doesn't degrade — it blanks a whole paragraph of
/// an ordinary answer, and the reader is left with an empty-looking bubble and
/// no idea it can be clicked. Prose that merely contains two `||` runs (a
/// logical-or in a code span, a Markdown table with empty cells) used to hit
/// exactly that, because any second `||` closed the first.
public enum ChatSpoilerMarkup {
    private static let marker = "||"

    public static func parse(_ raw: String) -> [ChatSpoilerSegment] {
        guard !raw.isEmpty else { return [] }
        var segments: [ChatSpoilerSegment] = []
        // `pending` is plain text not yet flushed — we hold it until we know
        // whether an upcoming `||` resolves into a real (closed, non-empty)
        // spoiler or should fold back into the surrounding prose.
        var pending = ""
        var rest = Substring(raw)

        while let open = rest.range(of: marker) {
            // Need a *closing* marker after the opener for this to be a spoiler.
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: marker) else { break }
            let body = afterOpen[afterOpen.startIndex..<close.lowerBound]
            if body.isEmpty || body.first!.isWhitespace || body.last!.isWhitespace {
                // Either `||||`, or markers that don't hug their body — not a
                // spoiler. Keep them as literal text and carry on scanning from
                // just past the OPENER (not past the closer): the run we just
                // rejected as a closer may well be the opener of a real spoiler.
                pending += rest[rest.startIndex..<open.upperBound]
                rest = rest[open.upperBound...]
                continue
            }
            pending += rest[rest.startIndex..<open.lowerBound]
            if !pending.isEmpty { segments.append(.text(pending)); pending = "" }
            segments.append(.spoiler(String(body)))
            rest = afterOpen[close.upperBound...]
        }

        pending += rest
        if !pending.isEmpty { segments.append(.text(pending)) }
        return segments
    }

    public static func containsSpoiler(_ raw: String) -> Bool {
        parse(raw).contains { if case .spoiler = $0 { return true } else { return false } }
    }
}
