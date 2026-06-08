import Foundation
import SwiftUI

@MainActor
@Observable
public final class DiscoverViewModel {

    public enum Source: Hashable, CaseIterable, Sendable {
        case tmdb, library, llm
    }

    // MARK: - Persistence keys

    private static let hasPickedKindKey = "ArrBarr.discoverHasPickedKind"

    // MARK: - Published state

    public var hasPickedKind: Bool {
        didSet {
            defaults.set(hasPickedKind, forKey: Self.hasPickedKindKey)
        }
    }
    public private(set) var current: DiscoverItem?
    public private(set) var queue: [DiscoverItem] = []
    public var filter = DiscoverFilter()
    public var moodText: String = ""
    public private(set) var failedSources: Set<Source> = []
    /// Per-source item counts from the most recent fetch batch.
    /// Visible in the empty-stack state so the user can diagnose why
    /// no cards appeared, without needing the console.
    public private(set) var lastFetchedCounts: [Source: Int] = [:]
    /// Per-source error message captured from the most recent fetch.
    /// Surfaces the actual failure reason (URL / status / decode error) in
    /// the empty-stack state — without this the user only sees "TMDB
    /// unavailable" with no clue why.
    public private(set) var sourceErrors: [Source: String] = [:]
    /// tmdbId → fetched credits. Populated lazily when the view requests
    /// a card's credits via `fetchCreditsIfNeeded`. Used by the card's
    /// back face for cast headshots + director.
    public private(set) var creditsCache: [Int: TMDBCredits] = [:]
    public private(set) var llmPoolExhausted: Bool = false
    /// True when the last TMDB fetch returned 0 results from the server
    /// (filter combo returned nothing — not a network error).
    public private(set) var tmdbReturnedEmpty: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var matched: [DiscoverItem] = []
    /// Cards the user swiped right in the current session (since the
    /// last `seed(items:mood:)`). Cleared when a new session starts so
    /// the "more picks" feedback only carries fresh signal.
    public private(set) var sessionMatched: [DiscoverItem] = []
    /// Cards the user swiped left in the current session.
    public private(set) var sessionSkipped: [DiscoverItem] = []
    /// Cards the user explicitly marked "fewer like this" — stronger
    /// negative signal than a regular left-swipe. Cleared when a new
    /// session starts.
    public private(set) var sessionDisliked: [DiscoverItem] = []
    /// Total number of picks the agent seeded for the current session.
    /// Set by `seed(items:mood:)` and used by the View to render the
    /// "N / total" progress chip. Doesn't shrink as the user swipes —
    /// progress is derived as `total - (queue.count + (current == nil ? 0 : 1))`.
    public private(set) var sessionTotal: Int = 0
    /// True when the user has matched new picks since they last viewed
    /// the picks list inside the overlay. Drives the picks icon's pulse.
    /// Set to true on every right-swipe; cleared when the user opens
    /// the matched view.
    public private(set) var hasUnseenPicks: Bool = false
    /// Incremented only by user-driven actions (mood submit, filter chip
    /// taps, explicit reshuffle). The View's `task(id:)` keys on this so
    /// LLM-applied filter changes don't trigger an infinite reshuffle loop.
    public private(set) var userActionTick: Int = 0
    /// Media kind the user selected in the picker segmented control.
    /// Persisted to UserDefaults so the choice survives app restarts.
    private static let mediaSelectionKey = "ArrBarr.discoverMediaSelection"
    private let defaults: UserDefaults

    public var mediaSelection: DiscoverMediaSelection {
        didSet {
            defaults.set(mediaSelection.rawValue, forKey: Self.mediaSelectionKey)
        }
    }

    // MARK: - Source closures

    public typealias TMDBSource = @MainActor (DiscoverFilter, Int) async throws -> [DiscoverItem]
    public typealias LibrarySource = @MainActor (DiscoverFilter) async throws -> [DiscoverItem]
    public typealias LLMSource = @MainActor ([String], String) async throws -> [DiscoverItem]

    private var tmdb: TMDBSource?
    private var library: LibrarySource?
    private var llm: LLMSource?

    // MARK: - Internals

    private var seenKeys = Set<String>()
    private var llmShownTitles: [String] = []
    private var tmdbPage = 0
    private var libraryDrained = false
    private var llmDormant = false
    private var creditsFetchingIds = Set<Int>()
    private var tmdbApiKey: String = ""

    /// Process-wide shared instance. Used by views that can't easily
    /// reach the popover-owned `@StateObject` (e.g. `QuizResumeCard`
    /// rendered deep inside a chat message bubble where environment
    /// objects don't always propagate reliably). PopoverContentView
    /// uses the same `.shared` instance so the state stays unified.
    public static let shared = DiscoverViewModel()

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

    /// Replace the deck with a pre-resolved set of picks (typically from
    /// a chat tool that has the titles in hand). Skips the fetch pipeline
    /// entirely — the seeded deck IS the session. When the user wants
    /// more, they ask explicitly (Q2 chat round-trip).
    public func seed(items: [DiscoverItem], mood: String) {
        sessionMatched.removeAll()
        sessionSkipped.removeAll()
        sessionDisliked.removeAll()
        reset()
        moodText = mood
        sessionTotal = items.count
        for item in items {
            if seenKeys.insert(item.dedupKey).inserted {
                queue.append(item)
            }
        }
        advanceIfNeeded()
    }

    /// Append more picks to the active session without resetting state.
    /// Used by the "more picks" flow — the user keeps their current card,
    /// matched/skipped feedback survives, and the new items merge into
    /// the deck (deduped against what they've already seen).
    public func extend(items: [DiscoverItem]) {
        var added = 0
        for item in items {
            if seenKeys.insert(item.dedupKey).inserted {
                queue.append(item)
                added += 1
            }
        }
        sessionTotal += added
        advanceIfNeeded()
    }

    /// Right swipe inserts the current card at index 0 of `matched` (newest
    /// first) and sets hasUnseenPicks. Left swipe discards.
    /// Either way the next card advances and a top-up may fire.
    public func swipe(right: Bool) async {
        startSwipe(right: right)
        finishSwipe()
    }

    /// First half of a swipe — records the outcome (matched insert,
    /// hasUnseenPicks set) but DOES NOT clear `current` or advance. The View
    /// calls this at the *start* of the fly-off animation. `current`
    /// stays as the still-flying card; the next card waits in the peek
    /// stack.
    public func startSwipe(right: Bool) {
        guard let item = current else { return }
        if right {
            matched.insert(item, at: 0)
            sessionMatched.append(item)
            hasUnseenPicks = true
        } else {
            sessionSkipped.append(item)
        }
    }

    /// Mark the current card as "fewer like this" and advance. Acts
    /// like a left-swipe (item drops out of the deck, doesn't enter
    /// matched), but is tagged separately so the "More picks" feedback
    /// loop can emphasise avoiding similar items.
    public func markDisliked() {
        guard let item = current else { return }
        sessionDisliked.append(item)
        sessionSkipped.append(item)   // also counts as skipped — same drop semantics
        current = nil
        advanceIfNeeded()
    }

    /// True when the user has actually engaged with the deck this session.
    /// Used by the overlay to decide whether to surface "more picks like
    /// these" — without engagement the button has no signal to feed back.
    public var hasSessionEngagement: Bool {
        !sessionMatched.isEmpty || !sessionSkipped.isEmpty
    }

    /// Number of cards the user has already moved past (swiped or
    /// committed) in the current session. Combined with `sessionTotal`
    /// this drives the "N / total" chip.
    public var sessionConsumed: Int {
        let remaining = queue.count + (current == nil ? 0 : 1)
        return max(0, sessionTotal - remaining)
    }

    /// Called by the View when the user opens the matched picks list.
    /// Clears the unseen-picks signal so the icon stops pulsing.
    public func acknowledgeUnseenPicks() {
        hasUnseenPicks = false
    }

    /// Second half of a swipe — actually clears `current` and pulls the
    /// next card off the queue. The View calls this after the fly-off
    /// animation finishes so the swap is invisible to the user.
    public func finishSwipe() {
        current = nil
        advanceIfNeeded()
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
                let items = try await tmdb!(filter, tmdbPage)
                tmdbReturnedEmpty = items.isEmpty
                lastFetchedCounts[.tmdb] = items.count
                return items
            case .library:
                let items = try await library!(filter)
                libraryDrained = true
                lastFetchedCounts[.library] = items.count
                return items
            case .llm:
                let items = try await llm!(llmShownTitles, moodText)
                if items.isEmpty {
                    llmDormant = true
                    llmPoolExhausted = true
                } else {
                    llmShownTitles.append(contentsOf: items.map(titleYearKey))
                }
                lastFetchedCounts[.llm] = items.count
                return items
            }
        } catch {
            failedSources.insert(source)
            // Record both a per-source error (for inline display) and the
            // generic global one. Also surface a zero count so the user sees
            // the source listed in the counts strip rather than missing
            // entirely.
            lastFetchedCounts[source] = 0
            sourceErrors[source] = String(describing: error)
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

    private func advanceIfNeeded() {
        if current == nil, !queue.isEmpty {
            current = queue.removeFirst()
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
        tmdbReturnedEmpty = false
        failedSources.removeAll()
        errorMessage = nil
        // `matched` deliberately NOT cleared — the picks list is sticky
        // across mood changes. The user explicitly clears it via the
        // "Clear picks" button on the Your Picks header. Re-seed
        // `seenKeys` with what they've already picked so the next
        // fetch doesn't surface the same titles again.
        for item in matched { seenKeys.insert(item.dedupKey) }
        lastFetchedCounts.removeAll()
        sourceErrors.removeAll()
        creditsCache.removeAll()
        creditsFetchingIds.removeAll()
        // Note: mediaSelection is intentionally NOT reset here — it's a
        // user-level preference that persists across reshuffles.
    }

    /// Explicit "wipe my picks" — invoked from the Your Picks header.
    /// Separate from `reset()` because picks should survive every
    /// reshuffle / mood change unless the user actively asks for a
    /// fresh start.
    public func clearMatched() {
        matched.removeAll()
    }

    private func titleYearKey(_ item: DiscoverItem) -> String {
        let year = item.result.year.map(String.init) ?? ""
        return year.isEmpty ? item.result.title : "\(item.result.title) (\(year))"
    }
}
