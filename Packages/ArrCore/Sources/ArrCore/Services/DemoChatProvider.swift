import Foundation

/// LLMProvider used when `DemoMode.isActive` is true. Real providers
/// (OpenAI / FoundationModels) require credentials or on-device model
/// availability — neither is reliable in a demo context. Instead of
/// failing or stalling, we hand the chat pipeline a pre-executed
/// `suggest_titles`-shaped tool result populated from canned data so
/// every prompt yields the rich-card UX a demo viewer expects.
///
/// Strategy notes (vs the alternatives):
///   - Intercepting at the `ChatViewModel.send` level would couple the
///     VM to demo-mode awareness; the VM stays provider-agnostic this
///     way.
///   - Stubbing the existing providers would still require wiring a
///     fake `invokeTool` to produce the rich result; that's strictly
///     more code and more types-to-modify than a fresh provider.
///   - A bespoke provider plugs into the existing factory switch,
///     reuses `LLMResponse(toolResults:)` (the "pre-executed" path the
///     FoundationModels provider already takes), and the rest of the
///     pipeline — tool-message rendering, RichToolResultView — is
///     completely unchanged.
public struct DemoChatProvider: LLMProvider {
    public init() {}
    public var isAvailable: Bool { true }

    public func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
        // A tiny artificial latency so the "thinking" indicator gets a
        // moment on-screen — without it, replies feel instant in a way
        // that reads as canned. 600ms is short enough to stay snappy.
        try? await Task.sleep(nanoseconds: 600_000_000)

        let lowered = prompt.lowercased()
        // Keyword routing: anything that smells like TV picks series,
        // anything that smells like film picks movies, otherwise we
        // alternate per-call using the history length so back-to-back
        // prompts in the same chat show both kinds.
        let kind: SuggestionKind = {
            if Self.containsAny(lowered, words: ["series", "show", "tv", "season", "episode", "serial", "serie"]) {
                return .series
            }
            if Self.containsAny(lowered, words: ["movie", "film", "cinema", "movies", "films"]) {
                return .movie
            }
            return (history.filter { $0.role == .assistant }.count % 2 == 0) ? .movie : .series
        }()

        // The quiz CTA (and any prompt that says quiz/swipe) must open the
        // real swipe deck, exactly like the live provider routing through
        // `discover_in_quiz` — answering with a suggestion list here read
        // as "demo has no quiz".
        if Self.containsAny(lowered, words: ["quiz", "swipe"]) {
            return await Self.quizResponse(kind: kind)
        }

        // Deterministic selection from the canned pool — same prompt
        // always yields the same picks, but different prompts shuffle
        // the order so the demo doesn't feel static across turns.
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

    /// Opens the Discover deck with the whole demo pool, mirroring
    /// `LocalToolBackend.assembleDeck`: post `.arrBarrOpenDiscoverQuiz`,
    /// answer with the `.discoverSession` resume card.
    private static func quizResponse(kind: SuggestionKind) async -> LLMResponse {
        let pool = (kind == .series) ? seriesPool : moviePool
        let items = pool.map { result in
            DiscoverItem(
                result: result,
                action: (kind == .series) ? .addToSonarr : .addToRadarr,
                originLabel: .llm,
                kind: (kind == .series) ? .show : .movie,
                reason: quizReasonKeys[result.title].map {
                    NSLocalizedString($0, bundle: .module, comment: "")
                }
            )
        }
        let mood = NSLocalizedString(
            kind == .series ? "demo.quizMood.series" : "demo.quizMood.movies",
            bundle: .module, comment: "")
        await MainActor.run {
            NotificationCenter.default.post(
                name: .arrBarrOpenDiscoverQuiz,
                object: nil,
                userInfo: ["mood": mood, "items": items, "append": false]
            )
        }
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

    /// "Why this card" hooks, keyed by pool title — localized at use.
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

    /// Deterministically pick 4 items from the canned pool. We hash the
    /// prompt to choose a starting offset, then take a contiguous slice
    /// — gives variety across prompts without ever returning fewer than
    /// the pool's worth of variety on repeats.
    private static func pick(kind: SuggestionKind, prompt: String) -> [SearchResult] {
        let pool = (kind == .series) ? seriesPool : moviePool
        guard !pool.isEmpty else { return [] }
        let count = min(4, pool.count)
        let offset = abs(prompt.hashValue) % pool.count
        return (0..<count).map { i in pool[(offset + i) % pool.count] }
    }

    // Suggestion cards reuse the demo universe's real artwork — the same
    // Wikipedia / Cover Art Archive sources the queue and library fixtures
    // use — so chat and quiz shots render actual covers without a TMDB key
    // (flat placeholder tiles read as broken in marketing screenshots).
    // Queue titles (Big Buck Bunny, Sintel, Tears of Steel) join the
    // discovery-only Blender shorts; the series pool is the demo search
    // pool verbatim.
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
