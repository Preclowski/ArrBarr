import Foundation

/// A run of chat text, either shown plainly or hidden behind a spoiler.
enum ChatSpoilerSegment: Equatable, Sendable {
    case text(String)
    case spoiler(String)
}

/// `||hidden||` is a spoiler only when the markers hug their body: a false
/// positive blanks a whole paragraph (e.g. `a || b` in code or tables).
enum ChatSpoilerMarkup {
    private static let marker = "||"

    static func parse(_ raw: String) -> [ChatSpoilerSegment] {
        guard !raw.isEmpty else { return [] }
        var segments: [ChatSpoilerSegment] = []
        // Held until we know whether an upcoming `||` closes a real spoiler.
        var pending = ""
        var rest = Substring(raw)

        while let open = rest.range(of: marker) {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: marker) else { break }
            let body = afterOpen[afterOpen.startIndex..<close.lowerBound]
            if body.isEmpty || body.first!.isWhitespace || body.last!.isWhitespace {
                // Not a spoiler: resume just past the opener, since the rejected closer may open a real one.
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

    static func containsSpoiler(_ raw: String) -> Bool {
        parse(raw).contains { if case .spoiler = $0 { return true } else { return false } }
    }
}
