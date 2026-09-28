import Foundation

/// A chat link renders only if its id appears verbatim in a tool result of this conversation:
/// models link invented ids from memory, and no prompt wording prevents it.
nonisolated enum ChatLinkVerification {
    static func knownKeys(in messages: [ChatMessage]) -> Set<String> {
        var out: Set<String> = []
        for message in messages {
            guard let text = message.toolResult, !text.isEmpty else { continue }
            out.formUnion(keys(in: text))
        }
        return out
    }

    static func isVerified(_ link: ChatLink, against known: Set<String>) -> Bool {
        known.contains(link.verificationKey)
    }

    static func keys(in text: String) -> Set<String> {
        var out: Set<String> = []
        for match in refRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let scheme = match.range(at: 1).substring(of: text),
                  let value = match.range(at: 2).substring(of: text) else { continue }
            // Via MediaRef so "imdb:0083658" and "imdb:tt0083658" resolve to one key.
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

    private static let refRegex = try! NSRegularExpression(
        pattern: "\\b(tmdbtv|tmdb|tvdb|imdb|mb|musicbrainz)\\s*:\\s*(tt?[0-9a-f-]+|[0-9]+)",
        options: [.caseInsensitive]
    )

    private static let personRegex = try! NSRegularExpression(
        pattern: "personId\\s*[:=]\\s*([0-9]+)",
        options: [.caseInsensitive]
    )
}

nonisolated private extension NSRange {
    func substring(of text: String) -> String? {
        guard let range = Range(self, in: text) else { return nil }
        return String(text[range])
    }
}
