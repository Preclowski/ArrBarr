import Foundation
import SwiftUI

@MainActor
public final class DiscoverViewModel: ObservableObject {

    public enum Source: Hashable, CaseIterable, Sendable {
        case tmdb, library, llm
    }

    public enum DiscoverStage: Sendable { case picker, tinder }

    // MARK: - LLM result type

    public struct LLMResult: Sendable {
        public let items: [DiscoverItem]
        public let suggestedFilters: DiscoverLLMPrompt.SuggestedFilters?
        public let resolvedPersonIds: [Int]
        public init(items: [DiscoverItem],
                    suggestedFilters: DiscoverLLMPrompt.SuggestedFilters?,
                    resolvedPersonIds: [Int] = []) {
            self.items = items
            self.suggestedFilters = suggestedFilters
            self.resolvedPersonIds = resolvedPersonIds
        }
    }

    // MARK: - Persistence keys

    private static let hasPickedKindKey = "ArrBarr.discoverHasPickedKind"

    // MARK: - Published state

    @Published public var stage: DiscoverStage = .picker

    @Published public var hasPickedKind: Bool {
        didSet {
            defaults.set(hasPickedKind, forKey: Self.hasPickedKindKey)
        }
    }
    @Published public private(set) var current: DiscoverItem?
    @Published public private(set) var queue: [DiscoverItem] = []
    @Published public var filter = DiscoverFilter()
    @Published public var moodText: String = ""
    @Published public private(set) var failedSources: Set<Source> = []
    /// tmdbId → fetched credits. Populated lazily when the view requests
    /// a card's credits via `fetchCreditsIfNeeded`. Used by the card's
    /// back face for cast headshots + director.
    @Published public private(set) var creditsCache: [Int: TMDBCredits] = [:]
    @Published public private(set) var llmPoolExhausted: Bool = false
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var matched: [DiscoverItem] = []
    /// Incremented only by user-driven actions (mood submit, filter chip
    /// taps, explicit reshuffle). The View's `task(id:)` keys on this so
    /// LLM-applied filter changes don't trigger an infinite reshuffle loop.
    @Published public private(set) var userActionTick: Int = 0
    /// Media kind the user selected in the picker segmented control.
    /// Persisted to UserDefaults so the choice survives app restarts.
    private static let mediaSelectionKey = "ArrBarr.discoverMediaSelection"
    private let defaults: UserDefaults

    @Published public var mediaSelection: DiscoverMediaSelection {
        didSet {
            defaults.set(mediaSelection.rawValue, forKey: Self.mediaSelectionKey)
        }
    }

    // MARK: - Source closures

    public typealias TMDBSource = @MainActor (DiscoverFilter, Int) async throws -> [DiscoverItem]
    public typealias LibrarySource = @MainActor (DiscoverFilter) async throws -> [DiscoverItem]
    public typealias LLMSource = @MainActor ([String], String) async throws -> LLMResult

    private var tmdb: TMDBSource?
    private var library: LibrarySource?
    private var llm: LLMSource?

    // MARK: - Internals

    private var seenKeys = Set<String>()
    private var llmShownTitles: [String] = []
    private var tmdbPage = 0
    private var libraryDrained = false
    private var llmDormant = false
    private var topUpTask: Task<Void, Never>?
    private let topUpThreshold = 5
    private var creditsFetchingIds = Set<Int>()
    private var tmdbApiKey: String = ""

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.mediaSelectionKey)
            .flatMap { DiscoverMediaSelection(rawValue: $0) }
        self.mediaSelection = stored ?? .movie
        self.hasPickedKind = defaults.bool(forKey: Self.hasPickedKindKey)
    }

    public func configure(tmdb: TMDBSource?, library: LibrarySource?, llm: LLMSource?) {
        self.tmdb = tmdb
        self.library = library
        self.llm = llm
    }

    public func configureCredits(apiKey: String) {
        tmdbApiKey = apiKey
    }

    /// Lazily fetch cast + crew for a TMDB movie id. Safe to call on every
    /// hover — silently no-ops if already cached or fetching.
    public func fetchCreditsIfNeeded(for tmdbId: Int) {
        guard !tmdbApiKey.isEmpty,
              tmdbId > 0,
              creditsCache[tmdbId] == nil,
              !creditsFetchingIds.contains(tmdbId) else { return }
        creditsFetchingIds.insert(tmdbId)
        Task { @MainActor in
            defer { creditsFetchingIds.remove(tmdbId) }
            let client = TMDBClient(apiKey: tmdbApiKey)
            if let credits = try? await client.movieCredits(movieId: tmdbId) {
                creditsCache[tmdbId] = credits
            }
        }
    }

    // MARK: - User-action tick helpers

    /// Call when the user explicitly changes a filter (decade, genre, status,
    /// monitoredOnly). This increments the tick so the View's task(id:)
    /// fires a reshuffle — but LLM-applied filter changes do NOT call this,
    /// avoiding an infinite loop.
    public func userChangedFilter() {
        userActionTick &+= 1
    }

    /// Call when the user submits the mood field.
    public func userSubmittedMood() {
        userActionTick &+= 1
    }

    /// Call when the user changes the media kind selector (Movies / Shows / AI decides).
    public func mediaSelectionChanged() {
        userActionTick &+= 1
    }

    // MARK: - Lifecycle

    public func start() async {
        reset()
        isLoading = true
        await fillBucket()
        advanceIfNeeded()
        isLoading = false
    }

    public func reshuffle() async {
        await start()
    }

    /// Right swipe appends the current card to `matched` (no overlay
    /// interrupts the swiping). Left swipe discards. Either way the next
    /// card advances and a top-up may fire.
    public func swipe(right: Bool) async {
        guard let item = current else { return }
        if right {
            matched.append(item)
        }
        current = nil
        advanceIfNeeded()
        if queue.count < topUpThreshold {
            scheduleTopUp()
        }
    }

    public func removeMatch(id: String) {
        matched.removeAll { $0.dedupKey == id }
    }

    public func requestMoreLLM() async {
        guard llm != nil,
              !moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        llmDormant = false
        llmPoolExhausted = false
        let items = await fetchItems(source: .llm)
        appendInterleaved([items])
        advanceIfNeeded()
    }

    // MARK: - Round-robin fill

    private func fillBucket() async {
        let sources = availableSources()
        // Fetch each source's items concurrently. Concurrency speeds up
        // first-card render and bucket top-up — the dominant cost is the
        // HTTP round-trip, and the three sources can run in parallel.
        var perSource: [[DiscoverItem]] = Array(repeating: [], count: sources.count)
        await withTaskGroup(of: (Int, [DiscoverItem]).self) { group in
            for (i, src) in sources.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (i, []) }
                    let items = await self.fetchItems(source: src)
                    return (i, items)
                }
            }
            for await (i, items) in group {
                perSource[i] = items
            }
        }
        // Round-robin merge: round 0 takes first item from each source,
        // round 1 the second from each, etc. Sources that ran out earlier
        // simply get skipped in later rounds.
        appendInterleaved(perSource)
    }

    private func availableSources() -> [Source] {
        var out: [Source] = []
        if tmdb != nil && !failedSources.contains(.tmdb) { out.append(.tmdb) }
        if library != nil && !failedSources.contains(.library) && !libraryDrained {
            out.append(.library)
        }
        if llm != nil && !failedSources.contains(.llm) && !llmDormant
           && !moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.llm)
        }
        return out
    }

    /// Fetches items from a single source. Returns the items WITHOUT
    /// touching the queue — caller is responsible for merging.
    /// Same side effects as before: marks failure, advances tmdbPage,
    /// flips libraryDrained / llmDormant / llmPoolExhausted / llmShownTitles.
    private func fetchItems(source: Source) async -> [DiscoverItem] {
        do {
            switch source {
            case .tmdb:
                tmdbPage += 1
                return try await tmdb!(filter, tmdbPage)
            case .library:
                let items = try await library!(filter)
                libraryDrained = true
                return items
            case .llm:
                let result = try await llm!(llmShownTitles, moodText)
                if result.items.isEmpty {
                    llmDormant = true
                    llmPoolExhausted = true
                } else {
                    llmShownTitles.append(contentsOf: result.items.map(titleYearKey))
                }
                if let filters = result.suggestedFilters {
                    applySuggestedFilters(filters, personIds: result.resolvedPersonIds)
                }
                return result.items
            }
        } catch {
            failedSources.insert(source)
            errorMessage = "Discover source failed: \(source) (\(error))"
            return []
        }
    }

    private func appendInterleaved(_ lists: [[DiscoverItem]]) {
        let maxLen = lists.map(\.count).max() ?? 0
        for round in 0..<maxLen {
            for list in lists {
                if round < list.count {
                    let it = list[round]
                    if seenKeys.insert(it.dedupKey).inserted {
                        queue.append(it)
                    }
                }
            }
        }
    }

    /// Apply LLM-suggested filters to the current filter without triggering
    /// userActionTick — so the View's task(id: userActionTick) does NOT fire
    /// a new reshuffle, breaking the potential infinite loop.
    ///
    /// Only fills empty/default slots — user-set filters are sticky. This
    /// means LLM populates filters on first mood entry (when everything is
    /// default) but on subsequent mood/filter edits the user's choices win.
    private func applySuggestedFilters(_ s: DiscoverLLMPrompt.SuggestedFilters,
                                       personIds: [Int] = []) {
        var f = filter
        // Only fill empty/default slots. User-set filters are sticky.
        if f.genres.isEmpty && !s.genres.isEmpty {
            f.genres = Set(s.genres)
        }
        if f.decade == .any, let d = s.decade {
            f.decade = d
        }
        if f.status == .any, let st = s.status {
            f.status = st
        }
        if f.personIds.isEmpty && !personIds.isEmpty {
            f.personIds = personIds
        }
        filter = f
    }

    private func advanceIfNeeded() {
        if current == nil, !queue.isEmpty {
            current = queue.removeFirst()
        }
    }

    private func scheduleTopUp() {
        if let existing = topUpTask, !existing.isCancelled { return }
        topUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.topUpTask = nil }
            let sources = self.availableSources()
            var perSource: [[DiscoverItem]] = Array(repeating: [], count: sources.count)
            await withTaskGroup(of: (Int, [DiscoverItem]).self) { group in
                for (i, src) in sources.enumerated() {
                    group.addTask { [weak self] in
                        guard let self else { return (i, []) }
                        let items = await self.fetchItems(source: src)
                        return (i, items)
                    }
                }
                for await (i, items) in group {
                    perSource[i] = items
                }
            }
            self.appendInterleaved(perSource)
            self.advanceIfNeeded()
        }
    }

    private func reset() {
        current = nil
        queue.removeAll()
        seenKeys.removeAll()
        llmShownTitles.removeAll()
        tmdbPage = 0
        libraryDrained = false
        llmDormant = false
        llmPoolExhausted = false
        failedSources.removeAll()
        errorMessage = nil
        matched.removeAll()
        creditsCache.removeAll()
        creditsFetchingIds.removeAll()
        // Note: mediaSelection is intentionally NOT reset here — it's a
        // user-level preference that persists across reshuffles.
        topUpTask?.cancel()
        topUpTask = nil
    }

    private func titleYearKey(_ item: DiscoverItem) -> String {
        let year = item.result.year.map(String.init) ?? ""
        return year.isEmpty ? item.result.title : "\(item.result.title) (\(year))"
    }
}
