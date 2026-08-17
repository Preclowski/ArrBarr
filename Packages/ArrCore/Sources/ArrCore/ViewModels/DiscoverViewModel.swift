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
    /// Held for the view model's lifetime — the observer must outlive every
    /// deck the user opens, and the view model itself lives as long as the
    /// Quiz does, so there is nothing to unregister early.
    private var addObserver: (any NSObjectProtocol)?
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
    public private(set) var llmPoolExhausted: Bool = false
    /// True when the last TMDB fetch returned 0 results from the server
    /// (filter combo returned nothing — not a network error).
    public private(set) var tmdbReturnedEmpty: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    /// Cards the user swiped right (chose to add) in the current session
    /// (since the last `seed(items:mood:)`). Cleared when a new session
    /// starts so the "more picks" feedback only carries fresh signal; also
    /// drives `QuizResumeCard`'s count.
    public private(set) var sessionMatched: [DiscoverItem] = []
    /// Cards the user skipped (>>) in the current session.
    public private(set) var sessionSkipped: [DiscoverItem] = []
    /// Total number of picks the agent seeded for the current session.
    /// Set by `seed(items:mood:)` and used by the View to render the
    /// "N / total" progress chip. Doesn't shrink as the user swipes —
    /// progress is derived as `total - (queue.count + (current == nil ? 0 : 1))`.
    public private(set) var sessionTotal: Int = 0
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
        // Observed HERE rather than in the view: the deck is hidden while the
        // add panel is up, so a view-level listener would be torn down exactly
        // when the "added" signal arrives.
        addObserver = NotificationCenter.default.addObserver(
            forName: .arrBarrDidAddToLibrary, object: nil, queue: .main
        ) { [weak self] note in
            guard let foreignId = note.userInfo?["foreignId"] as? String else { return }
            Task { @MainActor in self?.didAddToLibrary(foreignId: foreignId) }
        }
    }

    /// The user finished adding the card they were on — drop it and move to the
    /// next. Not `skip()`: this title was a *pick* (already recorded by
    /// `markPicked`), and recording it as skipped too would poison the signal
    /// the top-up round feeds on.
    public func didAddToLibrary(foreignId: String) {
        guard let item = current, item.result.foreignId == foreignId else { return }
        current = nil
        advanceIfNeeded()
    }

    public func configure(tmdb: TMDBSource?, library: LibrarySource?, llm: LLMSource?) {
        self.tmdb = tmdb
        self.library = library
        self.llm = llm
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

    /// Every card this session has already put in front of the user — still
    /// in the deck, current, or long since swiped. The `discover_in_quiz`
    /// tool reads this before an appended round lands so a top-up can't come
    /// back full of titles `extend` would silently drop (which reads to the
    /// user as "no more cards" while a manual retry still finds picks).
    public var shownDedupKeys: Set<String> { seenKeys }

    /// Skip the current card (>>) — records it as skipped for the
    /// engagement signal and advances to the next. This is the only action
    /// that advances the deck.
    public func skip() {
        if let item = current {
            sessionSkipped.append(item)
            // Persist the verdict: a skip is a cooldown, not a session-local
            // fact — without this the very next deck deals the same card.
            SwipeSignalStore.shared.record(key: item.dedupKey,
                                           title: item.result.title,
                                           kind: .skipped)
        }
        current = nil
        advanceIfNeeded()
    }

    /// Record that the user chose to add the current card (a "pick", drives
    /// `QuizResumeCard`'s count). Deliberately does NOT advance — opening the
    /// add card leaves the user on the same title so a cancelled add returns
    /// to it. Deduped so opening the add card twice on one title counts once.
    public func markPicked() {
        guard let item = current,
              !sessionMatched.contains(where: { $0.dedupKey == item.dedupKey }) else { return }
        sessionMatched.append(item)
        // Positive signal outlives the session — and clears any stale skip,
        // so a kept title can't stay suppressed by last month's mood.
        SwipeSignalStore.shared.record(key: item.dedupKey,
                                       title: item.result.title,
                                       kind: .kept)
    }

    /// Explicit "not interested": the only PERMANENT negative — a plain skip
    /// is just a cooldown. Still lands on the undo stack, so a slip of the
    /// finger is reversible (undo withdraws the veto signal too).
    public func veto() {
        guard let item = current else { return }
        sessionSkipped.append(item)
        SwipeSignalStore.shared.record(key: item.dedupKey,
                                       title: item.result.title,
                                       kind: .veto)
        current = nil
        advanceIfNeeded()
    }

    /// Undo the most recent skip: the last skipped card becomes current again
    /// and the one on screen slides back into the queue's front. Clicking
    /// repeatedly walks further back through this session's skips. Also
    /// withdraws the persisted skip signal — an undone skip was a mis-swipe,
    /// not a verdict, and must not cool the title down for two weeks.
    public func undoSkip() {
        guard let last = sessionSkipped.popLast() else { return }
        SwipeSignalStore.shared.remove(key: last.dedupKey)
        if let onScreen = current {
            queue.insert(onScreen, at: 0)
        }
        current = last
    }

    /// Whether there is a skip to undo — drives the deck's back button.
    public var canUndoSkip: Bool { !sessionSkipped.isEmpty }

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
        lastFetchedCounts.removeAll()
        sourceErrors.removeAll()
        // Note: mediaSelection is intentionally NOT reset here — it's a
        // user-level preference that persists across reshuffles.
    }

    private func titleYearKey(_ item: DiscoverItem) -> String {
        let year = item.result.year.map(String.init) ?? ""
        return year.isEmpty ? item.result.title : "\(item.result.title) (\(year))"
    }
}
