import Testing
import Foundation
@testable import ArrCore

/// The one file-state rule behind the Library tab, the detail heroes and the
/// ownership chip. These pin the cases where the three copies it replaced used
/// to disagree.
@Suite("Library file state")
struct LibraryFileStateTests {

    private static func series(_ json: String) throws -> SonarrLibraryRecord {
        try JSONDecoder().decode(SonarrLibraryRecord.self, from: Data(json.utf8))
    }

    @Test("Series counts are summed from the season statistics")
    func seriesCountsSumSeasons() throws {
        let rec = try Self.series(#"""
        {"id": 7, "monitored": true,
         "statistics": {"episodeCount": 99, "episodeFileCount": 99},
         "seasons": [
           {"seasonNumber": 1, "statistics": {"episodeCount": 10, "episodeFileCount": 10}},
           {"seasonNumber": 2, "statistics": {"episodeCount": 8, "episodeFileCount": 3}}
         ]}
        """#)
        #expect(rec.episodeFileCounts == EpisodeFileCounts(have: 13, total: 18))
        #expect(LibraryEntry.FileState.series(monitored: rec.monitored, counts: rec.episodeFileCounts) == .partial)
        #expect(rec.ownership == LibraryOwnership(arrId: 7, isDownloaded: false))
    }

    @Test("A complete series is downloaded")
    func completeSeriesIsDownloaded() throws {
        let rec = try Self.series(#"""
        {"id": 3, "monitored": true,
         "seasons": [{"seasonNumber": 1, "statistics": {"episodeCount": 6, "episodeFileCount": 6}}]}
        """#)
        #expect(LibraryEntry.FileState.series(monitored: true, counts: rec.episodeFileCounts) == .complete)
        #expect(rec.ownership?.isDownloaded == true)
    }

    @Test("Nothing aired yet reads not-available, not missing")
    func nothingAiredIsNotAvailable() {
        let counts = EpisodeFileCounts(have: 0, total: 0)
        #expect(LibraryEntry.FileState.series(monitored: true, counts: counts) == .notAvailable)
        #expect(LibraryEntry.FileState.series(monitored: true, counts: EpisodeFileCounts(have: 0, total: 4)) == .missing)
    }

    @Test("A file on disk wins over the unmonitored flag")
    func downloadedWinsOverUnmonitored() {
        #expect(LibraryEntry.FileState.movie(monitored: false, hasFile: true) == .complete)
        #expect(LibraryEntry.FileState.movie(monitored: false, hasFile: false) == .unmonitored)
        #expect(LibraryEntry.FileState.series(monitored: false, counts: EpisodeFileCounts(have: 3, total: 8)) == .unmonitored)
        // Unknown monitored flag (payload still loading) is not "unmonitored".
        #expect(LibraryEntry.FileState.movie(monitored: nil, hasFile: true) == .complete)
    }

    @Test("Stamping ownership sets id and downloaded together, and nil clears both")
    func stampingOwnership() {
        let base = SearchResult(
            externalId: 550, foreignId: "550", title: "Fight Club", subtitle: nil,
            year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: nil, runtime: nil, genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr)
        let owned = base.withLibraryOwnership(LibraryOwnership(arrId: 42, isDownloaded: true))
        #expect(owned.inLibraryArrId == 42)
        #expect(owned.libraryDownloaded)
        let cleared = owned.withLibraryOwnership(nil)
        #expect(cleared.inLibraryArrId == nil)
        #expect(!cleared.libraryDownloaded)
    }
}

@Suite("Library entry as a search row")
struct LibraryEntrySearchResultTests {
    @Test("A library entry maps to an owned, correctly stamped search row")
    func libraryEntryMapsToOwnedRow() {
        let entry = LibraryEntry(
            id: "radarr-42", source: .radarr, arrId: 42, externalId: 550, title: "Fight Club",
            year: 1999, posterURL: nil, posterRequiresAuth: false, state: .complete,
            sizeOnDisk: 0, fileCount: nil, totalCount: nil, fileQuality: nil, profileName: nil,
            customFormats: [], customFormatScore: 0, fileName: nil, genres: ["Drama"], runtime: 139,
            certification: "R", ratingImdb: 8.8, ratingTmdb: 8.4, ratingArr: nil,
            releaseStatus: nil, searchIndex: "fight club")
        let row = SearchResult(libraryEntry: entry)
        #expect(row.inLibraryArrId == 42)
        #expect(row.libraryDownloaded)
        #expect(row.externalId == 550)
        #expect(row.source == .radarr)
        #expect(row.rating == 8.4)
    }

    @Test("An entry whose poster is served by the arr keeps needing the API key")
    func posterAuthSurvivesTheMapping() {
        let entry = LibraryEntry(
            id: "radarr-9", source: .radarr, arrId: 9, externalId: 603, title: "The Matrix",
            year: 1999, posterURL: URL(string: "http://radarr.local/MediaCover/9/poster.jpg"),
            posterRequiresAuth: true, state: .complete,
            sizeOnDisk: 0, fileCount: nil, totalCount: nil, fileQuality: nil, profileName: nil,
            customFormats: [], customFormatScore: 0, fileName: nil, genres: [], runtime: nil,
            certification: nil, ratingImdb: nil, ratingTmdb: nil, ratingArr: nil,
            releaseStatus: nil, searchIndex: "the matrix")
        // Dropped here, the row asks the arr for artwork with no key and gets
        // a 401 — every local hit renders as a placeholder.
        #expect(SearchResult(libraryEntry: entry).posterRequiresAuth)
    }

    @Test("A library entry without a file maps to a not-downloaded row")
    func missingEntryIsNotDownloaded() {
        let entry = LibraryEntry(
            id: "sonarr-7", source: .sonarr, arrId: 7, externalId: 81189, title: "Breaking Bad",
            year: 2008, posterURL: nil, posterRequiresAuth: false, state: .partial,
            sizeOnDisk: 0, fileCount: 3, totalCount: 62, fileQuality: nil, profileName: nil,
            customFormats: [], customFormatScore: 0, fileName: nil, genres: [], runtime: nil,
            certification: nil, ratingImdb: nil, ratingTmdb: nil, ratingArr: 9.3,
            releaseStatus: nil, searchIndex: "breaking bad")
        let row = SearchResult(libraryEntry: entry)
        #expect(row.inLibraryArrId == 7)
        #expect(!row.libraryDownloaded)
        #expect(row.rating == 9.3)
    }
}
