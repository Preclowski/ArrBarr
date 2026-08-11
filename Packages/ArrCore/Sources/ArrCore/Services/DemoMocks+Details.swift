import Foundation

// Detail-view fixtures: Radarr movie / Sonarr series + episodes / Lidarr album + tracks for each demo entityId.

extension DemoMocks {
    // MARK: - Detail-view fixtures
    //
    // The detail panels (RadarrMovieDetail, SonarrSeriesDetail,
    // LidarrAlbumDetail) feed `MediaHeaderCard`, the season list, the
    // existing-file banner, etc. Each entry below corresponds to a
    // queue item's `entityId` so DetailView can look up rich metadata
    // when the user taps a row.

    /// Lookup helper used by RadarrClient.fetchMovieDetails when
    /// DemoMode is active.
    public static func radarrMovieDetail(id: Int) -> RadarrMovieDetail? {
        radarrDetails[id]
    }

    public static func sonarrSeriesDetail(id: Int) -> SonarrSeriesDetail? {
        sonarrDetails[id]
    }

    public static func sonarrEpisodes(seriesId: Int) -> [SonarrEpisodeDetail] {
        sonarrEpisodeData[seriesId] ?? []
    }

    /// Synthesises a `SonarrEpisodeFile` for every downloaded episode in
    /// the demo series, so detail-view EpisodeRow can render its
    /// custom-format score in the right gutter (instead of falling back
    /// to the air date). Score is seeded from episodeFileId so it stays
    /// stable across reloads and varies row-to-row — same hash trick
    /// the queue-row mocks already use.
    public static func sonarrEpisodeFileMap(seriesId: Int) -> [Int: SonarrEpisodeFile] {
        // Qualities/formats are older than anything the manual-search fixtures
        // offer, so every candidate release reads as a genuine upgrade in the
        // diff rather than a lateral move.
        let tiers: [(quality: String, formats: [String])] = [
            ("HDTV-720p", ["x264", "AAC 2.0"]),
            ("WEBRip-480p", ["x264"]),
            ("WEBDL-1080p", ["x264", "AAC 2.0", "Repack"]),
        ]
        var map: [Int: SonarrEpisodeFile] = [:]
        for ep in sonarrEpisodes(seriesId: seriesId) where ep.hasFile == true {
            guard let fid = ep.episodeFileId else { continue }
            let score = 200 + (fid * 37) % 400      // deterministic spread 200…600
            let size = Int64(1_500_000_000 + (fid * 53) % 1_500_000_000)
            let tier = tiers[fid % tiers.count]
            let season = String(format: "%02d", ep.seasonNumber ?? 0)
            let number = String(format: "%02d", ep.episodeNumber ?? 0)
            map[fid] = SonarrEpisodeFile(
                id: fid,
                seriesId: seriesId,
                customFormats: tier.formats.enumerated().map { ArrCustomFormat(id: $0.offset + 1, name: $0.element) },
                customFormatScore: score,
                quality: ArrQuality(quality: ArrQuality.ArrQualityName(name: tier.quality)),
                size: size,
                relativePath: "Season \(season)/S\(season)E\(number).\(tier.quality).x264-OLD.mkv"
            )
        }
        return map
    }

    public static func lidarrAlbumDetail(id: Int) -> LidarrAlbumDetail? {
        lidarrDetails[id]
    }

    public static func lidarrTracks(albumId: Int) -> [LidarrTrackDetail] {
        lidarrTrackData[albumId] ?? []
    }

    /// `/artist/{id}` — assembled from the album fixtures' embedded artists so
    /// the artist view mirrors whatever the demo albums say.
    public static func lidarrArtistDetail(id: Int) -> LidarrArtistDetail? {
        let owned = lidarrDetails.values.filter { $0.artist?.id == id }
        guard let artist = owned.first?.artist else { return nil }
        let stats = owned.compactMap(\.statistics)
        return LidarrArtistDetail(
            id: id,
            artistName: artist.artistName,
            overview: owned
                .sorted { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
                .first?.overview,
            genres: Array(Set(owned.flatMap { $0.genres ?? [] })).sorted(),
            images: artist.images,
            foreignArtistId: artist.foreignArtistId,
            statistics: LidarrLibraryStatistics(
                albumCount: owned.count,
                trackCount: stats.compactMap(\.trackCount).reduce(0, +),
                trackFileCount: stats.compactMap(\.trackFileCount).reduce(0, +),
                sizeOnDisk: stats.compactMap(\.sizeOnDisk).reduce(0, +)
            ),
            ratings: nil,
            monitored: true
        )
    }

    /// `/album?artistId=N` — the artist's albums in the slim list shape.
    public static func lidarrArtistAlbums(artistId: Int) -> [LidarrAlbumListRecord] {
        lidarrDetails.values
            .filter { $0.artist?.id == artistId }
            .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
            .map { album in
                LidarrAlbumListRecord(
                    id: album.id,
                    title: album.title,
                    albumType: album.albumType,
                    releaseDate: album.releaseDate,
                    monitored: album.monitored,
                    statistics: album.statistics,
                    images: album.images
                )
            }
    }

    static func image(seed: String, kind: String = "poster") -> ArrImage {
        let url = poster(label: "", seed: seed, w: 220, h: 330)?.absoluteString
        return ArrImage(coverType: kind, url: url, remoteUrl: url)
    }

    static var radarrDetails: [Int: RadarrMovieDetail] {
        [
            201: RadarrMovieDetail(
                id: 201,
                title: "Big Buck Bunny",
                year: 2008,
                overview: "A large rabbit deals with three bullying rodents who terrorise the forest. Big Buck Bunny shows off the open-source Blender movie pipeline at peak whimsy — a benchmark short for compositing, fluid sims, and fur shading that tens of millions of streams later still works as a charming standalone.",
                runtime: 10,
                genres: ["Animation", "Comedy", "Family", "Short"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 6.5, votes: 24_000),
                    tmdb: RadarrRatingValue(value: 7.2, votes: 1_100),
                    metacritic: RadarrRatingValue(value: 78, votes: nil),
                    rottenTomatoes: RadarrRatingValue(value: 92, votes: nil)
                ),
                images: [image(seed: "bigbuckbunny")],
                studio: "Blender Foundation",
                certification: "G",
                titleSlug: "bigbuckbunny",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: true
            ),
            202: RadarrMovieDetail(
                id: 202,
                title: "Sintel",
                year: 2010,
                overview: "A girl scours a hostile world for her lost dragon companion. Blender's third open-movie short, fronted by a lush hand-drawn opening cut to live-action plates and a haunting Jan Morgenstern score; widely cited as the moment Blender's renderer crossed the line into 'good enough for theatrical' for short-form work.",
                runtime: 14,
                genres: ["Animation", "Adventure", "Drama", "Fantasy"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 8.0, votes: 7_300),
                    tmdb: RadarrRatingValue(value: 7.9, votes: 480),
                    metacritic: nil,
                    rottenTomatoes: RadarrRatingValue(value: 88, votes: nil)
                ),
                images: [image(seed: "sintel")],
                studio: "Blender Foundation",
                certification: "PG",
                titleSlug: "sintel",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: true
            ),
            203: RadarrMovieDetail(
                id: 203,
                title: "Tears of Steel",
                year: 2012,
                overview: "A small group of warriors and scientists gather at the foot of an Amsterdam landmark to make a desperate stand against a robot uprising. Blender's first big live-action / VFX hybrid — the project that pushed compositing, motion-capture cleanup, and node-based shading into Blender's main branch.",
                runtime: 12,
                genres: ["Action", "Sci-Fi", "Short"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 6.7, votes: 4_200),
                    tmdb: RadarrRatingValue(value: 6.9, votes: 320),
                    metacritic: nil,
                    rottenTomatoes: nil
                ),
                images: [image(seed: "tearsofsteel")],
                studio: "Blender Foundation",
                certification: "PG",
                titleSlug: "tearsofsteel",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: false
            ),
            // Library-only title: owned, nothing in flight. The other three all
            // have a queue row, which hides the detail view's search CTA — so
            // without this one the whole manual-search + upgrade-diff flow is
            // unreachable for movies in demo.
            204: RadarrMovieDetail(
                id: 204,
                title: "Elephants Dream",
                year: 2006,
                overview: "Two men argue about the nature of the strange machine world they inhabit. The first Blender open movie — every asset, scene and tool shipped alongside the film, which is why it still turns up in graphics coursework twenty years later.",
                runtime: 11,
                genres: ["Animation", "Short", "Sci-Fi"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 6.8, votes: 5_600),
                    tmdb: RadarrRatingValue(value: 7.0, votes: 410),
                    metacritic: nil,
                    rottenTomatoes: RadarrRatingValue(value: 79, votes: nil)
                ),
                images: [image(seed: "elephantsdream")],
                studio: "Blender Foundation",
                certification: "PG",
                titleSlug: "elephantsdream",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: true
            ),
        ]
    }

    /// Whisparr shares Radarr's detail shape. Two entries matching the demo
    /// queue's cat "nature films" — without them, tapping a Whisparr row in
    /// demo tried to reach a real server and surfaced a connection error.
    static var whisparrDetails: [Int: RadarrMovieDetail] {
        [
            401: RadarrMovieDetail(
                id: 401,
                title: "Kitten Cam: Backyard Drama",
                year: 2024,
                overview: "A long-running observational documentary about feline politics in a suburban garden. Episode count varies depending on which neighbour cats show up.",
                runtime: 24,
                genres: ["Documentary", "Comedy"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 8.4, votes: 220),
                    tmdb: RadarrRatingValue(value: 8.1, votes: 90),
                    metacritic: nil,
                    rottenTomatoes: nil
                ),
                images: [image(seed: "kitten:neo")],
                studio: "Whisparr Studio",
                certification: nil,
                titleSlug: "kitten-cam-backyard-drama",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: true
            ),
            402: RadarrMovieDetail(
                id: 402,
                title: "The Black Cat Chronicles",
                year: 2023,
                overview: "Award-winning short film series following the social lives of three sibling cats sharing a Brooklyn apartment.",
                runtime: 18,
                genres: ["Short", "Drama"],
                ratings: RadarrDetailRatings(
                    imdb: RadarrRatingValue(value: 7.8, votes: 310),
                    tmdb: RadarrRatingValue(value: 7.6, votes: 140),
                    metacritic: nil,
                    rottenTomatoes: nil
                ),
                images: [image(seed: "kitten:millie")],
                studio: "Whisparr Studio",
                certification: nil,
                titleSlug: "the-black-cat-chronicles",
                movieFile: nil,
                inCinemas: nil,
                status: "released",
                monitored: true
            ),
        ]
    }

    static var sonarrDetails: [Int: SonarrSeriesDetail] {
        [
            101: SonarrSeriesDetail(
                id: 101,
                title: "Pioneer One",
                year: 2010,
                overview: "A mysterious capsule re-enters the atmosphere over Montana. As the US government investigates, a deeper Cold War-era conspiracy starts to unravel. The first show ever crowdfunded on BitTorrent — released CC-BY-SA, episode by episode, while the world figured out how to pay creators directly.",
                genres: ["Drama", "Mystery", "Sci-Fi"],
                runtime: 35,
                ratings: SonarrDetailRatings(value: 7.4, votes: 1_840),
                network: "VODO",
                status: "ended",
                images: [image(seed: "pioneerone")],
                titleSlug: "pioneerone",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 3, episodeCount: 6, totalEpisodeCount: 6,
                        sizeOnDisk: 1_800_000_000, percentOfEpisodes: 50
                    )),
                    SonarrSeasonInfo(seasonNumber: 2, monitored: false, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2010-06-16",
                monitored: true
            ),
            102: SonarrSeriesDetail(
                id: 102,
                title: "Caminandes",
                year: 2013,
                overview: "Koro, a wide-eyed Patagonian llama, just wants to live his life — but the trail keeps giving him reasons not to. Short episodes of Blender Foundation slapstick that became a tutorial pipeline for character rigging, eye shading, and snow simulation.",
                genres: ["Animation", "Comedy", "Family"],
                runtime: 5,
                ratings: SonarrDetailRatings(value: 7.6, votes: 2_300),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "caminandes")],
                titleSlug: "caminandes",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 1, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 450_000_000, percentOfEpisodes: 25
                    )),
                ],
                firstAired: "2013-04-13",
                monitored: true
            ),
        ]
    }

    static var sonarrEpisodeData: [Int: [SonarrEpisodeDetail]] {
        [
            101: [ // Pioneer One
                episode(101, 1, 1, "Earthfall", "A capsule re-enters over rural Montana.", daysAgo: 700, hasFile: true),
                episode(102, 1, 2, "Tomorrow Belongs to Us", "DHS gets involved.", daysAgo: 690, hasFile: true),
                episode(103, 1, 3, "Endurance", "A doctor risks her career.", daysAgo: 680, hasFile: false),
                episode(104, 1, 4, "Brave New Earth", "The signal travels.", daysAgo: 670, hasFile: false),
                episode(105, 1, 5, "Foothold", "An offer no one can refuse.", daysAgo: 660, hasFile: false),
                episode(106, 1, 6, "What Remains", "Things break, others mend.", daysAgo: 650, hasFile: true),
                // Season 2 is unmonitored (see `sonarrDetails`), and Sonarr
                // cascades that to its episodes — so the demo shows the
                // combined "unmonitored + not aired" row state too.
                episode(201, 2, 1, "Reentry", "Aftermath.", daysAhead: 1, hasFile: false, monitored: false),
                episode(202, 2, 2, "Witness", "An unexpected ally.", daysAhead: 8, hasFile: false, monitored: false),
                episode(203, 2, 3, "Cold War Echo", "An old enemy.", daysAhead: 15, hasFile: false, monitored: false),
                episode(204, 2, 4, "Diaspora", "The cosmonaut speaks.", daysAhead: 22, hasFile: false, monitored: false),
            ],
            102: [ // Caminandes
                episode(301, 1, 1, "Llama Drama", "Koro meets a fence.", daysAgo: 1100, hasFile: true),
                episode(302, 1, 2, "Gran Dillama", "Koro meets a llama-vending machine.", daysAgo: 950, hasFile: false),
                episode(303, 1, 3, "Llamigos", "Koro meets a penguin.", daysAgo: 800, hasFile: false),
                episode(304, 1, 4, "Snow Day", "Koro climbs.", daysAhead: 2, hasFile: false),
            ],
        ]
    }

    static func episode(
        _ id: Int, _ season: Int, _ number: Int,
        _ title: String, _ overview: String,
        daysAgo: Int = -1, daysAhead: Int = -1,
        hasFile: Bool,
        monitored: Bool = true
    ) -> SonarrEpisodeDetail {
        let date: Date
        if daysAgo >= 0 {
            date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        } else if daysAhead >= 0 {
            date = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
        } else {
            date = Date()
        }
        let fmt = ISO8601DateFormatter()
        return SonarrEpisodeDetail(
            id: id, seasonNumber: season, episodeNumber: number,
            title: title, overview: overview,
            airDateUtc: fmt.string(from: date),
            hasFile: hasFile, monitored: monitored, runtime: 45,
            episodeFileId: hasFile ? id : nil
        )
    }

    static var lidarrDetails: [Int: LidarrAlbumDetail] {
        [
            301: LidarrAlbumDetail(
                id: 301,
                title: "Ghosts I-IV",
                overview: "Trent Reznor and Atticus Ross's 36-track instrumental sprawl, released directly to fans on a tiered model that essentially invented the modern artist-direct download. Available freely under CC-BY-NC-SA — perfect demo content for a music tracker.",
                releaseDate: "2008-03-02",
                genres: ["Electronic", "Industrial", "Ambient", "Instrumental"],
                ratings: LidarrDetailRatings(value: 8.2, votes: 4_500),
                images: [image(seed: "ninghosts", kind: "cover")],
                artist: LidarrArtist(
                    id: 301, artistName: "Nine Inch Nails",
                    foreignArtistId: "b7ffd2af-418f-4be2-bdd1-22f8b48613da",
                    images: [image(seed: "ninghosts", kind: "poster")]
                ),
                foreignAlbumId: "ghosts-i-iv-2008",
                albumType: "Album",
                duration: 1_960_000, // ~33 min
                statistics: LidarrAlbumStats(
                    trackCount: 36, trackFileCount: 12, totalTrackCount: 36,
                    sizeOnDisk: 280_000_000
                ),
                monitored: true
            ),
            302: LidarrAlbumDetail(
                id: 302,
                title: "Out of It",
                overview: "Brad Sucks's second self-released album of cynical, hooky DIY rock. Made in his basement, released for free, distributed via direct downloads and CC licensing — a poster child for the open-music movement Lidarr was built to track.",
                releaseDate: "2008-09-08",
                genres: ["Indie Rock", "Alternative", "DIY"],
                ratings: LidarrDetailRatings(value: 7.6, votes: 320),
                images: [image(seed: "bradsucks", kind: "cover")],
                artist: LidarrArtist(
                    id: 302, artistName: "Brad Sucks",
                    foreignArtistId: "1ce18a52-ca5f-4f34-9bc6-5f2af0d33f5e",
                    images: [image(seed: "bradsucks", kind: "poster")]
                ),
                foreignAlbumId: "out-of-it-2017",
                albumType: "Album",
                duration: 2_280_000, // ~38 min
                statistics: LidarrAlbumStats(
                    trackCount: 11, trackFileCount: 11, totalTrackCount: 11,
                    sizeOnDisk: 95_000_000
                ),
                monitored: true
            ),
            303: LidarrAlbumDetail(
                id: 303,
                title: "I Don't Know What I'm Doing",
                overview: "Brad Sucks's 2003 debut — the bedroom-pop record he gave away for free on the early web while figuring out how to make a living without a label. \"Making Me Nervous\" became an unlikely viral hit, and the whole album stayed Creative Commons: the original blueprint for the artist-direct, open-music distribution Lidarr exists to follow.",
                releaseDate: "2003-04-22",
                genres: ["Indie Rock", "Power Pop", "DIY"],
                ratings: LidarrDetailRatings(value: 7.9, votes: 540),
                images: [image(seed: "bradsucks-debut", kind: "cover")],
                artist: LidarrArtist(
                    id: 302, artistName: "Brad Sucks",
                    foreignArtistId: "1ce18a52-ca5f-4f34-9bc6-5f2af0d33f5e",
                    images: [image(seed: "bradsucks", kind: "poster")]
                ),
                foreignAlbumId: "i-dont-know-what-im-doing-2003",
                albumType: "Album",
                duration: 2_395_000, // ~40 min
                statistics: LidarrAlbumStats(
                    trackCount: 12, trackFileCount: 12, totalTrackCount: 12,
                    sizeOnDisk: 110_000_000
                ),
                monitored: false
            ),
        ]
    }

    static var lidarrTrackData: [Int: [LidarrTrackDetail]] {
        [
            301: [
                track(3001, "1", 1, "1 Ghosts I", duration_ms: 152_000, hasFile: true),
                track(3002, "2", 2, "2 Ghosts I", duration_ms: 218_000, hasFile: true),
                track(3003, "3", 3, "3 Ghosts I", duration_ms: 218_000, hasFile: true),
                track(3004, "4", 4, "4 Ghosts I", duration_ms: 137_000, hasFile: true),
                track(3005, "5", 5, "5 Ghosts I", duration_ms: 169_000, hasFile: true),
                track(3006, "6", 6, "6 Ghosts I", duration_ms: 240_000, hasFile: true),
                track(3007, "7", 7, "7 Ghosts I", duration_ms: 153_000, hasFile: true),
                track(3008, "8", 8, "8 Ghosts I", duration_ms: 178_000, hasFile: true),
                track(3009, "9", 9, "9 Ghosts I", duration_ms: 165_000, hasFile: true),
                track(3010, "10", 10, "10 Ghosts II", duration_ms: 180_000, hasFile: true),
                track(3011, "11", 11, "11 Ghosts II", duration_ms: 245_000, hasFile: true),
                track(3012, "12", 12, "12 Ghosts II", duration_ms: 225_000, hasFile: true),
                track(3013, "13", 13, "13 Ghosts II", duration_ms: 277_000, hasFile: false),
                track(3014, "14", 14, "14 Ghosts II", duration_ms: 113_000, hasFile: false),
                track(3015, "15", 15, "15 Ghosts II", duration_ms: 224_000, hasFile: false),
                track(3016, "16", 16, "16 Ghosts II", duration_ms: 196_000, hasFile: false),
                track(3017, "17", 17, "17 Ghosts II", duration_ms: 209_000, hasFile: false),
                track(3018, "18", 18, "18 Ghosts II", duration_ms: 162_000, hasFile: false),
            ],
            302: [
                track(4001, "1", 1, "Sleeping",         duration_ms: 198_000, hasFile: true),
                track(4002, "2", 2, "Wonder",           duration_ms: 207_000, hasFile: true),
                track(4003, "3", 3, "Out of It",        duration_ms: 184_000, hasFile: true),
                track(4004, "4", 4, "Maps",             duration_ms: 215_000, hasFile: true),
                track(4005, "5", 5, "Holding Pattern",  duration_ms: 226_000, hasFile: true),
                track(4006, "6", 6, "Try",              duration_ms: 233_000, hasFile: true),
                track(4007, "7", 7, "What You Wanted",  duration_ms: 198_000, hasFile: true),
                track(4008, "8", 8, "Out of Reach",     duration_ms: 203_000, hasFile: true),
                track(4009, "9", 9, "Underwater",       duration_ms: 234_000, hasFile: true),
                track(4010, "10", 10, "Dive Light",     duration_ms: 191_000, hasFile: true),
                track(4011, "11", 11, "Surfacing",      duration_ms: 195_000, hasFile: true),
            ],
            303: [
                track(4101, "1",  1,  "Making Me Nervous",           duration_ms: 210_000, hasFile: true),
                track(4102, "2",  2,  "Fixing My Brain",             duration_ms: 190_000, hasFile: true),
                track(4103, "3",  3,  "Dropping out of School",      duration_ms: 170_000, hasFile: true),
                track(4104, "4",  4,  "Bad Sign",                    duration_ms: 220_000, hasFile: true),
                track(4105, "5",  5,  "Look and Feel Years Younger", duration_ms: 200_000, hasFile: true),
                track(4106, "6",  6,  "Borderline",                  duration_ms: 185_000, hasFile: true),
                track(4107, "7",  7,  "Total Breakdown",             duration_ms: 195_000, hasFile: true),
                track(4108, "8",  8,  "Certain Death",               duration_ms: 175_000, hasFile: true),
                track(4109, "9",  9,  "Gonna Be Alright",            duration_ms: 205_000, hasFile: true),
                track(4110, "10", 10, "T-Shirt",                     duration_ms: 180_000, hasFile: true),
                track(4111, "11", 11, "Overreacting",                duration_ms: 215_000, hasFile: true),
                track(4112, "12", 12, "Understood",                  duration_ms: 250_000, hasFile: true),
            ],
        ]
    }

    static func track(
        _ id: Int, _ trackNumber: String, _ absolute: Int,
        _ title: String, duration_ms: Int, hasFile: Bool
    ) -> LidarrTrackDetail {
        LidarrTrackDetail(
            id: id, trackNumber: trackNumber, absoluteTrackNumber: absolute,
            title: title, duration: duration_ms, mediumNumber: 1, hasFile: hasFile
        )
    }

    // MARK: - Cast fixtures
    //
    // Cast strips for the two live-action titles in the demo universe:
    // Tears of Steel (Radarr movie) and Pioneer One (Sonarr series). The
    // animated Blender shorts have no on-screen cast, so they return empty and
    // the cast row hides itself. Names, characters, order, and headshots are
    // the real TMDB credits (movie 133701 / tv 33050); headshots come straight
    // off TMDB's no-auth image CDN, so members without a TMDB portrait fall back
    // to the person glyph.

    /// TMDB profile image on the no-auth CDN. w185 is ample for the 52px circle.
    static func tmdbProfileURL(_ path: String) -> String {
        "https://image.tmdb.org/t/p/w185\(path)"
    }

    /// Movie cast, keyed by demo movie entityId. Backs the demo branch of
    /// `RadarrClient.fetchCredits`.
    public static func radarrMovieCredits(movieId: Int) -> [ArrCredit] {
        radarrCredits[movieId] ?? []
    }

    static var radarrCredits: [Int: [ArrCredit]] {
        [
            203: [ // Tears of Steel — live-action / VFX hybrid (TMDB 133701)
                castCredit("Derek de Lint",      "Old Thom",  0, "/8fRRmh8EYZBlUtu1Wlop0j22QcP.jpg",
                           tmdbId: DemoPerson.derekDeLint.rawValue),
                castCredit("Sergio Hasselbaink", "Barly",     1, "/6xjL2LqOEURISAzzFLtYsIVmGT1.jpg"),
                castCredit("Vanja Rukavina",     "Thom",      2, "/4zzhALIIwYvBFmem3dm6nOZg8py.jpg"),
                castCredit("Denise Rebergen",    "Celia",     3, "/hBJjiMZsz5WaEgCpkUsw7Z0lekD.jpg"),
                castCredit("Rogier Schippers",   "Kapitän",   4, "/fUeXGTjkNZPwHK1JZwtiK6SUYmT.jpg"),
                castCredit("Chris Haley",        "Tech head", 5, nil),
                castCredit("Jody Bhe",           "Djenghis",  6, nil),
            ],
        ]
    }

    static func castCredit(_ name: String, _ character: String, _ order: Int, _ profilePath: String?,
                           tmdbId: Int? = nil) -> ArrCredit {
        let images = profilePath.map {
            [ArrCredit.Image(coverType: "headshot", url: nil, remoteUrl: tmdbProfileURL($0))]
        }
        return ArrCredit(
            personName: name, personTmdbId: tmdbId,
            character: character, order: order,
            type: "cast", images: images
        )
    }

    /// Series cast, keyed by demo series entityId. Backs the demo branch of
    /// `CastProvider.seriesCast` (Sonarr has no `/credit` endpoint, so this
    /// stands in for the TMDB lookup the live app would do).
    public static func sonarrSeriesCast(seriesId: Int) -> [CastMember] {
        sonarrCast[seriesId] ?? []
    }

    static var sonarrCast: [Int: [CastMember]] {
        [
            101: [ // Pioneer One — BitTorrent-funded live-action drama (TMDB 33050)
                seriesCast("po-0", "Alexandra Blatt", "Sofie Larson",        nil),
                seriesCast("po-1", "Laura Graham",    "Jane",                nil),
                seriesCast("po-2", "James Rich",      "Tom Taylor",          "/oF7kZnQ0HgqXVCPFmU1t03quHr2.jpg",
                           tmdbId: DemoPerson.jamesRich.rawValue),
                seriesCast("po-3", "Einar Gunn",      "Secretary McClellan", "/eV7WLsX07KLND9ZwpqHHEqG8iUl.jpg"),
                seriesCast("po-4", "Jack Haley",      "Dr. Zachary Walzer",  "/mnH1MyyWZOogI5X6JHMnoEAkxyq.jpg"),
            ],
        ]
    }

    static func seriesCast(_ id: String, _ name: String, _ role: String, _ profilePath: String?,
                           tmdbId: Int? = nil) -> CastMember {
        CastMember(
            id: id, name: name, role: role,
            imageURL: profilePath.flatMap { URL(string: tmdbProfileURL($0)) },
            tmdbPersonId: tmdbId
        )
    }

}
