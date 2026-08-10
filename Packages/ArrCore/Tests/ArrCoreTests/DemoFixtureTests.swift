import Testing
import Foundation
@testable import ArrCore

/// Demo mode is a shipped surface, but nothing exercises it in CI — a fixture
/// that returns an empty array only shows up as an empty screen someone has to
/// notice by hand. These assert the fixtures resolve for every search shape the
/// UI can ask for, and that the library fixtures agree with the queue ones (an
/// upgrade row whose "existing" file doesn't match what the library reports is
/// the kind of demo inconsistency a viewer WILL spot).
@Suite("Demo fixtures")
struct DemoFixtureTests {

    // MARK: - Manual search

    @Test("Every search shape returns releases")
    func releasesForEveryShape() {
        let movie = DemoMocks.releases(query: [URLQueryItem(name: "movieId", value: "203")], source: .radarr)
        let episode = DemoMocks.releases(query: [URLQueryItem(name: "episodeId", value: "101")], source: .sonarr)
        let season = DemoMocks.releases(query: [
            URLQueryItem(name: "seriesId", value: "101"),
            URLQueryItem(name: "seasonNumber", value: "1"),
        ], source: .sonarr)
        let album = DemoMocks.releases(query: [URLQueryItem(name: "albumId", value: "301")], source: .lidarr)

        #expect(!movie.isEmpty)
        #expect(!episode.isEmpty)
        #expect(!season.isEmpty)
        #expect(!album.isEmpty)
    }

    @Test("Release names carry the title they were searched for")
    func releaseNamesUseTheTitle() {
        let movie = DemoMocks.releases(query: [URLQueryItem(name: "movieId", value: "203")], source: .radarr)
        #expect(movie.allSatisfy { $0.title.hasPrefix("Tears.of.Steel.2012.") })

        let whisparr = DemoMocks.releases(query: [URLQueryItem(name: "movieId", value: "402")], source: .whisparr)
        #expect(whisparr.allSatisfy { $0.title.hasPrefix("The.Black.Cat.Chronicles.2023.") })
    }

    @Test("A season search returns packs alongside single episodes")
    func seasonSearchHasPacks() {
        let season = DemoMocks.releases(query: [
            URLQueryItem(name: "seriesId", value: "101"),
            URLQueryItem(name: "seasonNumber", value: "1"),
        ], source: .sonarr)

        // ReleaseListView prefers packs and falls back to singles — both have to
        // be present or that branch never runs in demo.
        #expect(season.contains { $0.fullSeason == true })
        #expect(season.contains { $0.fullSeason == false })
    }

    @Test("The movie list covers every row state the list can render")
    func movieListCoversRowStates() {
        let releases = DemoMocks.releases(query: [URLQueryItem(name: "movieId", value: "201")], source: .radarr)

        #expect(releases.contains { $0.isTorrent })
        #expect(releases.contains { !$0.isTorrent })
        #expect(releases.contains { $0.isRejected })
        #expect(releases.contains { ($0.customFormatScore ?? 0) > 0 })
        #expect(releases.contains { ($0.customFormatScore ?? 0) < 0 })
        // Age drives the row's leading column; a nil there renders as a dash.
        #expect(releases.allSatisfy { $0.ageHours != nil })
        // Torrents carry a swarm, usenet doesn't — that's what shows/hides the
        // hover card's seeders row.
        #expect(releases.filter(\.isTorrent).allSatisfy { $0.seeders != nil })
        #expect(releases.filter { !$0.isTorrent }.allSatisfy { $0.seeders == nil })
    }

    @Test("Release guids are unique — duplicates collapse rows in the list")
    func releaseGuidsAreUnique() {
        for query in [
            [URLQueryItem(name: "movieId", value: "201")],
            [URLQueryItem(name: "episodeId", value: "101")],
            [URLQueryItem(name: "seriesId", value: "101"), URLQueryItem(name: "seasonNumber", value: "1")],
            [URLQueryItem(name: "albumId", value: "301")],
        ] {
            let releases = DemoMocks.releases(query: query, source: .sonarr)
            #expect(Set(releases.map(\.guid)).count == releases.count)
        }
    }

    @Test("An unkeyed search is empty; an unknown id still gets a list")
    func unkeyedSearchIsEmpty() {
        // No keying param = nothing was asked for.
        #expect(DemoMocks.releases(query: [], source: .radarr).isEmpty)
        // An id outside the curated set still returns candidates under a generic
        // name — a demo drill-in should never dead-end on an empty list.
        #expect(!DemoMocks.releases(query: [URLQueryItem(name: "movieId", value: "9999")], source: .radarr).isEmpty)
    }

    // MARK: - Files on disk

    @Test("Movie files match the queue fixtures they're being upgraded from")
    func movieFilesMatchQueueFixtures() {
        // Tears of Steel's queue row is an upgrade off a 1080p BluRay; the
        // library has to report exactly that file or the manual-search diff and
        // the queue's upgrade card contradict each other.
        let tears = DemoMocks.movieFile(movieId: 203)
        #expect(tears?.quality?.name == "Bluray-1080p")
        #expect(tears?.size == 8_400_000_000)

        let queueRow = DemoMocks.radarrQueue.first { $0.entityId == 203 }
        #expect(queueRow?.existingQuality == tears?.quality?.name)
        #expect(queueRow?.existingSize == tears?.size)

        // Big Buck Bunny is a fresh grab — no file, so the no-diff path is
        // demoable too.
        #expect(DemoMocks.movieFile(movieId: 201) == nil)
    }

    @Test("Episode files resolve by id and carry quality + formats")
    func episodeFilesResolve() {
        let map = DemoMocks.sonarrEpisodeFileMap(seriesId: 101)
        guard let id = map.keys.sorted().first else {
            Issue.record("Pioneer One should have downloaded episodes")
            return
        }

        let file = DemoMocks.episodeFile(id: id)
        #expect(file != nil)
        // Both feed the upgrade diff; a nil quality renders it as "—".
        #expect(file?.quality?.name?.isEmpty == false)
        #expect(file?.customFormats?.isEmpty == false)
        #expect(DemoMocks.episodeFile(id: 999_999) == nil)
    }

    // MARK: - Library

    @Test("Library listings cover the demo universe")
    func libraryListings() {
        #expect(DemoMocks.radarrLibrary().count == DemoMocks.radarrDetails.count)
        #expect(DemoMocks.sonarrLibrary().count == DemoMocks.sonarrDetails.count)
        #expect(DemoMocks.whisparrLibrary().count == DemoMocks.whisparrDetails.count)
        // Two artists behind three albums.
        #expect(DemoMocks.lidarrLibrary().count == 2)
    }

    @Test("Library records agree with the file fixtures about what's on disk")
    func libraryHasFileAgreesWithFiles() {
        for record in DemoMocks.radarrLibrary() {
            guard let id = record.id else { continue }
            #expect(record.hasFile == (DemoMocks.movieFile(movieId: id) != nil))
        }
    }

    @Test("Lookups report a library id for owned titles and zero for the rest")
    func lookupsMarkOwnedTitles() {
        let owned = DemoMocks.radarrLookup(term: "Sintel")
        #expect(owned.first?.id == 202)

        let notOwned = DemoMocks.radarrLookup(term: "Cosmos Laundromat")
        #expect(notOwned.first?.id == 0)

        let series = DemoMocks.sonarrLookup(term: "Pioneer")
        #expect(series.first?.id == 101)
    }

    // MARK: - Queue actions

    @Test("Demo queue actions survive the next refresh")
    @MainActor func queueActionsStick() {
        DemoQueueState.reset()
        defer { DemoQueueState.reset() }

        let items = DemoMocks.radarrQueue
        guard let target = items.first(where: { $0.status == .downloading }) else {
            Issue.record("the demo queue should hold a downloading row")
            return
        }

        DemoQueueState.perform(.pause, on: target)
        // `apply` is what a refresh runs the fresh fixtures through.
        let afterPause = DemoQueueState.apply(DemoMocks.radarrQueue)
        #expect(afterPause.first { $0.id == target.id }?.status == .paused)

        DemoQueueState.perform(.resume, on: target)
        #expect(DemoQueueState.apply(DemoMocks.radarrQueue).first { $0.id == target.id }?.status == .downloading)

        DemoQueueState.perform(.delete, on: target)
        let afterDelete = DemoQueueState.apply(DemoMocks.radarrQueue)
        #expect(afterDelete.contains { $0.id == target.id } == false)
        #expect(afterDelete.count == items.count - 1)

        DemoQueueState.reset()
        #expect(DemoQueueState.apply(DemoMocks.radarrQueue).count == items.count)
    }
}
