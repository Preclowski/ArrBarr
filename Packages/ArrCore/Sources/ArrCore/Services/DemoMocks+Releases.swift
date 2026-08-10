import Foundation

// Manual-search (interactive search) fixtures — the candidate releases an arr's
// `/release` endpoint returns for a movie / episode / season / album.
//
// The spread is deliberate: every state `ReleaseListView` can render has to
// appear somewhere in demo. Usenet next to torrent, a 40 GB remux next to a
// 2 GB WEBRip, ages from hours to years, positive AND negative custom-format
// scores, and two rejected candidates so the warning badge and its reasons are
// demoable. Sizes and scores line up with the queue fixtures' `existing` files,
// so the upgrade diff shows real gains rather than noise.

extension DemoMocks {

    /// Entry point for `ArrAPIClient.fetchReleases` in demo mode. Reads the same
    /// keying params the real endpoint takes, so the four search shapes
    /// (movie / episode / season / album) each get their own fixture list.
    static func releases(query: [URLQueryItem], source: QueueItem.Source) -> [Release] {
        let params = query.reduce(into: [String: String]()) { out, item in
            if let value = item.value { out[item.name] = value }
        }
        func int(_ name: String) -> Int? { params[name].flatMap(Int.init) }

        // seriesId + seasonNumber before episodeId: a season search carries both
        // in production, and the pack list is the right answer for it.
        if let seriesId = int("seriesId"), let season = int("seasonNumber") {
            return seasonReleases(seriesId: seriesId, season: season)
        }
        if let episodeId = int("episodeId") { return episodeReleases(episodeId: episodeId) }
        if let albumId = int("albumId") { return albumReleases(albumId: albumId) }
        if let movieId = int("movieId") { return movieReleases(movieId: movieId, source: source) }
        return []
    }

    // MARK: - Spec table

    /// One fixture row. The per-target lists below are tables of these — a
    /// dozen 15-line `Release` initialisers would bury the interesting part
    /// (the spread) in boilerplate.
    struct ReleaseSpec {
        /// Scene tag: the middle of the release name (`…2160p.BluRay.REMUX.HDR-`).
        let tag: String
        /// The arr's quality name, as shown in the row and the diff.
        let quality: String
        let bytes: Int64
        let score: Int
        let formats: [String]
        let usenet: Bool
        let ageHours: Double
        var seeders: Int? = nil
        let group: String
        /// Non-empty → the release renders rejected (badge on the download
        /// button, reasons in the hover card) and sinks to the bottom.
        var rejections: [String] = []
    }

    private static func build(_ base: String, _ specs: [ReleaseSpec], fullSeason: Bool? = nil) -> [Release] {
        specs.enumerated().map { index, spec in
            Release(
                guid: "demo-release-\(base)-\(index)",
                title: "\(base).\(spec.tag)-\(spec.group)",
                indexer: spec.usenet ? "DemoUsenet" : "DemoTracker",
                indexerId: spec.usenet ? 2 : 1,
                size: spec.bytes,
                // Usenet has no swarm — leaving these nil is what makes the
                // hover card drop its "Seeders / leechers" row for NZB rows.
                seeders: spec.usenet ? nil : spec.seeders,
                leechers: spec.usenet ? nil : max(1, (spec.seeders ?? 7) / 7),
                proto: spec.usenet ? "usenet" : "torrent",
                customFormatScore: spec.score,
                customFormats: spec.formats.map { Release.NamedRef(name: $0) },
                quality: Release.QualityContainer(quality: Release.NamedRef(name: spec.quality)),
                languages: [Release.NamedRef(name: "English")],
                releaseGroup: spec.group,
                ageHours: spec.ageHours,
                publishDate: iso(hoursAgo: spec.ageHours),
                rejected: !spec.rejections.isEmpty,
                rejections: spec.rejections.isEmpty ? nil : spec.rejections,
                infoUrl: nil,
                fullSeason: fullSeason
            )
        }
    }

    private static func iso(hoursAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 3600))
    }

    /// "Big Buck Bunny" + 2008 → "Big.Buck.Bunny.2008". Punctuation goes the way
    /// a real scene name drops it, so the demo rows look like indexer results
    /// rather than titles with dots in them.
    private static func sceneName(_ title: String, year: Int?) -> String {
        let cleaned = title.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        let words = String(cleaned).split(separator: " ").map(String.init)
        let name = words.joined(separator: ".")
        guard let year else { return name }
        return "\(name).\(year)"
    }

    private static func pad(_ number: Int?) -> String {
        String(format: "%02d", number ?? 0)
    }

    // MARK: - Movies

    private static func movieReleases(movieId: Int, source: QueueItem.Source) -> [Release] {
        let detail = (source == .whisparr ? whisparrDetails[movieId] : radarrDetails[movieId])
        let base = sceneName(detail?.title ?? "Demo Movie", year: detail?.year)
        return build(base, movieSpecs)
    }

    private static var movieSpecs: [ReleaseSpec] {
        [
            ReleaseSpec(
                tag: "2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.7.1.Atmos",
                quality: "Remux-2160p", bytes: 54_800_000_000, score: 1850,
                formats: ["HDR10+", "DV", "TrueHD", "Atmos", "Remux Tier 01", "HQ Source Group"],
                usenet: true, ageHours: 5, group: "DEMOREMUX"
            ),
            ReleaseSpec(
                tag: "2160p.BluRay.x265.10bit.HDR.DTS-HD.MA.5.1",
                quality: "Bluray-2160p", bytes: 18_400_000_000, score: 1720,
                formats: ["HDR10", "DV", "x265", "DTS-HD MA 5.1"],
                usenet: false, ageHours: 19, seeders: 84, group: "DEMOUHD"
            ),
            ReleaseSpec(
                tag: "2160p.AMZN.WEB-DL.DDP5.1.HDR.HEVC",
                quality: "WEBDL-2160p", bytes: 12_100_000_000, score: 980,
                formats: ["AMZN", "HDR10", "DDP 5.1", "x265"],
                usenet: true, ageHours: 61, group: "DEMOWEB"
            ),
            ReleaseSpec(
                tag: "1080p.BluRay.x264.DTS-HD.MA.5.1",
                quality: "Bluray-1080p", bytes: 8_400_000_000, score: 350,
                formats: ["x264", "DTS-HD MA 5.1"],
                usenet: false, ageHours: 210, seeders: 213, group: "DEMOBD"
            ),
            ReleaseSpec(
                tag: "1080p.AMZN.WEB-DL.DDP5.1.Atmos.AV1",
                quality: "WEBDL-1080p", bytes: 4_600_000_000, score: 720,
                formats: ["AMZN", "Atmos", "DDP 5.1", "AV1", "HQ Source Group"],
                usenet: false, ageHours: 372, seeders: 61, group: "DEMOAV1"
            ),
            ReleaseSpec(
                tag: "1080p.WEBRip.x264.AAC2.0",
                quality: "WEBRip-1080p", bytes: 2_900_000_000, score: 40,
                formats: ["x264", "AAC 2.0"],
                usenet: false, ageHours: 990, seeders: 9, group: "DEMORIP"
            ),
            ReleaseSpec(
                tag: "720p.HDTV.x264",
                quality: "HDTV-720p", bytes: 1_150_000_000, score: 60,
                formats: ["x264"],
                usenet: true, ageHours: 2_880, group: "DEMOTV"
            ),
            // Rejected #1 — profile cutoff. The most common real-world reason a
            // manual-search row needs an override.
            ReleaseSpec(
                tag: "480p.DVDRip.XviD",
                quality: "DVD", bytes: 720_000_000, score: -50,
                formats: ["XviD", "LQ"],
                usenet: false, ageHours: 6_100, seeders: 2, group: "DEMOSD",
                rejections: [
                    "Quality DVD is not wanted in profile",
                    "Existing file has a higher custom format score",
                ]
            ),
            // Rejected #2 — blocked format rather than blocked quality, so the
            // hover card shows a different flavour of reason.
            ReleaseSpec(
                tag: "2160p.WEB-DL.HDR.x265.HC",
                quality: "WEBDL-2160p", bytes: 9_800_000_000, score: -120,
                formats: ["HDR10", "x265", "Hardcoded Subs"],
                usenet: false, ageHours: 44, seeders: 31, group: "DEMOHC",
                rejections: ["Custom format 'Hardcoded Subs' is blocked in this profile"]
            ),
        ]
    }

    // MARK: - Episodes / seasons

    private static func episodeReleases(episodeId: Int) -> [Release] {
        guard let found = findEpisode(id: episodeId) else { return [] }
        let series = sonarrDetails[found.seriesId]
        let base = "\(sceneName(series?.title ?? "Demo Series", year: nil))"
            + ".S\(pad(found.episode.seasonNumber))E\(pad(found.episode.episodeNumber))"
        return build(base, episodeSpecs)
    }

    private static func findEpisode(id: Int) -> (seriesId: Int, episode: SonarrEpisodeDetail)? {
        for (seriesId, episodes) in sonarrEpisodeData {
            if let episode = episodes.first(where: { $0.id == id }) {
                return (seriesId, episode)
            }
        }
        return nil
    }

    private static var episodeSpecs: [ReleaseSpec] {
        [
            ReleaseSpec(
                tag: "2160p.AMZN.WEB-DL.DDP5.1.HDR.HEVC",
                quality: "WEBDL-2160p", bytes: 6_200_000_000, score: 1240,
                formats: ["AMZN", "HDR10", "DDP 5.1", "x265", "HQ Source Group"],
                usenet: true, ageHours: 3, group: "DEMOWEB"
            ),
            ReleaseSpec(
                tag: "1080p.BluRay.x264.DTS-HD.MA.5.1",
                quality: "Bluray-1080p", bytes: 3_800_000_000, score: 640,
                formats: ["x264", "DTS-HD MA 5.1"],
                usenet: false, ageHours: 26, seeders: 47, group: "DEMOBD"
            ),
            ReleaseSpec(
                tag: "1080p.AMZN.WEB-DL.DDP5.1.H.264",
                quality: "WEBDL-1080p", bytes: 2_100_000_000, score: 720,
                formats: ["AMZN", "x264", "DDP 5.1", "HQ Source Group"],
                usenet: false, ageHours: 78, seeders: 120, group: "DEMOWEB"
            ),
            ReleaseSpec(
                tag: "1080p.WEB-DL.AAC2.0.H.264.REPACK",
                quality: "WEBDL-1080p", bytes: 1_900_000_000, score: 380,
                formats: ["x264", "AAC 2.0", "Repack"],
                usenet: true, ageHours: 150, group: "DEMOFIX"
            ),
            ReleaseSpec(
                tag: "720p.HDTV.x264",
                quality: "HDTV-720p", bytes: 850_000_000, score: 60,
                formats: ["x264"],
                usenet: false, ageHours: 640, seeders: 18, group: "DEMOTV"
            ),
            ReleaseSpec(
                tag: "480p.WEBRip.x264",
                quality: "WEBRip-480p", bytes: 320_000_000, score: 20,
                formats: ["x264"],
                usenet: false, ageHours: 4_300, seeders: 3, group: "DEMOSD"
            ),
            ReleaseSpec(
                tag: "1080p.HDTV.x264.PROPER",
                quality: "HDTV-1080p", bytes: 2_400_000_000, score: -30,
                formats: ["x264", "LQ"],
                usenet: false, ageHours: 96, seeders: 6, group: "DEMOLQ",
                rejections: ["Not a preferred word upgrade for existing episode file"]
            ),
        ]
    }

    private static func seasonReleases(seriesId: Int, season: Int) -> [Release] {
        let series = sonarrDetails[seriesId]
        let base = "\(sceneName(series?.title ?? "Demo Series", year: nil)).S\(pad(season))"
        let packs = build(base, seasonPackSpecs, fullSeason: true)
        // The per-episode results the same call returns alongside the packs.
        // `ReleaseListView` hides them when packs exist and falls back to them
        // when they don't — keeping them in the fixture means demo exercises
        // that branch instead of only production doing so.
        let singles = sonarrEpisodes(seriesId: seriesId)
            .filter { $0.seasonNumber == season }
            .prefix(3)
            .flatMap { episode in
                build("\(base)E\(pad(episode.episodeNumber))", [singleEpisodeSpec], fullSeason: false)
            }
        return packs + singles
    }

    private static var seasonPackSpecs: [ReleaseSpec] {
        [
            ReleaseSpec(
                tag: "COMPLETE.2160p.AMZN.WEB-DL.DDP5.1.HDR.HEVC",
                quality: "WEBDL-2160p", bytes: 41_000_000_000, score: 1240,
                formats: ["AMZN", "HDR10", "DDP 5.1", "x265", "HQ Source Group"],
                usenet: true, ageHours: 12, group: "DEMOWEB"
            ),
            ReleaseSpec(
                tag: "COMPLETE.1080p.BluRay.x264.DTS-HD.MA.5.1",
                quality: "Bluray-1080p", bytes: 24_500_000_000, score: 640,
                formats: ["x264", "DTS-HD MA 5.1"],
                usenet: false, ageHours: 55, seeders: 38, group: "DEMOBD"
            ),
            ReleaseSpec(
                tag: "1080p.WEB-DL.AAC2.0.H.264",
                quality: "WEBDL-1080p", bytes: 9_400_000_000, score: 720,
                formats: ["AMZN", "x264", "AAC 2.0", "HQ Source Group"],
                usenet: false, ageHours: 310, seeders: 96, group: "DEMOWEB"
            ),
            ReleaseSpec(
                tag: "720p.HDTV.x264",
                quality: "HDTV-720p", bytes: 4_100_000_000, score: 60,
                formats: ["x264"],
                usenet: true, ageHours: 2_100, group: "DEMOTV"
            ),
        ]
    }

    private static var singleEpisodeSpec: ReleaseSpec {
        ReleaseSpec(
            tag: "1080p.WEB-DL.AAC2.0.H.264",
            quality: "WEBDL-1080p", bytes: 2_100_000_000, score: 720,
            formats: ["AMZN", "x264", "AAC 2.0"],
            usenet: false, ageHours: 300, seeders: 44, group: "DEMOWEB"
        )
    }

    // MARK: - Albums

    private static func albumReleases(albumId: Int) -> [Release] {
        guard let album = lidarrDetails[albumId] else { return [] }
        let artist = album.artist?.artistName ?? "Demo Artist"
        let year = album.releaseDate.flatMap { Int($0.prefix(4)) }
        let base = "\(sceneName(artist, year: nil))-\(sceneName(album.title, year: year))"
        return build(base, albumSpecs)
    }

    private static var albumSpecs: [ReleaseSpec] {
        [
            ReleaseSpec(
                tag: "24BIT.96kHz.WEB.FLAC",
                quality: "FLAC 24bit", bytes: 1_450_000_000, score: 420,
                formats: ["Lossless", "24bit", "Original Source"],
                usenet: false, ageHours: 30, seeders: 22, group: "DEMOHD"
            ),
            ReleaseSpec(
                tag: "WEB.FLAC",
                quality: "FLAC", bytes: 380_000_000, score: 320,
                formats: ["Lossless", "Original Source"],
                usenet: false, ageHours: 96, seeders: 57, group: "DEMOFLAC"
            ),
            ReleaseSpec(
                tag: "WEB.MP3.320",
                quality: "MP3-320", bytes: 128_000_000, score: 0,
                formats: ["Lossy"],
                usenet: true, ageHours: 480, group: "DEMOMP3"
            ),
            ReleaseSpec(
                tag: "WEB.MP3.V0",
                quality: "MP3-VBR V0", bytes: 96_000_000, score: 0,
                formats: ["Lossy"],
                usenet: false, ageHours: 1_400, seeders: 11, group: "DEMOV0"
            ),
            ReleaseSpec(
                tag: "WEB.MP3.128",
                quality: "MP3-128", bytes: 48_000_000, score: -80,
                formats: ["Lossy", "LQ"],
                usenet: false, ageHours: 8_700, seeders: 1, group: "DEMOLQ",
                rejections: ["Quality MP3-128 is not wanted in profile"]
            ),
        ]
    }
}
