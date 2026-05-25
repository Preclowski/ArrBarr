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
        await drain(source: .llm)
        advanceIfNeeded()
    }

    // MARK: - Round-robin fill

    private func fillBucket() async {
        for src in availableSources() {
            await drain(source: src)
        }
    }

    private func availableSources() -> [Source] {
        var out: [Source] = []
        // In .auto mode the LLM is the only source — it labels each title
        // with its own kind. TMDB and Library need a known kind to route
        // correctly, so they are skipped.
        let autoMode = mediaSelection == .auto
        if !autoMode {
            if tmdb != nil && !failedSources.contains(.tmdb) { out.append(.tmdb) }
            if library != nil && !failedSources.contains(.library) && !libraryDrained {
                out.append(.library)
            }
        }
        if llm != nil && !failedSources.contains(.llm) && !llmDormant
           && !moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.llm)
        }
        return out
    }

    private func drain(source: Source) async {
        do {
            let items: [DiscoverItem]
            switch source {
            case .tmdb:
                tmdbPage += 1
                items = try await tmdb!(filter, tmdbPage)
            case .library:
                items = try await library!(filter)
                libraryDrained = true
            case .llm:
                let result = try await llm!(llmShownTitles, moodText)
                items = result.items
                if items.isEmpty {
                    llmDormant = true
                    llmPoolExhausted = true
                } else {
                    llmShownTitles.append(contentsOf: items.map(titleYearKey))
                }
                if let suggested = result.suggestedFilters {
                    applySuggestedFilters(suggested, personIds: result.resolvedPersonIds)
                }
            }
            append(items)
        } catch {
            failedSources.insert(source)
            errorMessage = "Discover source failed: \(source) (\(error))"
        }
    }

    /// Apply LLM-suggested filters to the current filter without triggering
    /// userActionTick — so the View's task(id: userActionTick) does NOT fire
    /// a new reshuffle, breaking the potential infinite loop.
    private func applySuggestedFilters(_ s: DiscoverLLMPrompt.SuggestedFilters,
                                       personIds: [Int] = []) {
        var f = filter
        if !s.genres.isEmpty { f.genres = Set(s.genres) }
        if let d = s.decade { f.decade = d }
        if let st = s.status { f.status = st }
        if !personIds.isEmpty { f.personIds = personIds }
        filter = f
    }

    private func append(_ items: [DiscoverItem]) {
        for it in items {
            if seenKeys.insert(it.dedupKey).inserted {
                queue.append(it)
            }
        }
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
            for src in self.availableSources() {
                if self.queue.count >= self.topUpThreshold { break }
                await self.drain(source: src)
            }
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
