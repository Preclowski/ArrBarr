import Foundation

/// Structured side-channel payload carried by a `.tool` `ChatMessage`. The
/// LLM never sees this — it's UI-only. The corresponding `toolResult` text
/// remains the canonical info the model gets in the conversation.
public enum ChatRichContent: Sendable, Equatable {
    case searchSeriesResults([SearchResult])
    case searchMovieResults([SearchResult])
    case searchArtistResults([SearchResult])
    case searchSceneResults([SearchResult])
    case librarySeries([SonarrLibraryRecord])
    case libraryMovies([RadarrLibraryRecord])
    case libraryArtists([LidarrLibraryRecord])
    case libraryScenes([WhisparrLibraryRecord])
    case calendar([UpcomingItem])
    /// One artist's albums, with the artist named above them — the music half
    /// of what the movie/series carousels already did. `artist` is the display
    /// name; the cards carry the album ids.
    case albums(artist: String?, albums: [ChatAlbum])
    /// Name matches from `tmdb_search_person` — one minimal profile card per
    /// candidate, so "who is X" answers with a face instead of a bare sentence.
    case people([ChatPerson])
    /// The cast of one title — the head strip detail surfaces already use, so
    /// "who starred in The Matrix" answers with faces you can tap through to
    /// each person, not a bulleted list of names.
    case cast([CastMember])
    /// A filmography answer: the person's own card on top, their credits in the
    /// carousel below. Emitted by `tmdb_person_movie_credits` /
    /// `tmdb_person_tv_credits`, where the old payload showed the films but
    /// never the person they belong to.
    case personCredits(person: ChatPerson, results: [SearchResult])
    /// Active download queue. Upgrade rows render as a side-by-side
    /// comparison (current library file vs incoming release) so the user
    /// can see at a glance what's improving.
    case downloadQueue([QueueItem])
    /// Resume card for the Discover quiz overlay. Shown in chat after a
    /// `discover_in_quiz` tool call so the user can re-enter the just-opened
    /// quiz without re-prompting the LLM.
    case discoverSession(mood: String, posterURLs: [URL])

    /// Credits payload with the person's card when we have them, and the plain
    /// carousel when we don't. The carousel case follows the results' own
    /// source, so a TV credit list never renders through the movie path.
    public static func credits(person: ChatPerson?, results: [SearchResult]) -> ChatRichContent {
        if let person { return .personCredits(person: person, results: results) }
        return results.first?.source == .sonarr ? .searchSeriesResults(results) : .searchMovieResults(results)
    }
}

/// Keeps one person from being carded twice in the same answer.
///
/// A "films with X" question routinely runs `tmdb_search_person` and then
/// `tmdb_person_movie_credits` (and often `_tv_credits` too) — three tool calls
/// that each know about the same human, so the chat used to stack three
/// identical cards linking to the same view. The rule is one card per person per
/// assistant turn: the credits card wins (it carries life dates and owns the
/// carousel under it), the search card steps aside, and a second credits call
/// keeps only its carousel.
///
/// Scoped to the turn, not the conversation — asking about the same actor again
/// ten messages later should of course show them again.
public enum ChatPersonCardDedupe {
    /// Rich payloads that need to change, keyed by message id. `nil` means the
    /// message has nothing left to draw and should be dropped entirely.
    public static func adjustments(for messages: [ChatMessage]) -> [UUID: ChatRichContent?] {
        var out: [UUID: ChatRichContent?] = [:]
        for turn in turns(messages) { adjust(turn, into: &out) }
        return out
    }

    /// Splits the history into assistant turns — each user message starts a new
    /// one, and everything answering it belongs to that turn.
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
        // People this turn will card through a credits call. Known up front so
        // an EARLIER search card can yield to a LATER credits card.
        // Keyed by id AND by name. TMDB carries several people per famous name —
        // a search for "Jason Biggs" turns up the actor and a crew namesake —
        // and two cards reading "Jason Biggs" are a duplicate to everyone
        // except the de-duplicator matching on ids.
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
