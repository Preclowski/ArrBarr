import Testing
import Foundation
@testable import ArrCore

@Suite("Quiz streaming")
struct QuizStreamingTests {

    @Test("scanner yields only the items that have closed, plus the scalars before them")
    func scannerPartial() {
        let text = #"{"mood":"cozy \"90s\"","kind":"movie","append":false,"items":[{"title":"Big Buck Bunny","year":2008},{"title":"Sintel","ye"#
        let partial = QuizArgumentsScanner.scan(text)
        #expect(partial.string("mood") == #"cozy "90s""#)
        #expect(partial.string("kind") == "movie")
        #expect(partial.bool("append") == false)
        let picks = LocalToolBackend.suggestItems(.object(["items": .array(partial.items)]))
        #expect(picks.map(\.title) == ["Big Buck Bunny"])
        #expect(picks.first?.year == 2008)
    }

    @Test("scanner does not commit a bare literal that may still grow")
    func scannerOpenLiteral() {
        #expect(QuizArgumentsScanner.scan(#"{"kind":"movie","append":tr"#).bool("append") == nil)
        #expect(QuizArgumentsScanner.scan(#"{"items":[{"title":"A"}],"kind":"ser"#).string("kind") == nil)
    }

    @Test("scanner reads a finished payload in full, braces inside strings included")
    func scannerComplete() {
        let text = #"{"items":[{"title":"A } B"},{"title":"C"}],"kind":"series","mood":"m"}"#
        let partial = QuizArgumentsScanner.scan(text)
        #expect(partial.items.count == 2)
        #expect(partial.string("kind") == "series")
    }

    @Test("stream accumulator rebuilds tool calls from deltas")
    func accumulator() throws {
        func chunk(_ json: String) throws -> ChatCompletionChunk {
            try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(json.utf8))
        }
        var stream = ChatCompletionStream()
        _ = stream.apply(try chunk(#"{"choices":[{"delta":{"content":"Hi"}}]}"#))
        _ = stream.apply(try chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"discover_in_quiz","arguments":""}}]}}]}"#))
        let touched = stream.apply(try chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"kind\":"}}]}}]}"#))
        _ = stream.apply(try chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"movie\"}"}}]}}]}"#))
        #expect(touched.first?.arguments == #"{"kind":"#)
        #expect(stream.text == "Hi")
        #expect(stream.toolCalls.count == 1)
        #expect(stream.toolCalls.first?.id == "c1")
        #expect(stream.toolCalls.first?.arguments == #"{"kind":"movie"}"#)
    }

    private func item(_ id: Int, owned: Bool = false) -> DiscoverItem {
        let r = SearchResult(
            externalId: id, foreignId: String(id), title: "T\(id)", subtitle: nil,
            year: 2010, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: 100,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: owned ? id : nil
        )
        return DiscoverItem(result: r)
    }

    @Test("pipeline keeps pick order across feeds and filters what the deck must not get")
    func pipeline() async {
        let setup = QuizDeckPipeline.Setup(kind: "movie", libraryMode: "new", append: false, mood: "m",
                                           shown: [], suppressed: ["tmdb:4"], delivers: false)
        let pipeline = QuizDeckPipeline(setup: setup, width: 2) { [self] pick in
            guard let id = pick.tmdbId else { return nil }
            // Earlier picks finish later, so release order is what is tested.
            try? await Task.sleep(for: .milliseconds(10 * (6 - id)))
            return id == 3 ? nil : item(id, owned: id == 2)
        }
        let picks = (1...5).map { id -> QuizDeckPipeline.Pick in (title: "T" + String(id), year: nil, tmdbId: id) }
        await pipeline.feed(Array(picks.prefix(2)))
        await pipeline.feed(picks, isFinal: true)
        let outcome = await pipeline.finish()
        #expect(outcome.resolved.map(\.result.externalId) == [1, 2, 4, 5])
        #expect(outcome.delivered == ["tmdb:1", "tmdb:5"])
        #expect(outcome.unresolved == ["T3"])
    }
}
