import Testing
import Foundation
@testable import ArrCore

@Suite("DiscoverViewModel")
@MainActor
struct DiscoverViewModelTests {

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

    @Test("start() pulls from every available source and dedupes across them")
    func startPullsFromAllSourcesAndDedupes() async {
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [self.makeItem(2, .library), self.makeItem(3, .library)] },
            llm: nil
        )
        await vm.start()
        let keys = Set(vm.queue.map(\.dedupKey) + (vm.current.map { [$0.dedupKey] } ?? []))
        #expect(keys == ["tmdb:1", "tmdb:2", "tmdb:3"])
    }

    @Test("Skip is the only action that advances the deck, and it records the skip")
    func skipAdvancesAndRecords() async {
        // Skip (>>) is the only action that advances the deck.
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb), self.makeItem(3, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        #expect(vm.current?.dedupKey == "tmdb:1")
        vm.skip()
        #expect(vm.current?.dedupKey == "tmdb:2")
        vm.skip()
        #expect(vm.current?.dedupKey == "tmdb:3")
        #expect(vm.sessionSkipped.map(\.dedupKey) == ["tmdb:1", "tmdb:2"])
    }

    @Test("markPicked records the pick without advancing, and counts a card once")
    func markPickedRecordsWithoutAdvancing() async {
        // + = add: records a pick (drives QuizResumeCard's count) but does NOT
        // advance — a cancelled add returns to the same card. Deduped.
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [self.makeItem(1, .tmdb), self.makeItem(2, .tmdb)] },
            library: { _ in [] }, llm: nil
        )
        await vm.start()
        #expect(vm.current?.dedupKey == "tmdb:1")
        vm.markPicked()
        #expect(vm.sessionMatched.map(\.dedupKey) == ["tmdb:1"])
        #expect(vm.current?.dedupKey == "tmdb:1", "markPicked must not advance the deck")
        vm.markPicked()   // pressing + twice on the same card counts once
        #expect(vm.sessionMatched.map(\.dedupKey) == ["tmdb:1"])
    }

    @Test("A throwing source drops only itself; the others still fill the deck")
    func perSourceFailureDropsOnlyThatSource() async {
        struct Boom: Error {}
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in throw Boom() },
            library: { _ in [self.makeItem(7, .library)] },
            llm: nil
        )
        await vm.start()
        #expect(vm.current?.dedupKey == "tmdb:7")
        #expect(vm.failedSources.contains(.tmdb))
    }

    @Test("The LLM source stays dormant while the mood is empty")
    func llmDormantWhenMoodEmpty() async {
        var llmCalled = false
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in [] }, library: { _ in [] },
            llm: { _, _ in llmCalled = true; return [] }
        )
        vm.moodText = ""
        await vm.start()
        #expect(!llmCalled)
    }

    @Test("requestMoreLLM appends to the queue and accumulates the exclusion list")
    func requestMoreLLMAccumulatesExcludes() async {
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
        #expect(receivedExcludes.last == [])
        #expect(vm.queue.count + (vm.current == nil ? 0 : 1) == 2)

        await vm.requestMoreLLM()
        #expect(receivedExcludes.count == 2)
        #expect(receivedExcludes[1].count == 2, "second call should exclude the 2 already-shown")
    }

    @Test("Filling the bucket interleaves the sources round-robin")
    func fillBucketInterleavesSources() async {
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
        #expect(order == ["tmdb:100", "tmdb:200", "tmdb:101", "tmdb:201", "tmdb:102", "tmdb:202"])
    }

    @Test("A source error is captured as a message plus a zero count")
    func sourceErrorCapturesMessageAndZeroCount() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let vm = freshVM()
        vm.configure(
            tmdb: { _, _ in throw Boom() },
            library: { _ in [self.makeItem(1, .library)] },
            llm: nil
        )
        await vm.start()
        #expect(vm.failedSources.contains(.tmdb))
        #expect(vm.lastFetchedCounts[.tmdb] == 0)
        #expect(vm.sourceErrors[.tmdb] != nil)
        #expect(vm.sourceErrors[.tmdb]?.contains("boom") ?? false)
    }

    // MARK: - Top-up rounds

    @Test("shownDedupKeys covers seeded, consumed and extended cards, and resets on seed")
    func shownKeysCoverTheWholeSession() async {
        let vm = freshVM()
        vm.seed(items: [makeItem(1, .llm), makeItem(2, .llm)], mood: "cosy")
        vm.skip()   // tmdb:1 leaves the deck but stays "shown"
        vm.extend(items: [makeItem(3, .llm)])
        #expect(vm.shownDedupKeys == ["tmdb:1", "tmdb:2", "tmdb:3"])

        vm.seed(items: [makeItem(9, .llm)], mood: "loud")
        #expect(vm.shownDedupKeys == ["tmdb:9"])
    }

    @Test("An all-duplicate top-up round adds nothing and leaves the deck empty")
    func duplicateTopUpRoundAddsNothing() async {
        // The failure the user hit: the agent's appended round comes back with
        // titles the deck has already shown, `extend` drops every one of them,
        // and the surface has no way to tell that apart from "there is nothing
        // left" — so it says "No more cards" while a retry still finds picks.
        let vm = freshVM()
        vm.seed(items: [makeItem(1, .llm)], mood: "cosy")
        vm.skip()
        #expect(vm.current == nil)

        let before = vm.sessionTotal
        vm.extend(items: [makeItem(1, .llm)])
        #expect(vm.current == nil)
        #expect(vm.sessionTotal == before, "a duplicate round must not inflate the total")
    }

    @Test("Append rounds are filtered against the live deck before they reach it")
    func appendRoundsAreFilteredAgainstTheDeck() {
        let shown: Set<String> = ["tmdb:1", "tmdb:2"]
        let round = [makeItem(1, .llm), makeItem(3, .llm), makeItem(2, .llm)]
        let split = LocalToolBackend.splitAlreadyShown(round, shown: shown)
        #expect(split.fresh.map(\.dedupKey) == ["tmdb:3"])
        #expect(split.dropped.map(\.dedupKey) == ["tmdb:1", "tmdb:2"])
    }
}
