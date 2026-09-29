import Foundation
import MediaKit

/// Demo chat: real providers need credentials or an on-device model, so this answers
/// with pre-executed `suggest_titles`-shaped results from canned data.
struct DemoChatProvider: LLMProvider {
    init() {}
    var isAvailable: Bool { true }

    func respond(prompt: String, tools: [ToolDefinition], history: [ChatMessage]) async throws -> LLMResponse {
        // A short delay so the "thinking" indicator shows; instant replies read as canned.
        try? await Task.sleep(nanoseconds: 600_000_000)

        let lowered = prompt.lowercased()
        // No keyword match alternates by history length, so back-to-back prompts show both kinds.
        let kind: SuggestionKind = {
            if Self.containsAny(lowered, words: ["series", "show", "tv", "season", "episode", "serial", "serie"]) {
                return .series
            }
            if Self.containsAny(lowered, words: ["movie", "film", "cinema", "movies", "films"]) {
                return .movie
            }
            return (history.filter { $0.role == .assistant }.count % 2 == 0) ? .movie : .series
        }()

        // Quiz prompts open the real deck, as `discover_in_quiz` does live.
        if Self.containsAny(lowered, words: ["quiz", "swipe"]) {
            return await Self.quizResponse(kind: kind)
        }

        // Deterministic per prompt, but different prompts shuffle the order.
        let picks = Self.pick(kind: kind, prompt: prompt)

        let text = Self.summary(kind: kind, count: picks.count)
        let rich: ChatRichContent = (kind == .series)
            ? .searchSeriesResults(picks)
            : .searchMovieResults(picks)

        let toolCall = ToolCall(
            id: nil,
            name: "suggest_titles",
            arguments: .object([
                "kind": .string(kind == .series ? "series" : "movie"),
                "items": .array(picks.map { result in
                    var obj: [String: JSONValue] = ["title": .string(result.title)]
                    if let y = result.year { obj["year"] = .number(Double(y)) }
                    return .object(obj)
                }),
            ])
        )
        let toolOutput = ToolCallOutput(text: text, rich: rich)

        return LLMResponse(
            text: text,
            toolCalls: [toolCall],
            toolResults: [toolOutput]
        )
    }

    // MARK: - Routing helpers

    private enum SuggestionKind { case series, movie }

    private static func containsAny(_ haystack: String, words: [String]) -> Bool {
        for w in words where haystack.contains(w) { return true }
        return false
    }

    private static func summary(kind: SuggestionKind, count: Int) -> String {
        let template: String = (kind == .series)
            ? String(localized: "chat.hereAreLldSeries.tooltip", bundle: .module)
            : String(localized: "chat.hereAreLldFilms.tooltip", bundle: .module)
        return String(format: template, count)
    }

    // MARK: - Quiz deck

    /// Mirrors `LocalToolBackend.assembleDeck`.
    private static func quizResponse(kind: SuggestionKind) async -> LLMResponse {
        let pool = (kind == .series) ? seriesPool : moviePool
        let items = pool.map { result in
            DiscoverItem(
                result: result,
                kind: (kind == .series) ? .show : .movie,
                reason: quizReasonKeys[result.title].map {
                    NSLocalizedString($0, bundle: .module, comment: "")
                }
            )
        }
        let mood = NSLocalizedString(
            kind == .series ? "demo.quizMood.series" : "demo.quizMood.movies",
            bundle: .module, comment: "")
        AppMessages.post(AppMessages.OpenDiscoverQuiz(items: items, append: false))
        let text = NSLocalizedString("demo.quizOpened", bundle: .module, comment: "")
        let posters = items.prefix(3).compactMap { $0.result.posterURL }
        return LLMResponse(
            text: text,
            toolCalls: [ToolCall(id: nil, name: "discover_in_quiz", arguments: .object([
                "mood": .string(mood),
                "kind": .string(kind == .series ? "series" : "movie"),
            ]))],
            toolResults: [ToolCallOutput(text: text, rich: .discoverSession(mood: mood, posterURLs: Array(posters)))]
        )
    }

    /// Keyed by pool title, localized at use.
    private static let quizReasonKeys: [String: String] = [
        "Big Buck Bunny": "demo.quizReason.bigbuckbunny",
        "Sintel": "demo.quizReason.sintel",
        "Tears of Steel": "demo.quizReason.tearsofsteel",
        "Elephants Dream": "demo.quizReason.elephantsdream",
        "Spring": "demo.quizReason.spring",
        "Cosmos Laundromat": "demo.quizReason.cosmoslaundromat",
        "Pioneer One": "demo.quizReason.pioneerone",
        "Caminandes": "demo.quizReason.caminandes",
    ]

    // MARK: - Canned content

    /// A prompt hash picks the starting offset of a contiguous slice.
    private static func pick(kind: SuggestionKind, prompt: String) -> [SearchResult] {
        let pool = (kind == .series) ? seriesPool : moviePool
        guard !pool.isEmpty else { return [] }
        let count = min(4, pool.count)
        let offset = abs(prompt.hashValue) % pool.count
        return (0..<count).map { i in pool[(offset + i) % pool.count] }
    }

    // The same real artwork the queue and library fixtures use, so screenshots show actual
    // covers without a TMDB key.
    private static let moviePool: [SearchResult] = [
        SearchResult(
            externalId: 10001, foreignId: "10001",
            title: "Big Buck Bunny", subtitle: nil, year: 2008,
            rating: 7.0, imdb: 6.4, rottenTomatoes: 81, metacritic: nil,
            overview: "A giant rabbit with a heart bigger than himself takes gentle, elaborate revenge on three bullying rodents. Blender's second open movie, and still its most famous.",
            runtime: 10,
            genres: ["Animation", "Comedy", "Short"],
            network: "Blender Foundation", certification: "G",
            posterURL: DemoMocks.poster(label: "Big Buck Bunny", seed: "bigbuckbunny"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            externalId: 10002, foreignId: "10002",
            title: "Sintel", subtitle: nil, year: 2010,
            rating: 7.6, imdb: 7.4, rottenTomatoes: nil, metacritic: nil,
            overview: "A lonely girl crosses mountains and ruins searching for the dragon she once nursed back to health. Blender's third open movie — the sad one.",
            runtime: 15,
            genres: ["Animation", "Fantasy", "Short"],
            network: "Blender Foundation", certification: "PG",
            posterURL: DemoMocks.poster(label: "Sintel", seed: "sintel"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            externalId: 10010, foreignId: "10010",
            title: "Tears of Steel", subtitle: nil, year: 2012,
            rating: 6.9, imdb: 6.7, rottenTomatoes: nil, metacritic: nil,
            overview: "A small group of warriors and scientists gather at the foot of an Amsterdam landmark to make a desperate stand against a robot uprising. Blender's first live-action VFX open movie.",
            runtime: 12,
            genres: ["Action", "Sci-Fi", "Short"],
            network: "Blender Foundation", certification: "PG",
            posterURL: DemoMocks.poster(label: "Tears of Steel", seed: "tearsofsteel"),
            source: .radarr, inLibraryArrId: nil
        ),
    ] + DemoMocks.radarrSearchPool.filter {
        // only the discovery entries with real artwork seeds
        ["Elephants Dream", "Spring", "Cosmos Laundromat"].contains($0.title)
    }

    private static let seriesPool: [SearchResult] = DemoMocks.sonarrSearchPool
}
