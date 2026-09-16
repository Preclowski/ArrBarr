import Testing
@testable import ArrCore

/// The Library tab's filter counts and filtered list are recomputed by `body`,
/// and the filter strip sits in the grid's safe area — so they re-ran while the
/// grid scrolled. Both are memoized now; these tests pin the memoization
/// itself (the predicate must not be consulted twice for the same key) and the
/// invalidation that keeps it honest.
@Suite("Library memoization")
@MainActor
struct LibraryMemoizationTests {

    private func entry(_ id: String, state: LibraryEntry.FileState) -> LibraryEntry {
        LibraryEntry(id: id, source: .radarr, arrId: 1, title: id, year: nil,
                     posterURL: nil, posterRequiresAuth: false, state: state,
                     sizeOnDisk: 0, fileCount: nil, totalCount: nil, fileQuality: nil,
                     profileName: nil, customFormats: [], customFormatScore: 0,
                     fileName: nil, genres: [], runtime: nil, certification: nil,
                     ratingImdb: nil, ratingTmdb: nil, ratingArr: nil,
                     releaseStatus: nil, overview: nil, searchIndex: "",
                     releaseDate: nil, dateAdded: nil)
    }

    @Test("A repeated count is served from the cache, not from a second pass")
    func countIsMemoized() {
        let vm = LibraryViewModel()
        let rows = [entry("a", state: .complete), entry("b", state: .missing)]

        var passes = 0
        let predicate: (LibraryEntry) -> Bool = { _ in passes += 1; return true }

        #expect(vm.count(.radarr, cacheKey: "all", over: rows, where: predicate) == 2)
        #expect(passes == 2)
        #expect(vm.count(.radarr, cacheKey: "all", over: rows, where: predicate) == 2)
        #expect(passes == 2, "second call must not walk the entries again")
    }

    @Test("A repeated filtered list is served from the cache")
    func visibleIsMemoized() {
        let vm = LibraryViewModel()
        let rows = [entry("a", state: .complete), entry("b", state: .missing)]

        var passes = 0
        let predicate: (LibraryEntry) -> Bool = { passes += 1; return $0.state == .missing }

        #expect(vm.visible(.radarr, cacheKey: "title|missing", from: rows, where: predicate).count == 1)
        #expect(passes == 2)
        #expect(vm.visible(.radarr, cacheKey: "title|missing", from: rows, where: predicate).count == 1)
        #expect(passes == 2)
    }

    @Test("Different keys are cached apart")
    func keysDoNotCollide() {
        let vm = LibraryViewModel()
        let rows = [entry("a", state: .complete), entry("b", state: .missing)]

        #expect(vm.count(.radarr, cacheKey: "all", over: rows) { _ in true } == 2)
        #expect(vm.count(.radarr, cacheKey: "missing", over: rows) { $0.state == .missing } == 1)
    }
}
