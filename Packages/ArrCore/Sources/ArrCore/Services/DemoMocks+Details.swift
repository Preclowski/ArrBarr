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
        var map: [Int: SonarrEpisodeFile] = [:]
        for ep in sonarrEpisodes(seriesId: seriesId) where ep.hasFile == true {
            guard let fid = ep.episodeFileId else { continue }
            let score = 200 + (fid * 37) % 400      // deterministic spread 200…600
            let size = Int64(1_500_000_000 + (fid * 53) % 1_500_000_000)
            map[fid] = SonarrEpisodeFile(
                id: fid,
                seriesId: seriesId,
                customFormats: nil,
                customFormatScore: score,
                quality: nil,
                size: size,
                relativePath: "S\(String(format: "%02d", ep.seasonNumber ?? 0))/episode.\(fid).mkv"
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
                status: "released"
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
                status: "released"
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
                status: "released"
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
                        episodeFileCount: 4, episodeCount: 6, totalEpisodeCount: 6,
                        sizeOnDisk: 2_400_000_000, percentOfEpisodes: 66.6
                    )),
                    SonarrSeasonInfo(seasonNumber: 2, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2010-06-16"
            ),
            102: SonarrSeriesDetail(
                id: 102,
                title: "Caminandes",
                year: 2013,
                overview: "Koro, a wide-eyed Patagonian llama, just wants to live his life — but the trail keeps giving him reasons not to. Three short episodes of Blender Foundation slapstick that became a tutorial pipeline for character rigging, eye shading, and snow simulation.",
                genres: ["Animation", "Comedy", "Family"],
                runtime: 5,
                ratings: SonarrDetailRatings(value: 7.6, votes: 2_300),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "caminandes")],
                titleSlug: "caminandes",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 3, episodeCount: 5, totalEpisodeCount: 5,
                        sizeOnDisk: 1_400_000_000, percentOfEpisodes: 60
                    )),
                ],
                firstAired: "2013-04-13"
            ),
            103: SonarrSeriesDetail(
                id: 103,
                title: "Tears of Steel",
                year: 2012,
                overview: "A serialised continuation of the Blender short — the same Amsterdam crew, episode-by-episode, exploring the years between the robot uprising and the human resistance. Demo placeholder for a sci-fi season pack.",
                genres: ["Sci-Fi", "Action", "Drama"],
                runtime: 28,
                ratings: SonarrDetailRatings(value: 7.1, votes: 980),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "tearsofsteel")],
                titleSlug: "tearsofsteel-series",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 3, totalEpisodeCount: 3,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2012-09-26"
            ),
            104: SonarrSeriesDetail(
                id: 104,
                title: "Cosmos Laundromat",
                year: 2015,
                overview: "Franck the suicidal sheep meets a multiversal salesman who promises any life he can imagine — for a price. The Blender Foundation's experimental open-movie pilot; demo content for a half-hour adult-animation drama.",
                genres: ["Animation", "Drama", "Fantasy"],
                runtime: 12,
                ratings: SonarrDetailRatings(value: 7.5, votes: 1_400),
                network: "Blender Foundation",
                status: "ended",
                images: [image(seed: "cosmoslaundromat")],
                titleSlug: "cosmoslaundromat-series",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 1, totalEpisodeCount: 1,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2015-08-10"
            ),
            105: SonarrSeriesDetail(
                id: 105,
                title: "Northern Cascade",
                year: 2023,
                overview: "A team of glaciologists, climbers, and a reluctant journalist disappear in the Cascade range. Each season unwinds the timeline differently — what they took with them, what they left behind, and what was already there before they arrived. (Demo placeholder.)",
                genres: ["Drama", "Mystery", "Thriller"],
                runtime: 52,
                ratings: SonarrDetailRatings(value: 8.4, votes: 12_500),
                network: "Demo Streaming",
                status: "continuing",
                images: [image(seed: "northerncascade")],
                titleSlug: "northerncascade",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 8, episodeCount: 8, totalEpisodeCount: 8,
                        sizeOnDisk: 36_000_000_000, percentOfEpisodes: 100
                    )),
                    SonarrSeasonInfo(seasonNumber: 2, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 3, episodeCount: 8, totalEpisodeCount: 8,
                        sizeOnDisk: 14_500_000_000, percentOfEpisodes: 37.5
                    )),
                ],
                firstAired: "2023-02-09"
            ),
            106: SonarrSeriesDetail(
                id: 106,
                title: "Spring Tales",
                year: 2019,
                overview: "An animated anthology of folklore retold from the perspective of small things — a bee on a stalk, a frog in a puddle, a salamander under a stone. A spiritual descendant of Blender's `Spring` short, expanded into a season of slow-paced visual storytelling. (Demo placeholder.)",
                genres: ["Animation", "Family", "Drama"],
                runtime: 22,
                ratings: SonarrDetailRatings(value: 8.0, votes: 3_200),
                network: "Blender Foundation",
                status: "continuing",
                images: [image(seed: "spring")],
                titleSlug: "springtales",
                seasons: [
                    SonarrSeasonInfo(seasonNumber: 1, monitored: true, statistics: SonarrSeasonStats(
                        episodeFileCount: 0, episodeCount: 4, totalEpisodeCount: 4,
                        sizeOnDisk: 0, percentOfEpisodes: 0
                    )),
                ],
                firstAired: "2019-04-04"
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
                episode(201, 2, 1, "Reentry", "Aftermath.", daysAhead: 1, hasFile: false),
                episode(202, 2, 2, "Witness", "An unexpected ally.", daysAhead: 8, hasFile: false),
                episode(203, 2, 3, "Cold War Echo", "An old enemy.", daysAhead: 15, hasFile: false),
                episode(204, 2, 4, "Diaspora", "The cosmonaut speaks.", daysAhead: 22, hasFile: false),
            ],
            102: [ // Caminandes
                episode(301, 1, 1, "Llama Drama", "Koro meets a fence.", daysAgo: 1100, hasFile: true),
                episode(302, 1, 2, "Gran Dillama", "Koro meets a llama-vending machine.", daysAgo: 950, hasFile: true),
                episode(303, 1, 3, "Llamigos", "Koro meets a penguin.", daysAgo: 800, hasFile: false),
                episode(304, 1, 4, "Mountain Pass", "Koro climbs.", daysAgo: 600, hasFile: true),
                episode(305, 1, 5, "Frozen Lake", "Koro slips.", daysAgo: 400, hasFile: false),
            ],
            105: [ // Northern Cascade
                episode(701, 2, 1, "First Tracks", "A return to the range.", daysAgo: 70, hasFile: true),
                episode(702, 2, 2, "Approach", "The team splits.", daysAgo: 63, hasFile: true),
                episode(703, 2, 3, "Whiteout", "Visibility drops to zero.", daysAgo: 56, hasFile: true),
                episode(704, 2, 4, "Cold Start", "Equipment fails.", daysAgo: 49, hasFile: false),
                episode(705, 2, 5, "Bivouac", "A long night.", daysAgo: 42, hasFile: false),
                episode(706, 2, 6, "Crevasse", "Someone goes down.", daysAhead: 0, hasFile: false),
                episode(707, 2, 7, "Recovery", "Helicopter on standby.", daysAhead: 7, hasFile: false),
                episode(708, 2, 8, "Aftermath", "Press conference.", daysAhead: 14, hasFile: false),
            ],
            106: sprintTalesEpisodes,
            103: tosSeriesEpisodes,
            104: [
                episode(901, 1, 1, "The Beginning", "Franck negotiates.", daysAhead: 0, hasFile: false),
            ],
        ]
    }

    static var sprintTalesEpisodes: [SonarrEpisodeDetail] {
        [
            episode(801, 1, 1, "Bloom", "A flower opens.", daysAgo: 0, hasFile: false),
            episode(802, 1, 2, "Petals", "A breeze picks up.", daysAhead: 7, hasFile: false),
            episode(803, 1, 3, "Pollen", "A bee visits.", daysAhead: 14, hasFile: false),
            episode(804, 1, 4, "Wilt", "Autumn arrives.", daysAhead: 21, hasFile: false),
        ]
    }

    static var tosSeriesEpisodes: [SonarrEpisodeDetail] {
        [
            episode(401, 1, 1, "First Light", "The team gathers.", daysAgo: 30, hasFile: false),
            episode(402, 1, 2, "Mecha", "An old enemy returns.", daysAgo: 23, hasFile: false),
            episode(403, 1, 3, "Reunion", "Decisions made.", daysAgo: 16, hasFile: false),
        ]
    }

    static func episode(
        _ id: Int, _ season: Int, _ number: Int,
        _ title: String, _ overview: String,
        daysAgo: Int = -1, daysAhead: Int = -1,
        hasFile: Bool
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
            hasFile: hasFile, monitored: true, runtime: 45,
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
                )
            ),
            302: LidarrAlbumDetail(
                id: 302,
                title: "Out of It",
                overview: "Brad Sucks's third self-released album of cynical, hooky DIY rock. Made in his basement, released for free, distributed via direct downloads and CC licensing — a poster child for the open-music movement Lidarr was built to track.",
                releaseDate: "2017-04-04",
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
                )
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

}
