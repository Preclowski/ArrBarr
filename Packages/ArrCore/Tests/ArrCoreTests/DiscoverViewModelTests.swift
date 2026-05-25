import XCTest
@testable import ArrCore

@MainActor
final class DiscoverViewModelTests: XCTestCase {

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
        let vm = DiscoverViewModel()
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
        let vm = DiscoverViewModel()
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
        let vm = DiscoverViewModel()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:1")
        XCTAssertTrue(vm.matched.isEmpty)
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:1"])
        XCTAssertEqual(vm.current?.dedupKey, "tmdb:2")
        await vm.swipe(right: false)
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:1"], "left swipe must not append")
    }

    func test_removeMatch_dropsByDedupKey() async {
        let vm = DiscoverViewModel()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.count, 2)
        vm.removeMatch(id: "tmdb:1")
        XCTAssertEqual(vm.matched.map(\.dedupKey), ["tmdb:2"])
    }

    func test_reset_clearsMatched() async {
        let vm = DiscoverViewModel()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        XCTAssertEqual(vm.matched.count, 1)
        await vm.reshuffle()
        XCTAssertTrue(vm.matched.isEmpty)
    }

    func test_topUp_fetchesMoreWhenQueueBelowThreshold() async {
        var tmdbCalls = 0
        let vm = DiscoverViewModel()
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
        let vm = DiscoverViewModel()
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
        let vm = DiscoverViewModel()
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
        let vm = DiscoverViewModel()
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

    func test_llmDrain_appliesSuggestedFilters() async {
        let suggested = DiscoverLLMPrompt.SuggestedFilters(
            genres: [.comedy, .drama], decade: .nineties, status: .owned)
        let vm = DiscoverViewModel()
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
}
