import Foundation

/// Which ids the tools actually produced in this conversation.
///
/// The model is told to link only ids it got from a tool result. It does not
/// always obey — asked for "the gaps in your collection", it names six films
/// whose ids no tool ever printed and links them from memory, so every link
/// lands on some unrelated film (or on nothing at all). No prompt wording fixes
/// that reliably, because inventing a plausible id is the same act as inventing
/// a plausible sentence.
///
/// So linking is verified, not trusted: a chat link renders as a link only if
/// its id appears verbatim in a tool result of this conversation. Anything else
/// stays plain text — the prose survives, the wrong door doesn't open.
public enum ChatLinkVerification {
    /// Keys (`tmdb:603`, `person:3063`, …) harvested from every tool result.
    public static func knownKeys(in messages: [ChatMessage]) -> Set<String> {
        var out: Set<String> = []
        for message in messages {
            guard let text = message.toolResult, !text.isEmpty else { continue }
            out.formUnion(keys(in: text))
        }
        return out
    }

    /// True when this link points at something a tool actually returned.
    public static func isVerified(_ link: ChatLink, against known: Set<String>) -> Bool {
        known.contains(link.verificationKey)
    }

    static func keys(in text: String) -> Set<String> {
        var out: Set<String> = []
        for match in refRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let scheme = match.range(at: 1).substring(of: text),
                  let value = match.range(at: 2).substring(of: text) else { continue }
            // Normalised through MediaRef so "imdb:0083658" and "imdb:tt0083658"
            // — both of which the tools may print — resolve to one key.
            if let ref = MediaRef(urlString: "\(scheme):\(value)") {
                out.insert(ref.urlString.lowercased())
            }
        }
        for match in personRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let id = match.range(at: 1).substring(of: text) else { continue }
            out.insert("person:\(id)")
        }
        return out
    }

    /// `tmdb:603`, `tvdb:81189`, `imdb:tt0133093`, `mb:<guid>` as printed in the
    /// tool text.
    private static let refRegex = try! NSRegularExpression(
        pattern: "\\b(tmdbtv|tmdb|tvdb|imdb|mb|musicbrainz)\\s*:\\s*(tt?[0-9a-f-]+|[0-9]+)",
        options: [.caseInsensitive]
    )

    /// `personId: 3063` and `(personId: 6384)` — the shape the person and cast
    /// tools print.
    private static let personRegex = try! NSRegularExpression(
        pattern: "personId\\s*[:=]\\s*([0-9]+)",
        options: [.caseInsensitive]
    )
}

private extension NSRange {
    func substring(of text: String) -> String? {
        guard let range = Range(self, in: text) else { return nil }
        return String(text[range])
    }
}
