import Foundation
import MediaKit

/// UI-only payload on a `.tool` message; the model only ever sees `toolResult`.
nonisolated public enum ChatRichContent: Sendable, Equatable {
    case searchSeriesResults([SearchResult])
    case searchMovieResults([SearchResult])
    case searchArtistResults([SearchResult])
    case searchSceneResults([SearchResult])
    case librarySeries([ArrSeries])
    case libraryMovies([ArrMovie])
    case libraryArtists([ArrArtist])
    case libraryScenes([ArrMovie])
    case calendar([UpcomingItem])
    /// `artist` is the display name; the cards carry the album ids.
    case albums(artist: String?, albums: [ChatAlbum])
    case people([ChatPerson])
    case cast([CastMember])
    case personCredits(person: ChatPerson, results: [SearchResult])
    /// Upgrade rows compare the current library file with the incoming release.
    case downloadQueue([QueueItem])
    /// Lets the user re-enter the quiz without re-prompting the model.
    case discoverSession(mood: String, posterURLs: [URL])

    /// The carousel case follows the results' source, so TV credits never take the movie path.
    public static func credits(person: ChatPerson?, results: [SearchResult]) -> ChatRichContent {
        if let person { return .personCredits(person: person, results: results) }
        return results.first?.source == .sonarr ? .searchSeriesResults(results) : .searchMovieResults(results)
    }
}

/// One card per person per assistant turn: the credits card wins over the
/// search card, and a second credits call keeps only its carousel.
nonisolated enum ChatPersonCardDedupe {
    /// `nil` means the message has nothing left to draw and is dropped.
    static func adjustments(for messages: [ChatMessage]) -> [UUID: ChatRichContent?] {
        var out: [UUID: ChatRichContent?] = [:]
        for turn in turns(messages) { adjust(turn, into: &out) }
        return out
    }

    private static func turns(_ messages: [ChatMessage]) -> [[ChatMessage]] {
        var out: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        for msg in messages {
            if msg.role == .user, !current.isEmpty {
                out.append(current)
                current = []
            }
            current.append(msg)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func adjust(_ turn: [ChatMessage], into out: inout [UUID: ChatRichContent?]) {
        // Known up front so an earlier search card yields to a later credits card.
        // Also keyed by name: TMDB has namesakes, and two same-name cards read as duplicates.
        var claimedByCredits: Set<String> = []
        for msg in turn {
            if case .personCredits(let person, _)? = msg.richContent {
                claimedByCredits.formUnion(keys(person))
            }
        }

        var carded: Set<String> = []
        for msg in turn {
            switch msg.richContent {
            case .people(let people):
                let kept = people.filter { person in
                    keys(person).isDisjoint(with: claimedByCredits.union(carded))
                }
                kept.forEach { carded.formUnion(keys($0)) }
                if kept.count != people.count {
                    out[msg.id] = kept.isEmpty ? ChatRichContent?.none : .people(kept)
                }
            case .personCredits(let person, let results):
                if !keys(person).isDisjoint(with: carded) {
                    out[msg.id] = .credits(person: nil, results: results)
                } else {
                    carded.formUnion(keys(person))
                }
            default:
                continue
            }
        }
    }

    private static func keys(_ person: ChatPerson) -> Set<String> {
        ["id:\(person.tmdbId)", "name:\(person.name.lowercased())"]
    }
}
