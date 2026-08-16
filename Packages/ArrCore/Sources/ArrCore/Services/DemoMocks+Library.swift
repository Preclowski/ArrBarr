import Foundation

// Library-side fixtures: what each arr says it already HAS, plus the small
// reference endpoints (custom formats, quality profiles, system status).
//
// These back the surfaces that read the library rather than the queue — the
// existing-file banner and the manual-search upgrade diff, the Quiz's library
// source, the chat empty state's poster wall, Spotlight, and the Settings
// connection test. Without them demo mode showed empty lists for features that
// work fine in production, which is exactly the impression a demo shouldn't
// give.

extension DemoMocks {

    // MARK: - Files on disk

    /// The file Radarr/Whisparr already holds for a demo movie, or nil for the
    /// ones deliberately left "not downloaded yet".
    ///
    /// Deliberately mirrors the `existing` files in the queue fixtures: the
    /// movie whose queue row is an upgrade owns exactly the file that row says
    /// it's replacing, so the manual-search diff and the queue's upgrade card
    /// tell the same story.
    public static func movieFile(movieId: Int) -> ArrFile? {
        switch movieId {
        case 202: // Sintel — the HDTV file its queue row upgrades away from
            return file(quality: "HDTV-720p", score: 60, size: 850_000_000,
                        formats: ["x264", "AAC 2.0"],
                        path: "Sintel (2010)/Sintel.2010.720p.HDTV.x264-OLD.mkv")
        case 203: // Tears of Steel — 1080p BluRay, being upgraded to 2160p
            return file(quality: "Bluray-1080p", score: 350, size: 8_400_000_000,
                        formats: ["x264", "DTS-HD MA 5.1"],
                        path: "Tears of Steel (2012)/Tears.of.Steel.2012.1080p.BluRay.x264-OLD.mkv")
        case 204: // Elephants Dream — in the library, nothing in flight
            return file(quality: "WEBDL-1080p", score: 180, size: 3_100_000_000,
                        formats: ["x264", "AAC 2.0"],
                        path: "Elephants Dream (2006)/Elephants.Dream.2006.1080p.WEB-DL.x264-DEMO.mkv")
        case 402: // The Black Cat Chronicles
            return file(quality: "WEBDL-1080p", score: 240, size: 2_400_000_000,
                        formats: ["x264"],
                        path: "The Black Cat Chronicles (2023)/The.Black.Cat.Chronicles.2023.1080p.WEB-DL.x264-OLD.mkv")
        default:
            // 201 (Big Buck Bunny) and 401 have no file — their queue rows are
            // fresh grabs, and the no-diff path needs to be demoable too.
            return nil
        }
    }

    static func file(quality: String, score: Int, size: Int64, formats: [String], path: String) -> ArrFile {
        ArrFile(
            customFormats: formats.enumerated().map { ArrCustomFormat(id: $0.offset + 1, name: $0.element) },
            customFormatScore: score,
            quality: ArrQuality(quality: ArrQuality.ArrQualityName(name: quality)),
            size: size,
            relativePath: path
        )
    }

    /// Single `/episodefile/{id}` lookup — served from the same map the series
    /// detail already builds, so one episode can't report two different files.
    /// (Covered by DemoFixtureTests — keep behaviourally identical to the map.)
    public static func episodeFile(id: Int) -> ArrFile? {
        for seriesId in sonarrEpisodeData.keys {
            if let match = sonarrEpisodeFileMap(seriesId: seriesId)[id] {
                return ArrFile(
                    customFormats: match.customFormats,
                    customFormatScore: match.customFormatScore,
                    quality: match.quality,
                    size: match.size,
                    relativePath: match.relativePath
                )
            }
        }
        return nil
    }

    // MARK: - Library listings

    /// `/movie` — the whole Radarr library. Drives the Quiz's library source,
    /// the chat empty state's poster wall, Spotlight and the library summary.
    public static func radarrLibrary() -> [RadarrLibraryRecord] {
        radarrDetails.values
            .sorted { $0.id < $1.id }
            .map { detail in
                RadarrLibraryRecord(
                    id: detail.id,
                    tmdbId: detail.id,
                    title: detail.title,
                    year: detail.year,
                    hasFile: movieFile(movieId: detail.id) != nil,
                    titleSlug: detail.titleSlug,
                    monitored: true,
                    images: detail.images,
                    genres: detail.genres,
                    runtime: detail.runtime,
                    overview: detail.overview,
                    ratings: RadarrLookupRatings(
                        tmdb: RadarrLookupRatingValue(value: detail.ratings?.tmdb?.value,
                                                     votes: detail.ratings?.tmdb?.votes),
                        imdb: RadarrLookupRatingValue(value: detail.ratings?.imdb?.value,
                                                     votes: detail.ratings?.imdb?.votes),
                        metacritic: nil,
                        rottenTomatoes: nil
                    ),
                    certification: detail.certification,
                    studio: detail.studio,
                    sizeOnDisk: movieFile(movieId: detail.id)?.size ?? 0
                )
            }
    }

    /// `/series` — the whole Sonarr library, seasons included so the chat's
    /// "is S1 monitored?" style questions have something to answer with.
    public static func sonarrLibrary() -> [SonarrLibraryRecord] {
        sonarrDetails.values
            .sorted { $0.id < $1.id }
            .map { detail in
                let episodes = sonarrEpisodes(seriesId: detail.id)
                let withFiles = episodes.filter { $0.hasFile == true }.count
                return SonarrLibraryRecord(
                    id: detail.id,
                    tvdbId: detail.id,
                    title: detail.title,
                    year: detail.year,
                    status: "continuing",
                    monitored: true,
                    statistics: SonarrLibraryStatistics(
                        episodeCount: episodes.count,
                        episodeFileCount: withFiles,
                        seasonCount: Set(episodes.compactMap(\.seasonNumber)).count,
                        sizeOnDisk: Int64(withFiles) * 1_900_000_000
                    ),
                    images: detail.images,
                    seasons: Set(episodes.compactMap(\.seasonNumber)).sorted().map { season in
                        let inSeason = episodes.filter { $0.seasonNumber == season }
                        return SonarrLibrarySeason(
                            seasonNumber: season,
                            monitored: true,
                            statistics: SonarrLibrarySeasonStatistics(
                                episodeCount: inSeason.count,
                                episodeFileCount: inSeason.filter { $0.hasFile == true }.count,
                                totalEpisodeCount: inSeason.count
                            )
                        )
                    },
                    overview: detail.overview,
                    titleSlug: detail.titleSlug
                )
            }
    }

    /// `/artist` — the Lidarr library, one record per artist behind the demo
    /// albums (two artists, three albums).
    public static func lidarrLibrary() -> [LidarrLibraryRecord] {
        let artists = lidarrDetails.values.compactMap(\.artist)
        var seen: Set<Int> = []
        return artists
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
            .map { artist in
                LidarrLibraryRecord(
                    id: artist.id,
                    foreignArtistId: artist.foreignArtistId,
                    artistName: artist.artistName,
                    monitored: true,
                    images: artist.images,
                    statistics: LidarrLibraryStatistics(
                        albumCount: lidarrDetails.values.filter { $0.artist?.id == artist.id }.count,
                        trackCount: 36, trackFileCount: 24, sizeOnDisk: 280_000_000
                    )
                )
            }
    }

    /// `/movie` on Whisparr — same endpoint shape as Radarr, different record.
    public static func whisparrLibrary() -> [WhisparrLibraryRecord] {
        whisparrDetails.values
            .sorted { $0.id < $1.id }
            .map { detail in
                WhisparrLibraryRecord(
                    id: detail.id,
                    foreignId: String(detail.id),
                    tmdbId: detail.id,
                    title: detail.title,
                    year: detail.year,
                    studio: detail.studio,
                    hasFile: movieFile(movieId: detail.id) != nil,
                    monitored: true,
                    images: detail.images,
                    sizeOnDisk: movieFile(movieId: detail.id)?.size ?? 0
                )
            }
    }

    // MARK: - Lookups

    /// `/movie/lookup` — the demo search pool, plus the library titles so a
    /// lookup for something already owned reports its library id (that's what
    /// drives the "in library" state on cards).
    public static func radarrLookup(term: String) -> [RadarrLookupRecord] {
        let owned = radarrDetails.values.map { detail in
            RadarrLookupRecord(
                id: detail.id, tmdbId: detail.id, title: detail.title, year: detail.year,
                overview: detail.overview, runtime: detail.runtime,
                ratings: RadarrLookupRatings(
                    tmdb: RadarrLookupRatingValue(value: detail.ratings?.tmdb?.value, votes: detail.ratings?.tmdb?.votes),
                    imdb: RadarrLookupRatingValue(value: detail.ratings?.imdb?.value, votes: detail.ratings?.imdb?.votes),
                    metacritic: nil, rottenTomatoes: nil
                ),
                images: detail.images, genres: detail.genres,
                certification: detail.certification, studio: detail.studio, status: "released"
            )
        }
        // The pool directly, not `searchResults(for: "")` — that helper caps an
        // empty query at six results (right for a search screen, wrong here:
        // a lookup for the seventh title would come back empty).
        let discoverable = radarrSearchPool.map { result in
            RadarrLookupRecord(
                // id 0 = not in the library; the card renders as addable.
                id: 0, tmdbId: result.externalId, title: result.title, year: result.year,
                overview: result.overview, runtime: result.runtime,
                ratings: RadarrLookupRatings(
                    tmdb: RadarrLookupRatingValue(value: result.rating, votes: 900),
                    imdb: RadarrLookupRatingValue(value: result.imdb, votes: 4_000),
                    metacritic: nil, rottenTomatoes: nil
                ),
                images: poster(from: result), genres: result.genres,
                certification: result.certification, studio: result.network, status: "released"
            )
        }
        return matches(term: term, in: owned + discoverable, title: \.title)
    }

    /// `/series/lookup` — same idea as `radarrLookup`.
    public static func sonarrLookup(term: String) -> [SonarrLookupRecord] {
        let owned = sonarrDetails.values.map { detail in
            SonarrLookupRecord(
                id: detail.id, tvdbId: detail.id, title: detail.title, year: detail.year,
                overview: detail.overview,
                ratings: SonarrLookupRatings(value: 7.5),
                images: detail.images,
                statistics: SonarrLookupStats(seasonCount: detail.seasons?.count ?? 1),
                genres: detail.genres, network: detail.network, runtime: 35, status: "continuing"
            )
        }
        let discoverable = sonarrSearchPool.map { result in
            SonarrLookupRecord(
                id: 0, tvdbId: result.externalId, title: result.title, year: result.year,
                overview: result.overview,
                ratings: SonarrLookupRatings(value: result.rating),
                images: poster(from: result),
                statistics: SonarrLookupStats(seasonCount: 1),
                genres: result.genres, network: result.network, runtime: result.runtime, status: "ended"
            )
        }
        return matches(term: term, in: owned + discoverable, title: \.title)
    }

    /// Reuses the search pool's own artwork rather than re-deriving a seed —
    /// a lookup card and a search card for the same title must not show
    /// different posters.
    private static func poster(from result: SearchResult) -> [ArrImage] {
        guard let url = result.posterURL?.absoluteString else { return [] }
        return [ArrImage(coverType: "poster", url: url, remoteUrl: url)]
    }

    /// Case-insensitive contains, first-match-wins on duplicate titles (a
    /// library title also present in the discover pool keeps its library id).
    private static func matches<T>(term: String, in pool: [T], title: KeyPath<T, String>) -> [T] {
        var seen: Set<String> = []
        let deduped = pool.filter { seen.insert($0[keyPath: title].lowercased()).inserted }
        let query = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return deduped }
        return deduped.filter { $0[keyPath: title].lowercased().contains(query) }
    }

    // MARK: - Reference data

    /// `/customformat` — the formats the demo queue rows and releases wear, so
    /// the chat's `describe_format` and the format-score surfaces resolve.
    public static func customFormats() -> [ArrCustomFormatDetail] {
        let names = [
            "HDR10+", "DV", "Atmos", "TrueHD", "DTS-HD MA 5.1", "DDP 5.1", "AAC 2.0",
            "x265", "x264", "AV1", "XviD", "AMZN", "Repack", "Remux Tier 01",
            "HQ Source Group", "Hardcoded Subs", "LQ", "Lossless", "24bit", "Lossy",
        ]
        return names.enumerated().map { index, name in
            ArrCustomFormatDetail(
                id: index + 1,
                name: name,
                specifications: [
                    ArrCustomFormatDetail.Specification(
                        name: name,
                        implementation: "ReleaseTitleSpecification",
                        implementationName: "Release Title",
                        negate: false,
                        required: false,
                        fields: nil
                    )
                ]
            )
        }
    }

    /// `/qualityprofile` — one profile with the scores the demo releases claim,
    /// so a "why did this score 1850?" answer has a table to read from.
    public static func qualityProfiles() -> [ArrQualityProfile] {
        [
            ArrQualityProfile(
                id: 1,
                name: "Ultra-HD",
                formatItems: customFormats().map { format in
                    ArrQualityProfile.FormatItem(
                        format: format.id,
                        name: format.name,
                        score: demoFormatScore(format.name)
                    )
                }
            ),
            ArrQualityProfile(id: 2, name: "HD-1080p", formatItems: []),
        ]
    }

    private static func demoFormatScore(_ name: String) -> Int {
        switch name {
        case "HDR10+", "DV": return 500
        case "Remux Tier 01": return 400
        case "TrueHD", "Atmos": return 250
        case "HQ Source Group": return 200
        case "DTS-HD MA 5.1", "DDP 5.1": return 100
        case "x265", "AV1", "AMZN": return 50
        case "Repack": return 20
        case "Lossless", "24bit": return 200
        case "LQ": return -200
        case "Hardcoded Subs": return -300
        case "XviD": return -100
        default: return 0
        }
    }

    /// What the Settings "Test" button prints. Version numbers match what the
    /// real arrs shipped so the string reads plausibly.
    public static func systemStatus(serviceName: String) -> String {
        switch serviceName {
        case "Sonarr":   return "Sonarr 4.0.10.2544"
        case "Radarr":   return "Radarr 5.14.0.9383"
        case "Lidarr":   return "Lidarr 2.6.4.4402"
        case "Whisparr": return "Whisparr 2.0.0.548"
        default:         return "\(serviceName) (demo)"
        }
    }
}
