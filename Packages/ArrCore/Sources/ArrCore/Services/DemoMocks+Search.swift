import Foundation

// Search-result pools the demo chat draws its suggestions from.

extension DemoMocks {
    static var radarrSearchPool: [SearchResult] {
        [
            SearchResult(
                externalId: 10003, foreignId: "10003",
                title: "Elephants Dream", subtitle: nil,
                year: 2006,
                rating: 7.0,
                imdb: 6.8, rottenTomatoes: 79, metacritic: 71,
                overview: "Two characters argue about the nature of the strange world they inhabit. Blender's first ever open movie — short, surreal, and a watershed moment for free / open-source CGI in 2006.",
                runtime: 11,
                genres: ["Animation", "Short", "Sci-Fi"],
                network: "Blender Foundation",
                certification: "PG",
                posterURL: poster(label: "Elephants Dream", seed: "elephantsdream", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010003"
            ),
            SearchResult(
                externalId: 10004, foreignId: "10004",
                title: "Spring", subtitle: nil,
                year: 2019,
                rating: 7.8,
                imdb: 7.5, rottenTomatoes: 91, metacritic: 82,
                overview: "A young shepherd girl and her dog encounter ancient creatures during the spring melt. Blender's most painterly open-movie short — every frame deliberately staged like a watercolour.",
                runtime: 8,
                genres: ["Animation", "Family", "Adventure"],
                network: "Blender Foundation",
                certification: "G",
                posterURL: poster(label: "Spring", seed: "spring", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010004"
            ),
            SearchResult(
                externalId: 10005, foreignId: "10005",
                title: "Charge", subtitle: nil,
                year: 2018,
                rating: 7.0,
                imdb: 6.9, rottenTomatoes: nil, metacritic: nil,
                overview: "A short film about a robot who has to choose between his owner and his charging cable. Maker-built, shot on consumer-grade rigs, and released openly. Demo entry for a small indie sci-fi short.",
                runtime: 9,
                genres: ["Sci-Fi", "Short", "Drama"],
                network: nil,
                certification: "PG",
                posterURL: poster(label: "Charge", seed: "charge", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010005"
            ),
            SearchResult(
                externalId: 10006, foreignId: "10006",
                title: "Agent 327: Operation Barbershop", subtitle: nil,
                year: 2017,
                rating: 7.4,
                imdb: 7.2, rottenTomatoes: 88, metacritic: nil,
                overview: "A Dutch comic-book spy walks into a barbershop and out into a slapstick brawl. Blender Animation Studio's pilot for an Agent 327 feature — three minutes of bouncy character animation that doubles as a tech demo for the EEVEE realtime renderer.",
                runtime: 4,
                genres: ["Animation", "Action", "Comedy"],
                network: "Blender Animation Studio",
                certification: "PG",
                posterURL: poster(label: "Agent 327", seed: "agent327", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010006"
            ),
            SearchResult(
                externalId: 10007, foreignId: "10007",
                title: "Hero", subtitle: nil,
                year: 2018,
                rating: 7.2,
                imdb: 7.0, rottenTomatoes: nil, metacritic: nil,
                overview: "Grease-pencil 2D animation about a small dog with a big imagination. Blender's first major showcase of fully integrated 2D-in-3D pipeline work — a love letter to hand-drawn cartoons rendered inside a 3D scene.",
                runtime: 4,
                genres: ["Animation", "Family"],
                network: "Blender Animation Studio",
                certification: "G",
                posterURL: poster(label: "Hero", seed: "hero2018", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010007"
            ),
            SearchResult(
                externalId: 10008, foreignId: "10008",
                title: "Coffee Run", subtitle: nil,
                year: 2020,
                rating: 7.1,
                imdb: 6.9, rottenTomatoes: nil, metacritic: nil,
                overview: "A frantic cup of coffee dashes through a city of frantic adults. Pure stylised motion design, mostly built in grease pencil and used as a stress test for Blender's grease-pencil performance.",
                runtime: 4,
                genres: ["Animation", "Short", "Comedy"],
                network: "Blender Animation Studio",
                certification: "G",
                posterURL: poster(label: "Coffee Run", seed: "coffeerun", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010008"
            ),
            SearchResult(
                externalId: 10009, foreignId: "10009",
                title: "Cosmos Laundromat", subtitle: nil,
                year: 2015,
                rating: 7.5,
                imdb: 7.3, rottenTomatoes: nil, metacritic: nil,
                overview: "Franck the suicidal sheep meets a multiversal salesman who promises any life he can imagine — for a price. Blender's experimental open-movie pilot, and a showcase for its character-animation and hair-shading pipelines.",
                runtime: 12,
                genres: ["Animation", "Drama", "Fantasy"],
                network: "Blender Foundation",
                certification: "PG",
                posterURL: poster(label: "Cosmos Laundromat", seed: "cosmoslaundromat", w: 200, h: 300),
                source: .radarr,
                imdbId: "tt0010009"
            ),
        ]
    }

    static var sonarrSearchPool: [SearchResult] {
        [
            SearchResult(
                externalId: 20001, foreignId: "20001",
                title: "Pioneer One", subtitle: "1 season",
                year: 2010,
                rating: 7.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "BitTorrent-funded sci-fi thriller about a Soviet capsule that re-enters the atmosphere over Montana. Each episode was paid for by viewer donations after the previous one shipped.",
                runtime: 35,
                genres: ["Drama", "Mystery", "Sci-Fi"],
                network: "VODO",
                certification: nil,
                posterURL: poster(label: "Pioneer One", seed: "pioneerone", w: 200, h: 300),
                source: .sonarr,
                imdbId: "tt0020001"
            ),
            SearchResult(
                externalId: 20002, foreignId: "20002",
                title: "Caminandes", subtitle: "1 season",
                year: 2013,
                rating: 7.6,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A llama, a fence, and a steady supply of bad ideas. Blender Foundation's silent slapstick anthology.",
                runtime: 5,
                genres: ["Animation", "Comedy", "Family"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Caminandes", seed: "caminandes", w: 200, h: 300),
                source: .sonarr,
                imdbId: "tt0020002"
            ),
        ]
    }
}
