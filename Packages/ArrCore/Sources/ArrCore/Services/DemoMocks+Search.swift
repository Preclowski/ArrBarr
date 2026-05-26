import Foundation

// Search-result pools per source — backs the demo SearchClient.

extension DemoMocks {
    // MARK: - Search results

    public static func searchResults(for query: String, source: QueueItem.Source) -> [SearchResult] {
        let pool: [SearchResult]
        switch source {
        case .radarr:   pool = radarrSearchPool
        case .sonarr:   pool = sonarrSearchPool
        case .lidarr:   pool = lidarrSearchPool
        case .whisparr: pool = whisparrSearchPool
        }
        guard !query.isEmpty else { return Array(pool.prefix(6)) }
        let q = query.lowercased()
        return pool.filter { result in
            result.title.lowercased().contains(q)
                || (result.overview?.lowercased().contains(q) ?? false)
                || result.genres.contains(where: { $0.lowercased().contains(q) })
        }
    }

    static var radarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 10003, foreignId: "10003",
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
                source: .radarr
            ),
            SearchResult(
                id: 10004, foreignId: "10004",
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
                source: .radarr
            ),
            SearchResult(
                id: 10005, foreignId: "10005",
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
                source: .radarr
            ),
            SearchResult(
                id: 10006, foreignId: "10006",
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
                source: .radarr
            ),
            SearchResult(
                id: 10007, foreignId: "10007",
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
                source: .radarr
            ),
            SearchResult(
                id: 10008, foreignId: "10008",
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
                source: .radarr
            ),
        ]
    }

    static var lidarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 30001, foreignId: "b7ffd2af-418f-4be2-bdd1-22f8b48613da",
                title: "Nine Inch Nails",
                subtitle: "Industrial rock",
                year: nil,
                rating: 8.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Trent Reznor's industrial-rock project. Released the four-volume instrumental 'Ghosts I-IV' under Creative Commons in 2008.",
                runtime: nil,
                genres: ["Industrial", "Rock", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "NIN", seed: "ninghosts", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30002, foreignId: "1ce18a52-ca5f-4f34-9bc6-5f2af0d33f5e",
                title: "Brad Sucks",
                subtitle: "One-man band",
                year: nil,
                rating: 7.2,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Ottawa one-man indie pop project. Every album he's released has been free / Creative Commons since 2003.",
                runtime: nil,
                genres: ["Indie", "Pop"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Brad Sucks", seed: "bradsucks", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30003, foreignId: "30c4c46c-2c4e-44a3-b9f2-c0ultonforeignid",
                title: "Jonathan Coulton",
                subtitle: "Geek folk",
                year: nil,
                rating: 7.8,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "American musician known for 'Code Monkey' and 'Still Alive' (Portal). Releases most work under CC-BY-NC.",
                runtime: nil,
                genres: ["Folk", "Comedy", "Indie"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Coulton", seed: "coultonsomeguys", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30004, foreignId: "kevinmacleod-incompetech",
                title: "Kevin MacLeod",
                subtitle: "Royalty-free composer",
                year: nil,
                rating: 7.0,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Prolific incompetech.com composer. Over 2000 royalty-free tracks under CC-BY 4.0 — every YouTube tutorial ever uses his work.",
                runtime: nil,
                genres: ["Soundtrack", "Ambient", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Kevin MacLeod", seed: "kevinmacleod", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30005, foreignId: "tobu-musicbrainz",
                title: "Tobu",
                subtitle: "Electronic / EDM",
                year: nil,
                rating: 7.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Latvian electronic producer who releases under No Copyright Sounds. Heavy presence on YouTube-creator playlists.",
                runtime: nil,
                genres: ["EDM", "Electronic", "House"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Tobu", seed: "tobu", w: 200, h: 200),
                source: .lidarr
            ),
            SearchResult(
                id: 30006, foreignId: "komiku-fma",
                title: "Komiku",
                subtitle: "Chiptune / 8-bit",
                year: nil,
                rating: 7.1,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "French chiptune composer. Whole catalog on Free Music Archive under CC0 — game devs and podcasters love them.",
                runtime: nil,
                genres: ["Chiptune", "Soundtrack", "Electronic"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Komiku", seed: "komiku", w: 200, h: 200),
                source: .lidarr
            ),
        ]
    }

    static var whisparrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 40001, foreignId: "40001",
                title: "Kitten Cam: Backyard Drama", subtitle: nil,
                year: 2024,
                rating: 8.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A long-running observational documentary about feline politics in a suburban garden. Episode count varies depending on neighbour cats.",
                runtime: 24,
                genres: ["Documentary", "Comedy"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Kitten Cam", seed: "kitten:neo", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40002, foreignId: "40002",
                title: "The Black Cat Chronicles", subtitle: nil,
                year: 2023,
                rating: 7.8,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Award-winning short film series following the social lives of three sibling cats sharing a Brooklyn apartment.",
                runtime: 18,
                genres: ["Short", "Drama"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Black Cat", seed: "kitten:millie", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40003, foreignId: "40003",
                title: "Nine Lives of Mittens", subtitle: nil,
                year: 2022,
                rating: 7.1,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "An anthology, one short per life. Tenth episode somehow exists.",
                runtime: 22,
                genres: ["Anthology", "Drama"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Mittens", seed: "kitten:poppy", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40004, foreignId: "40004",
                title: "Whiskers & Whispers", subtitle: nil,
                year: 2024,
                rating: 6.9,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "ASMR podcast hosted by three cats. Episodes are mostly purring with occasional commentary on the texture of cardboard boxes.",
                runtime: 32,
                genres: ["Podcast", "Lifestyle"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Whiskers", seed: "kitten:bella", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40005, foreignId: "40005",
                title: "Cat Burglar", subtitle: nil,
                year: 2021,
                rating: 7.3,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Mockumentary about a tabby who keeps stealing tools from the neighbour's workshop. Three seasons, no leads.",
                runtime: 26,
                genres: ["Mockumentary", "Crime", "Comedy"],
                network: "Whisparr Studio",
                certification: nil,
                posterURL: poster(label: "Cat Burglar", seed: "kitten:g", w: 200, h: 300),
                source: .whisparr
            ),
            SearchResult(
                id: 40006, foreignId: "40006",
                title: "Garage Cat Files", subtitle: nil,
                year: 2024,
                rating: 7.6,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Industrial-cinema treatment of a stray that adopted a mechanic's garage. Lots of slow pans and one bench grinder.",
                runtime: 41,
                genres: ["Documentary", "Drama"],
                network: nil,
                certification: nil,
                posterURL: poster(label: "Garage Cat", seed: "kitten:mu", w: 200, h: 300),
                source: .whisparr
            ),
        ]
    }

    static var sonarrSearchPool: [SearchResult] {
        [
            SearchResult(
                id: 20001, foreignId: "20001",
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
                source: .sonarr
            ),
            SearchResult(
                id: 20002, foreignId: "20002",
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
                source: .sonarr
            ),
            SearchResult(
                id: 20003, foreignId: "20003",
                title: "Northern Cascade", subtitle: "2 seasons",
                year: 2023,
                rating: 8.4,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A team of glaciologists, climbers, and a reluctant journalist disappear in the Cascade range. Each season unwinds the timeline differently — what they took with them, what they left behind, and what was already there before they arrived.",
                runtime: 52,
                genres: ["Drama", "Mystery", "Thriller"],
                network: "Demo Streaming",
                certification: nil,
                posterURL: poster(label: "Northern Cascade", seed: "northerncascade", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20004, foreignId: "20004",
                title: "Spring Tales", subtitle: "1 season",
                year: 2019,
                rating: 8.0,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "Animated anthology of folklore from the perspective of small things. Pollen-cam.",
                runtime: 22,
                genres: ["Animation", "Family", "Drama"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Spring Tales", seed: "spring", w: 200, h: 300),
                source: .sonarr
            ),
            SearchResult(
                id: 20005, foreignId: "20005",
                title: "Cosmos Laundromat", subtitle: "Pilot",
                year: 2015,
                rating: 7.5,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: "A multiversal salesman makes a pitch to a suicidal sheep. Open-movie pilot.",
                runtime: 12,
                genres: ["Animation", "Drama", "Fantasy"],
                network: "Blender Foundation",
                certification: nil,
                posterURL: poster(label: "Cosmos Laundromat", seed: "cosmoslaundromat", w: 200, h: 300),
                source: .sonarr
            ),
        ]
    }
}
