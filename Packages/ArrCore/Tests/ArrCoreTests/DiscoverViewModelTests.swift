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
            llm: { _, _ in llmCalled = true; return [] }
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
                return [self.makeItem(base + 1, .llm), self.makeItem(base + 2, .llm)]
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

    func test_swipeRight_setsHasUnseenPicks() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in (1...5).map { self.makeItem($0, .tmdb) } },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        XCTAssertFalse(vm.hasUnseenPicks, "no unseen picks before any swipe")
        await vm.swipe(right: true)
        XCTAssertTrue(vm.hasUnseenPicks, "right-swipe should set hasUnseenPicks")
    }

    func test_swipeLeft_doesNotSetHasUnseenPicks() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in (1...5).map { self.makeItem($0, .tmdb) } },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: false)
        XCTAssertFalse(vm.hasUnseenPicks, "left-swipe should not set hasUnseenPicks")
    }

    func test_acknowledgeUnseenPicks_clearsFlag() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in (1...5).map { self.makeItem($0, .tmdb) } },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        await vm.swipe(right: true)
        XCTAssertTrue(vm.hasUnseenPicks)
        vm.acknowledgeUnseenPicks()
        XCTAssertFalse(vm.hasUnseenPicks, "acknowledgeUnseenPicks should clear the flag")
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
}
