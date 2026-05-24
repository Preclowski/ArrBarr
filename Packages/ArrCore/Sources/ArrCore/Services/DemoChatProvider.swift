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
            ? String(localized: "Here are %lld series you might enjoy.", bundle: .module)
            : String(localized: "Here are %lld films you might enjoy.", bundle: .module)
        return String(format: template, count)
    }

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

    private static func poster(_ text: String, bg: String) -> URL? {
        let label = text
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26") ?? text
        return URL(string: "https://placehold.co/200x300/\(bg)/ffffff/png?text=\(label)&font=lato")
    }

    private static let moviePool: [SearchResult] = [
        SearchResult(
            id: 335984, foreignId: "335984",
            title: "Blade Runner 2049", subtitle: nil, year: 2017,
            rating: 8.0, imdb: 8.0, rottenTomatoes: 88, metacritic: 81,
            overview: "Thirty years after the events of the first film, a new blade runner unearths a long-buried secret that has the potential to plunge what's left of society into chaos.",
            runtime: 164,
            genres: ["Sci-Fi", "Drama", "Mystery"],
            network: "Warner Bros.", certification: "R",
            posterURL: poster("Blade Runner 2049", bg: "1c3859"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 693134, foreignId: "693134",
            title: "Dune: Part Two", subtitle: nil, year: 2024,
            rating: 8.4, imdb: 8.5, rottenTomatoes: 92, metacritic: 79,
            overview: "Paul Atreides unites with the Fremen and begins a spiritual and martial journey to become Muad'Dib, while seeking revenge against the conspirators who destroyed his family.",
            runtime: 166,
            genres: ["Sci-Fi", "Adventure"],
            network: "Legendary", certification: "PG-13",
            posterURL: poster("Dune Part Two", bg: "4a2c1d"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 666277, foreignId: "666277",
            title: "Past Lives", subtitle: nil, year: 2023,
            rating: 7.9, imdb: 7.8, rottenTomatoes: 96, metacritic: 94,
            overview: "Nora and Hae Sung, two deeply connected childhood friends, are wrest apart after Nora's family emigrates from South Korea. Two decades later, they are reunited for one fateful week.",
            runtime: 105,
            genres: ["Romance", "Drama"],
            network: "A24", certification: "PG-13",
            posterURL: poster("Past Lives", bg: "5c1f1f"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 545611, foreignId: "545611",
            title: "Everything Everywhere All at Once", subtitle: nil, year: 2022,
            rating: 8.0, imdb: 7.8, rottenTomatoes: 94, metacritic: 81,
            overview: "An aging Chinese immigrant is swept up in an insane adventure, where she alone can save the world by exploring other universes connecting with the lives she could have led.",
            runtime: 139,
            genres: ["Action", "Adventure", "Sci-Fi"],
            network: "A24", certification: "R",
            posterURL: poster("Everything Everywhere", bg: "3b1d52"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 76600, foreignId: "76600",
            title: "Avatar: The Way of Water", subtitle: nil, year: 2022,
            rating: 7.6, imdb: 7.6, rottenTomatoes: 76, metacritic: 67,
            overview: "Set more than a decade after the events of the first film, learn the story of the Sully family, the trouble that follows them, the lengths they go to keep each other safe, and the tragedies they endure.",
            runtime: 192,
            genres: ["Sci-Fi", "Adventure"],
            network: "20th Century Studios", certification: "PG-13",
            posterURL: poster("Avatar Way of Water", bg: "1f4a52"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 502356, foreignId: "502356",
            title: "The Super Mario Bros. Movie", subtitle: nil, year: 2023,
            rating: 7.0, imdb: 7.0, rottenTomatoes: 59, metacritic: 46,
            overview: "While working underground to fix a water main, Brooklyn plumbers — and brothers — Mario and Luigi are transported down a mysterious pipe and wander into a magical new world.",
            runtime: 92,
            genres: ["Animation", "Family", "Adventure"],
            network: "Illumination", certification: "PG",
            posterURL: poster("Super Mario Bros", bg: "5c1f1f"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 872585, foreignId: "872585",
            title: "Oppenheimer", subtitle: nil, year: 2023,
            rating: 8.1, imdb: 8.3, rottenTomatoes: 93, metacritic: 90,
            overview: "The story of J. Robert Oppenheimer's role in the development of the atomic bomb during World War II.",
            runtime: 180,
            genres: ["Drama", "History", "Biography"],
            network: "Universal", certification: "R",
            posterURL: poster("Oppenheimer", bg: "3a3a1f"),
            source: .radarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 346698, foreignId: "346698",
            title: "Barbie", subtitle: nil, year: 2023,
            rating: 7.1, imdb: 6.8, rottenTomatoes: 88, metacritic: 80,
            overview: "Barbie suffers a crisis that leads her to question her world and her existence.",
            runtime: 114,
            genres: ["Comedy", "Adventure", "Fantasy"],
            network: "Warner Bros.", certification: "PG-13",
            posterURL: poster("Barbie", bg: "4a1f4a"),
            source: .radarr, inLibraryArrId: nil
        ),
    ]

    private static let seriesPool: [SearchResult] = [
        SearchResult(
            id: 369802, foreignId: "369802",
            title: "Severance", subtitle: "2 seasons", year: 2022,
            rating: 8.7, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "Mark leads a team of office workers whose memories have been surgically divided between their work and personal lives. When a mysterious colleague appears outside of work, it begins a journey to discover the truth.",
            runtime: 55,
            genres: ["Sci-Fi", "Thriller", "Drama"],
            network: "Apple TV+", certification: nil,
            posterURL: poster("Severance", bg: "1c3859"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 388477, foreignId: "388477",
            title: "The Bear", subtitle: "3 seasons", year: 2022,
            rating: 8.6, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "A young chef from the fine dining world returns to Chicago to run his deceased brother's Italian beef sandwich shop.",
            runtime: 30,
            genres: ["Comedy", "Drama"],
            network: "FX", certification: nil,
            posterURL: poster("The Bear", bg: "5c1f1f"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 386818, foreignId: "386818",
            title: "Andor", subtitle: "1 season", year: 2022,
            rating: 8.4, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "In an era filled with danger, deception and intrigue, Cassian Andor embarks on the path that is destined to turn him into a rebel hero.",
            runtime: 45,
            genres: ["Sci-Fi", "Drama", "Action"],
            network: "Disney+", certification: nil,
            posterURL: poster("Andor", bg: "1d4a3a"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 408463, foreignId: "408463",
            title: "Shogun", subtitle: "1 season", year: 2024,
            rating: 8.8, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "In Japan in the year 1600, at the dawn of a century-defining civil war, Lord Yoshii Toranaga is fighting for his life as his enemies on the Council of Regents unite against him.",
            runtime: 60,
            genres: ["Drama", "History"],
            network: "FX", certification: nil,
            posterURL: poster("Shogun", bg: "4a2c1d"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 392276, foreignId: "392276",
            title: "House of the Dragon", subtitle: "2 seasons", year: 2022,
            rating: 8.4, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "The Targaryen dynasty is at the absolute apex of its power, with more than 15 dragons under their yoke. Most empires crumble from such heights. In the case of the Targaryens, their slow fall begins almost 193 years before the events of Game of Thrones.",
            runtime: 60,
            genres: ["Drama", "Fantasy", "Action"],
            network: "HBO", certification: nil,
            posterURL: poster("House of the Dragon", bg: "3b1d52"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 392256, foreignId: "392256",
            title: "Fallout", subtitle: "1 season", year: 2024,
            rating: 8.4, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "In a future, post-apocalyptic Los Angeles brought about by nuclear decimation, citizens must live in underground bunkers to protect themselves from radiation, mutants and bandits.",
            runtime: 60,
            genres: ["Sci-Fi", "Drama", "Adventure"],
            network: "Prime Video", certification: nil,
            posterURL: poster("Fallout", bg: "3a3a1f"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 396583, foreignId: "396583",
            title: "The Last of Us", subtitle: "1 season", year: 2023,
            rating: 8.7, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "Twenty years after modern civilization has been destroyed, Joel, a hardened survivor, is hired to smuggle Ellie, a 14-year-old girl, out of an oppressive quarantine zone.",
            runtime: 60,
            genres: ["Drama", "Sci-Fi", "Horror"],
            network: "HBO", certification: nil,
            posterURL: poster("The Last of Us", bg: "1d4a3a"),
            source: .sonarr, inLibraryArrId: nil
        ),
        SearchResult(
            id: 359774, foreignId: "359774",
            title: "Slow Horses", subtitle: "4 seasons", year: 2022,
            rating: 8.3, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: "Follow a team of British intelligence agents who serve as a dumping ground department of MI5 due to their career-ending mistakes.",
            runtime: 50,
            genres: ["Drama", "Thriller", "Spy"],
            network: "Apple TV+", certification: nil,
            posterURL: poster("Slow Horses", bg: "1f4a52"),
            source: .sonarr, inLibraryArrId: nil
        ),
    ]
}
