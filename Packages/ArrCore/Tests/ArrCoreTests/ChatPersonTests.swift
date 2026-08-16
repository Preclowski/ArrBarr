import Testing
import Foundation
@testable import ArrCore

@Suite("Chat person card")
struct ChatPersonTests {
    private func details(birthday: String?, deathday: String? = nil) -> TMDBPersonDetails {
        let json = """
        {"id": 19292, "name": "Adam Sandler", "known_for_department": "Acting",
         "birthday": \(birthday.map { "\"\($0)\"" } ?? "null"),
         "deathday": \(deathday.map { "\"\($0)\"" } ?? "null")}
        """
        return try! JSONDecoder().decode(TMDBPersonDetails.self, from: Data(json.utf8))
    }

    private func result(id: Int, title: String, source: QueueItem.Source) -> SearchResult {
        SearchResult(
            id: id, foreignId: String(id), title: title, subtitle: nil,
            year: 2019, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: source, inLibraryArrId: nil
        )
    }

    @Test("Life dates read as years, and only the years")
    func lifespan() {
        #expect(ChatPerson(details(birthday: "1966-09-09")).lifespan == "1966")
        #expect(ChatPerson(details(birthday: "1935-08-17", deathday: "2019-06-11")).lifespan == "1935–2019")
        #expect(ChatPerson(details(birthday: nil)).lifespan == nil)
        // A death date with no birth date says nothing on its own line.
        #expect(ChatPerson(details(birthday: nil, deathday: "2019-06-11")).lifespan == nil)
    }

    @Test("A malformed TMDB date yields no year rather than a wrong one")
    func malformedDate() {
        #expect(ChatPerson.year("19") == nil)
        #expect(ChatPerson.year("") == nil)
        #expect(ChatPerson.year(nil) == nil)
        #expect(ChatPerson.year("not-a-date") == nil)
    }

    @Test("The card carries the identity PersonView needs")
    func personRef() {
        let person = ChatPerson(tmdbId: 19292, name: "Adam Sandler", profilePath: "/abc.jpg")
        #expect(person.ref.tmdbId == 19292)
        #expect(person.ref.name == "Adam Sandler")
        #expect(person.ref.profilePath == "/abc.jpg")
    }

    private func toolMessage(_ rich: ChatRichContent) -> ChatMessage {
        ChatMessage(role: .tool, content: "tool", richContent: rich)
    }

    private let tilda = ChatPerson(tmdbId: 3063, name: "Tilda Swinton")
    private let sandler = ChatPerson(tmdbId: 19292, name: "Adam Sandler")

    @Test("The search card yields to the credits card for the same person")
    func searchCardYieldsToCredits() {
        let movie = result(id: 1, title: "Suspiria", source: .radarr)
        let search = toolMessage(.people([tilda]))
        let credits = toolMessage(.personCredits(person: tilda, results: [movie]))
        let out = ChatPersonCardDedupe.adjustments(for: [
            ChatMessage(role: .user, content: "Filmy z Tildą Swinton"), search, credits,
        ])
        // Search message drops out entirely; credits keeps its card.
        #expect(out[search.id] == ChatRichContent??.some(nil))
        #expect(out[credits.id] == nil)
    }

    @Test("A second credits call keeps its carousel but not a second card")
    func secondCreditsLosesItsCard() {
        let movie = result(id: 1, title: "Suspiria", source: .radarr)
        let series = result(id: 2, title: "Suspiria: The Series", source: .sonarr)
        let movies = toolMessage(.personCredits(person: tilda, results: [movie]))
        let shows = toolMessage(.personCredits(person: tilda, results: [series]))
        let out = ChatPersonCardDedupe.adjustments(for: [
            ChatMessage(role: .user, content: "Filmy i seriale z Tildą"), movies, shows,
        ])
        #expect(out[movies.id] == nil)
        #expect(out[shows.id] == .some(.searchSeriesResults([series])))
    }

    @Test("Only the duplicated person leaves the search card")
    func keepsTheOtherCandidates() {
        let movie = result(id: 1, title: "Suspiria", source: .radarr)
        let search = toolMessage(.people([tilda, sandler]))
        let credits = toolMessage(.personCredits(person: tilda, results: [movie]))
        let out = ChatPersonCardDedupe.adjustments(for: [
            ChatMessage(role: .user, content: "kto to"), search, credits,
        ])
        #expect(out[search.id] == .some(.people([sandler])))
    }

    @Test("Asking about the same person in a later turn cards them again")
    func perTurnScope() {
        let first = toolMessage(.people([tilda]))
        let second = toolMessage(.people([tilda]))
        let out = ChatPersonCardDedupe.adjustments(for: [
            ChatMessage(role: .user, content: "kto to Tilda"), first,
            ChatMessage(role: .user, content: "a jeszcze raz?"), second,
        ])
        #expect(out.isEmpty)
    }

    @Test("The credits argument accepts what a model actually writes")
    func creditsKindParsing() {
        #expect(LocalToolBackend.CreditsKind("movies") == .movies)
        #expect(LocalToolBackend.CreditsKind("film") == .movies)
        #expect(LocalToolBackend.CreditsKind("series") == .series)
        #expect(LocalToolBackend.CreditsKind("tv") == .series)
        // Absent or nonsense → plain name resolution, never a guessed kind.
        #expect(LocalToolBackend.CreditsKind("") == nil)
        #expect(LocalToolBackend.CreditsKind("both") == nil)
    }

    @Test("Credits fall back to a plain carousel when the person lookup failed")
    func creditsRichFallback() {
        let movie = result(id: 1, title: "Uncut Gems", source: .radarr)
        let series = result(id: 2, title: "Sandler Show", source: .sonarr)

        #expect(LocalToolBackend.creditsRich(person: nil, results: [movie]) == .searchMovieResults([movie]))
        #expect(LocalToolBackend.creditsRich(person: nil, results: [series]) == .searchSeriesResults([series]))

        let person = ChatPerson(tmdbId: 19292, name: "Adam Sandler")
        #expect(LocalToolBackend.creditsRich(person: person, results: [movie])
                == .personCredits(person: person, results: [movie]))
    }
}
