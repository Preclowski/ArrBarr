import XCTest
@testable import ArrCore

@MainActor
final class DiscoverViewModelTests: XCTestCase {

    /// Each test gets a fresh, isolated UserDefaults to avoid cross-test
    /// contamination from persisted mediaSelection values.
    private func freshVM() -> DiscoverViewModel {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return DiscoverViewModel(defaults: suite)
    }

    private func makeItem(_ id: Int, _ origin: DiscoverItem.Origin) -> DiscoverItem {
        let r = SearchResult(
            id: id, foreignId: String(id), title: "T\(id)", subtitle: nil,
            year: 2010, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: 100,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
        return DiscoverItem(result: r, action: .addToRadarr, originLabel: origin)
    }

    func test_start_pullsFromAllAvailableSources_andDedupes() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [self.makeItem(2, .library), self.makeItem(3, .library)] },
            llm: nil
        )
        await vm.start()
        XCTAssertEqual(Set(vm.queue.map(\.dedupKey) + (vm.current.map { [$0.dedupKey] } ?? [])),
                       ["tmdb:1", "tmdb:2", "tmdb:3"])
    }

    func test_swipe_advancesToNextCard() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb), self.makeItem(3, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:1")
        await vm.swipe(right: true)
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:2")
        await vm.swipe(right: false)
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:3")
    }

    func test_swipeRight_appendsToMatched_andAdvances() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb), self.makeItem(3, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:1")
        XCTAssertTrue(vm.matched.isEmpty)
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:1"])
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:2")
        await vm.swipe(right: true)
        // Newest first: item 2 lands at index 0.
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:2", "tmdb:1"], "newest pick must be at index 0")
        await vm.swipe(right: false)
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:2", "tmdb:1"], "left swipe must not append")
    }

    func test_removeMatch_dropsByDedupKey() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.count, 2)
        // Newest-first: matched = ["tmdb:2", "tmdb:1"]. Remove item 1.
        vm.removeMatch(id: "tmdb:1")
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:2"])
    }

    func test_reshuffle_preservesMatched_andDedupesAgainstThem() async {
        // Matched is sticky across mood changes — reshuffle must NOT
        // clear it. seenKeys gets re-seeded with picked items so the
        // next fetch doesn't surface the same titles.
        let vm = freshVM()
        var call = 0
        vm.configure(
            tmdb: { _, _ in
                call += 1
                return [self.makeItem(1, .tmdb)]
            },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.count, 1)
        await vm.reshuffle()
        XCTAssertEqual(vm.matched.count, 1, "picks survive reshuffle")
        // Same item from the next fetch is filtered out as already picked.
        XCTAssertNil(vm.current, "picked item shouldn't resurface")
    }

    func test_clearMatched_emptiesPicks() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.count, 2)
        vm.clearMatched()
        XCTAssertTrue(vm.matched.isEmpty)
    }

    func test_topUp_fetchesMoreWhenQueueBelowThreshold() async {
        var tmdbCalls = 0
        let vm = freshVM()
        vm.configure(
            tmdb: { _, page in
                tmdbCalls += 1
                let base = (page - 1) * 10
                return (1...10).map { self.makeItem(base + $0, .tmdb) }
            },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        XCTAssertEqual(tmdbCalls, 1)
        for _ in 0..<7 { await vm.swipe(right: false) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThanOrEqual(tmdbCalls, 2)
    }

    func test_perSourceFailure_dropsOnlyThatSource() async {
        struct Boom: Error {}
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in throw Boom() },
            library: { _ in [self.makeItem(7, .library)] },
            llm: nil
        )
        await vm.start()
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:7")
        XCTAssertTrue(vm.failedSources.contains(.tmdb))
    }

    func test_llmDormantWhenMoodEmpty() async {
        var llmCalled = false
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [] }, library: { _ in [] },
            llm: { _, _ in llmCalled = true; return .init(items: [], suggestedFilters: nil) }
        )
        vm.moodText = ""
        await vm.start()
        XCTAssertFalse(llmCalled)
    }

    func test_requestMoreLLM_appendsToQueueAndAccumulatesExcludes() async {
        var receivedExcludes: [[String]] = []
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [] }, library: { _ in [] },
            llm: { excludes, _ in
                receivedExcludes.append(excludes)
                let base = receivedExcludes.count * 100
                return .init(items: [self.makeItem(base + 1, .llm), self.makeItem(base + 2, .llm)],
                             suggestedFilters: nil)
            }
        )
        vm.moodText = "noir"
        await vm.start()
        XCTAssertEqual(receivedExcludes.last, [])
        XCTAssertEqual(vm.queue.count + (vm.current == nil ? 0 : 1), 2)

        await vm.requestMoreLLM()
        XCTAssertEqual(receivedExcludes.count, 2)
        XCTAssertEqual(receivedExcludes[1].count, 2, "second call should exclude the 2 already-shown")
    }

    func test_fillBucket_interleavesSources() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(100, .tmdb), self.makeItem(101, .tmdb), self.makeItem(102, .tmdb)] },
            library: { _ in [self.makeItem(200, .library), self.makeItem(201, .library), self.makeItem(202, .library)] },
            llm: nil
        )
        await vm.start()
        let order = ([vm.current?.dedupKey] + vm.queue.map(\.dedupKey)).compactMap { $0 }
        // Round 0 visits source[0]=tmdb, source[1]=library; round 1 same; round 2 same.
        // Expected: [tmdb:100, tmdb:200, tmdb:101, tmdb:201, tmdb:102, tmdb:202]
        XCTAssertEqual(order, ["tmdb:100", "tmdb:200", "tmdb:101", "tmdb:201", "tmdb:102", "tmdb:202"])
    }

    func test_swipeRight_milestoneTickBumps_everyTenPicks() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in (1...30).map { self.makeItem($0, .tmdb) } },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        let initialTick = vm.picksMilestoneTick
        for _ in 0..<9 { await vm.swipe(right: true) }
        XCTAssertEqual(vm.picksMilestoneTick, initialTick, "9 picks shouldn't trip the tick")
        await vm.swipe(right: true)
        XCTAssertEqual(vm.picksMilestoneTick, initialTick + 1, "10th pick trips the tick")
        for _ in 0..<10 { await vm.swipe(right: true) }
        XCTAssertEqual(vm.picksMilestoneTick, initialTick + 2, "20th pick trips it again")
    }

    func test_autoJumpDisabled_suppressesMilestoneTick() async {
        let vm = freshVM()
        vm.autoJumpEnabled = false
        vm.configure(
            tmdb: { _, _ in (1...20).map { self.makeItem($0, .tmdb) } },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        let initial = vm.picksMilestoneTick
        for _ in 0..<10 { await vm.swipe(right: true) }
        XCTAssertEqual(vm.picksMilestoneTick, initial,
                       "10 picks with auto-jump disabled shouldn't fire the tick")
    }

    func test_sourceError_capturesMessageAndZeroCount() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in throw Boom() },
            library: { _ in [self.makeItem(1, .library)] },
            llm: nil
        )
        await vm.start()
        XCTAssertTrue(vm.failedSources.contains(.tmdb))
        XCTAssertEqual(vm.lastFetchedCounts[.tmdb], 0)
        XCTAssertNotNil(vm.sourceErrors[.tmdb])
        XCTAssertTrue(vm.sourceErrors[.tmdb]?.contains("boom") ?? false)
    }

    func test_llmDrain_appliesSuggestedFilters() async {
        let suggested = DiscoverLLMPrompt.SuggestedFilters(
            genres: [.comedy, .drama], decade: .nineties, status: .owned)
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [] }, library: { _ in [] },
            llm: { _, _ in
                DiscoverViewModel.LLMResult(
                    items: [self.makeItem(1, .llm)],
                    suggestedFilters: suggested)
            }
        )
        vm.moodText = "x"
        await vm.start()
        XCTAssertEqual(vm.filter.genres, [.comedy, .drama])
        XCTAssertEqual(vm.filter.decade, .nineties)
        XCTAssertEqual(vm.filter.status, .owned)
    }

    func test_suggestedFilters_sortsByUsageDescending() {
        let vm = freshVM()
        vm.bumpPersonUsage("Quentin Tarantino")
        vm.bumpPersonUsage("Quentin Tarantino")
        vm.bumpPersonUsage("Christopher Nolan")
        let ids = vm.suggestedFilters.map(\.id)
        let tarantinoIdx = ids.firstIndex(of: "person.Quentin Tarantino")
        let nolanIdx = ids.firstIndex(of: "person.Christopher Nolan")
        XCTAssertNotNil(tarantinoIdx)
        XCTAssertNotNil(nolanIdx)
        XCTAssertLessThan(tarantinoIdx!, nolanIdx!,
                          "More-used Tarantino should come before less-used Nolan")
    }

    func test_suggestedFilters_excludesActiveFilters() {
        let vm = freshVM()
        vm.filter.genres = [.comedy]
        let ids = vm.suggestedFilters.map(\.id)
        XCTAssertFalse(ids.contains("genre.\(DiscoverGenre.comedy.rawValue)"),
                       "Comedy is active, should not appear in suggestions")
        XCTAssertTrue(ids.contains("genre.\(DiscoverGenre.drama.rawValue)"),
                      "Inactive Drama should still appear")
    }

    func test_suggestedFilters_coldStartReturnsCuratedTen() {
        let vm = freshVM()
        let filters = vm.suggestedFilters
        XCTAssertEqual(filters.count, 10,
                       "Fresh VM should show 10 curated discovery suggestions")
        // First entry should be the top-of-curation Tarantino.
        XCTAssertEqual(filters.first?.id, "person.Quentin Tarantino")
    }

    func test_suggestionsByCategory_includesAiStarters_whenLLMAvailable() {
        let vm = freshVM()
        let grouped = vm.suggestionsByCategory(llmAvailable: true)
        XCTAssertFalse((grouped[.ai] ?? []).isEmpty,
                       "AI bucket should expose starter prompts when LLM available")
        XCTAssertTrue((grouped[.people] ?? []).contains(where: { $0.id == "person.Quentin Tarantino" }))
    }

    func test_suggestionsByCategory_excludesAi_whenLLMUnavailable() {
        let vm = freshVM()
        let grouped = vm.suggestionsByCategory(llmAvailable: false)
        XCTAssertNil(grouped[.ai], "AI bucket should be absent without LLM")
    }
}
