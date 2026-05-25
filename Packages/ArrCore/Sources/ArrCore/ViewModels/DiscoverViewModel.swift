import Foundation
import SwiftUI

/// View-layer DTO describing a suggested filter pill. The VM emits these
/// already-ordered and deduplicated against the active filter, so the View
/// just renders them in sequence.
public struct SuggestedFilter: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable {
        case people, genre, decade, rating, runtime, ai
    }
    public let id: String       // e.g. "person.Quentin Tarantino", "genre.action"
    public let label: String    // display label as-is
    public let category: Category
    public let icon: String?    // SF Symbol name; matches the in-picker icons
}

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
    private static let autoJumpEnabledKey = "ArrBarr.discoverAutoJumpEnabled"
    private static let customMoodsKey = "ArrBarr.discoverCustomMoods"
    private static let customPeopleKey = "ArrBarr.discoverCustomPeople"
    private static let customTagsByCategoryKey = "ArrBarr.discoverCustomTagsByCategory"
    private static let personNameCacheKey = "ArrBarr.discoverPersonNameCache"
    private static let moodUsageKey = "ArrBarr.discoverMoodUsage"
    private static let personUsageKey = "ArrBarr.discoverPersonUsage"

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
    /// Per-source item counts from the most recent fetch batch.
    /// Visible in the empty-stack state so the user can diagnose why
    /// no cards appeared, without needing the console.
    @Published public private(set) var lastFetchedCounts: [Source: Int] = [:]
    /// Per-source error message captured from the most recent fetch.
    /// Surfaces the actual failure reason (URL / status / decode error) in
    /// the empty-stack state — without this the user only sees "TMDB
    /// unavailable" with no clue why.
    @Published public private(set) var sourceErrors: [Source: String] = [:]
    /// tmdbId → fetched credits. Populated lazily when the view requests
    /// a card's credits via `fetchCreditsIfNeeded`. Used by the card's
    /// back face for cast headshots + director.
    @Published public private(set) var creditsCache: [Int: TMDBCredits] = [:]
    @Published public private(set) var llmPoolExhausted: Bool = false
    /// True when the last TMDB fetch returned > 0 raw server-side results
    /// but all were filtered out as already in-library.
    @Published public private(set) var tmdbAllInLibrary: Bool = false
    /// True when the last TMDB fetch returned 0 results from the server
    /// (filter combo returned nothing — not a network error).
    @Published public private(set) var tmdbReturnedEmpty: Bool = false
    @Published public private(set) var isLoading: Bool = false
    /// True while a background top-up fetch is in flight. View shows a
    /// spinner in the card slot when both `queue` and `current` are
    /// empty and this is true — keeps the user from staring at an
    /// empty rectangle between cards.
    @Published public private(set) var isTopUpRunning: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var matched: [DiscoverItem] = []
    /// Increments every time the matched list crosses a 10-pick boundary
    /// (10, 20, 30, …). View observes via .onChange to trigger an
    /// auto-jump to the picks list.
    @Published public private(set) var picksMilestoneTick: Int = 0
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

    /// When true, every 10th right-swipe bumps `picksMilestoneTick` so the
    /// view auto-jumps to the picks list. User-toggleable from the picks
    /// header — persists across sessions.
    @Published public var autoJumpEnabled: Bool {
        didSet {
            defaults.set(autoJumpEnabled, forKey: Self.autoJumpEnabledKey)
        }
    }

    /// User-added mood labels that appear as pills in the picker. Tapping
    /// one commits immediately as `moodText`. Persisted to UserDefaults so
    /// the user's library of moods builds up across sessions.
    @Published public private(set) var customMoods: [String] = []

    /// User-added celebrity names. Same UX as `customMoods` but resolves
    /// via TMDB on tap. Persisted under `customPeopleKey`.
    @Published public private(set) var customPeople: [String] = []

    /// User-added free-form labels per filter category (genre, decade,
    /// rating, runtime). Tapping any of these acts like a custom mood —
    /// the label flows into `moodText` and the LLM uses it as intent.
    /// Keyed by category raw value so the View can group them visually
    /// without the model knowing about UI categories. Persisted JSON.
    @Published public private(set) var customTagsByCategory: [String: [String]] = [:]

    /// Cache of name → TMDB person id resolutions. Populated lazily by
    /// `togglePerson(name:)` so we don't re-hit the TMDB search endpoint
    /// every time the user re-opens the picker. Persisted to defaults
    /// (small `[String: Int]` map serialized as JSON).
    @Published public private(set) var personNameCache: [String: Int] = [:]

    /// Names the user has clicked in the picker — drives the pill's
    /// "picked" visual *synchronously*. The actual `filter.personIds`
    /// only updates after TMDB resolves the name to an id; without
    /// this set the pill would stay grey during the round-trip (or
    /// forever if the resolve silently failed) and the user would
    /// conclude the tap did nothing.
    @Published public private(set) var selectedPersonNames: Set<String> = []

    /// Per-mood tap count. Used by the View to sort the MOOD row so the
    /// user's favourites bubble up. Persisted JSON.
    @Published public private(set) var moodUsageCount: [String: Int] = [:]

    /// Per-person tap count. Used by the View to sort the PEOPLE row so
    /// the user's favourites bubble up. Persisted JSON.
    @Published public private(set) var personUsageCount: [String: Int] = [:]

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
        // Default true — auto-jump is opt-out, not opt-in.
        if defaults.object(forKey: Self.autoJumpEnabledKey) == nil {
            self.autoJumpEnabled = true
        } else {
            self.autoJumpEnabled = defaults.bool(forKey: Self.autoJumpEnabledKey)
        }
        self.customMoods = defaults.stringArray(forKey: Self.customMoodsKey) ?? []
        self.customPeople = defaults.stringArray(forKey: Self.customPeopleKey) ?? []
        if let data = defaults.data(forKey: Self.personNameCacheKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.personNameCache = decoded
        }
        if let data = defaults.data(forKey: Self.moodUsageKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.moodUsageCount = decoded
        }
        if let data = defaults.data(forKey: Self.personUsageKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.personUsageCount = decoded
        }
        if let data = defaults.data(forKey: Self.customTagsByCategoryKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.customTagsByCategory = decoded
        }
    }

    // MARK: - Custom per-category tags

    public func addCustomTag(category: String, label raw: String) {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        var current = customTagsByCategory[category] ?? []
        let lowered = label.lowercased()
        guard !current.contains(where: { $0.lowercased() == lowered }) else { return }
        current.append(label)
        customTagsByCategory[category] = current
        persistCustomTags()
    }

    public func removeCustomTag(category: String, label: String) {
        var current = customTagsByCategory[category] ?? []
        current.removeAll { $0 == label }
        if current.isEmpty {
            customTagsByCategory.removeValue(forKey: category)
        } else {
            customTagsByCategory[category] = current
        }
        persistCustomTags()
    }

    private func persistCustomTags() {
        if let data = try? JSONEncoder().encode(customTagsByCategory) {
            defaults.set(data, forKey: Self.customTagsByCategoryKey)
        }
    }

    // MARK: - Custom moods

    /// Append a new custom mood pill. Trims and dedupes (case-insensitive)
    /// so the user can't fill the cloud with near-duplicates. No-op on
    /// empty input.
    public func addCustomMood(_ raw: String) {
        let mood = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mood.isEmpty else { return }
        let lowered = mood.lowercased()
        guard !customMoods.contains(where: { $0.lowercased() == lowered }) else { return }
        customMoods.append(mood)
        defaults.set(customMoods, forKey: Self.customMoodsKey)
    }

    public func removeCustomMood(_ mood: String) {
        customMoods.removeAll { $0 == mood }
        defaults.set(customMoods, forKey: Self.customMoodsKey)
    }

    public func bumpMoodUsage(_ mood: String) {
        moodUsageCount[mood, default: 0] += 1
        if let data = try? JSONEncoder().encode(moodUsageCount) {
            defaults.set(data, forKey: Self.moodUsageKey)
        }
    }

    // MARK: - Custom people

    public func addCustomPerson(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let lowered = name.lowercased()
        guard !customPeople.contains(where: { $0.lowercased() == lowered }) else { return }
        customPeople.append(name)
        defaults.set(customPeople, forKey: Self.customPeopleKey)
    }

    public func removeCustomPerson(_ name: String) {
        customPeople.removeAll { $0 == name }
        defaults.set(customPeople, forKey: Self.customPeopleKey)
    }

    public func bumpPersonUsage(_ name: String) {
        personUsageCount[name, default: 0] += 1
        if let data = try? JSONEncoder().encode(personUsageCount) {
            defaults.set(data, forKey: Self.personUsageKey)
        }
    }

    // MARK: - Suggested filters

    /// Up to 10 pills the View renders in the Suggestions row. Top 8 are the
    /// user's most-used catalog items (across all categories); the remaining
    /// up-to-2 slots are filled with curated discovery defaults that the user
    /// has *never* used, so a brand-new picker still shows a useful row. Active
    /// filters (already chips in the composer) are excluded — the row never
    /// duplicates what's already selected.
    public var suggestedFilters: [SuggestedFilter] {
        let pool = Self.curatedPool(mediaSelection: mediaSelection)
        let active = activeFilterIds()
        let usage = combinedUsage()
        let candidates = pool.filter { !active.contains($0.id) }
        let used = candidates
            .filter { (usage[$0.id] ?? 0) > 0 }
            .sorted { (usage[$0.id] ?? 0) > (usage[$1.id] ?? 0) }
        let unused = candidates.filter { (usage[$0.id] ?? 0) == 0 }
        let topUsed = Array(used.prefix(8))
        let discoveryCount = max(0, 10 - topUsed.count)
        let discovery = Array(unused.prefix(discoveryCount))
        return topUsed + discovery
    }

    /// Suggestions grouped by category for the per-category mini-row layout.
    /// AI bucket holds starter prompts as pseudo-filters — their `label` is
    /// the prompt text the View should drop into `moodText`. Omitted when
    /// `llmAvailable` is false. Caller iterates a fixed display order.
    public func suggestionsByCategory(llmAvailable: Bool)
        -> [SuggestedFilter.Category: [SuggestedFilter]] {
        var out: [SuggestedFilter.Category: [SuggestedFilter]] = [:]
        // Distribute filter suggestions by their category. Cap each bucket
        // at 3 so a single category doesn't dominate the strip.
        for s in suggestedFilters where s.category != .ai {
            var bucket = out[s.category] ?? []
            if bucket.count < 3 { bucket.append(s) }
            out[s.category] = bucket
        }
        if llmAvailable {
            out[.ai] = Self.aiStarterPrompts
        }
        return out
    }

    /// Curated starter prompts surfaced as the AI suggestion row. Kept
    /// short so the row stays visually balanced; the LLM doesn't need many
    /// examples to convey "you can write naturally here".
    private static let aiStarterPrompts: [SuggestedFilter] = [
        .init(id: "ai.cozy", label: "Cozy Sunday afternoon",
              category: .ai, icon: "sparkles"),
        .init(id: "ai.flight", label: "Long flight",
              category: .ai, icon: "sparkles"),
        .init(id: "ai.date", label: "Date night",
              category: .ai, icon: "sparkles"),
    ]

    /// Curated default catalog. Order doubles as the cold-start sort —
    /// when no usage data exists, the View shows the first 10 entries.
    /// Length pills are dropped for `.show` (Sonarr has no runtime filter).
    private static func curatedPool(mediaSelection: DiscoverMediaSelection) -> [SuggestedFilter] {
        var pool: [SuggestedFilter] = [
            .init(id: "person.Quentin Tarantino", label: "Quentin Tarantino",
                  category: .people, icon: "person.fill"),
            .init(id: "person.Christopher Nolan", label: "Christopher Nolan",
                  category: .people, icon: "person.fill"),
            .init(id: "person.Adam Sandler", label: "Adam Sandler",
                  category: .people, icon: "person.fill"),
            .init(id: "person.Leonardo DiCaprio", label: "Leonardo DiCaprio",
                  category: .people, icon: "person.fill"),
            .init(id: "genre.\(DiscoverGenre.comedy.rawValue)", label: "Comedy",
                  category: .genre, icon: "face.smiling"),
            .init(id: "genre.\(DiscoverGenre.drama.rawValue)", label: "Drama",
                  category: .genre, icon: "theatermasks"),
            .init(id: "genre.\(DiscoverGenre.horror.rawValue)", label: "Horror",
                  category: .genre, icon: "drop"),
            .init(id: "genre.\(DiscoverGenre.scienceFiction.rawValue)", label: "Sci-Fi",
                  category: .genre, icon: "atom"),
            .init(id: "decade.\(DiscoverDecade.nineties.rawValue)", label: "1990s",
                  category: .decade, icon: "calendar"),
            .init(id: "decade.\(DiscoverDecade.twoThousands.rawValue)", label: "2000s",
                  category: .decade, icon: "calendar"),
            .init(id: "rating.\(DiscoverRatingTier.highlyRated.rawValue)", label: "Highly rated",
                  category: .rating, icon: "star.fill"),
        ]
        if mediaSelection != .show {
            pool.append(.init(id: "runtime.\(DiscoverRuntime.short.rawValue)",
                              label: "Short", category: .runtime, icon: "hare"))
        }
        return pool
    }

    /// IDs currently active in `filter` / `selectedPersonNames`, used to
    /// deduplicate the Suggestions row against the composer chips.
    private func activeFilterIds() -> Set<String> {
        var out: Set<String> = []
        for name in selectedPersonNames { out.insert("person.\(name)") }
        for g in filter.genres { out.insert("genre.\(g.rawValue)") }
        if filter.decade != .any { out.insert("decade.\(filter.decade.rawValue)") }
        if filter.rating != .any { out.insert("rating.\(filter.rating.rawValue)") }
        if filter.runtime != .any { out.insert("runtime.\(filter.runtime.rawValue)") }
        return out
    }

    /// Merge person + mood usage maps into a single id-keyed lookup so the
    /// suggestions sort can compare across categories.
    private func combinedUsage() -> [String: Int] {
        var u: [String: Int] = [:]
        for (name, count) in personUsageCount {
            u["person.\(name)"] = count
        }
        for (label, count) in moodUsageCount {
            u["mood.\(label)"] = count
        }
        return u
    }

    // MARK: - Person filter helpers

    /// Resolve a celebrity name to a TMDB person id and toggle it in
    /// `filter.personIds`. Visual state in `selectedPersonNames` flips
    /// *first* (synchronously) so the pill lights up the instant the
    /// user taps; the actual TMDB resolve happens afterwards. If
    /// resolution fails (no key, network, no hit) we roll the visual
    /// state back so the user sees the pill drop instead of getting a
    /// false positive.
    public func togglePerson(name: String) async {
        let nowSelected = !selectedPersonNames.contains(name)
        if nowSelected {
            selectedPersonNames.insert(name)
        } else {
            selectedPersonNames.remove(name)
        }
        // Cached path — id already known, just update the filter.
        if let cached = personNameCache[name] {
            applyPersonIdSelection(cached, selected: nowSelected)
            return
        }
        // Cold path — must resolve via TMDB before we can mutate the
        // filter. No key or no hit ⇒ undo the visual selection.
        guard !tmdbApiKey.isEmpty else {
            if nowSelected { selectedPersonNames.remove(name) }
            return
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        guard let hit = (try? await client.searchPerson(query: name))?.first else {
            if nowSelected { selectedPersonNames.remove(name) }
            return
        }
        personNameCache[name] = hit.id
        if let data = try? JSONEncoder().encode(personNameCache) {
            defaults.set(data, forKey: Self.personNameCacheKey)
        }
        // Use the freshly resolved selection state — `selectedPersonNames`
        // may have flipped again during the in-flight resolve.
        let currentlySelected = selectedPersonNames.contains(name)
        applyPersonIdSelection(hit.id, selected: currentlySelected)
    }

    /// True when the user has tapped this name in the picker. Drives the
    /// pill's colored "picked" state regardless of whether the TMDB
    /// resolve has finished yet — visual feedback should be instant.
    public func isPersonSelected(name: String) -> Bool {
        selectedPersonNames.contains(name)
    }

    /// Reconciles `filter.personIds` with an explicit selected/deselected
    /// state for an id — used by the (possibly delayed) TMDB resolve
    /// path, since `selectedPersonNames` may have flipped while the
    /// network call was in flight.
    private func applyPersonIdSelection(_ id: Int, selected: Bool) {
        if selected {
            if !filter.personIds.contains(id) { filter.personIds.append(id) }
        } else {
            filter.personIds.removeAll { $0 == id }
        }
        userChangedFilter()
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

    /// Right swipe inserts the current card at index 0 of `matched` (newest
    /// first) and fires a milestone tick every 10 picks. Left swipe discards.
    /// Either way the next card advances and a top-up may fire.
    public func swipe(right: Bool) async {
        startSwipe(right: right)
        finishSwipe()
    }

    /// First half of a swipe — records the outcome (matched insert,
    /// milestone tick) and kicks off a top-up fetch if the queue is
    /// running low, but DOES NOT clear `current` or advance. The View
    /// calls this at the *start* of the fly-off animation so the async
    /// fetch overlaps with the visual transition. `current` stays as
    /// the still-flying card; the next card waits in the peek stack.
    public func startSwipe(right: Bool) {
        guard let item = current else { return }
        if right {
            matched.insert(item, at: 0)
            if autoJumpEnabled, matched.count > 0, matched.count % 10 == 0 {
                picksMilestoneTick &+= 1
            }
        }
        // `-1` accounts for the card we're about to consume — without it
        // we'd kick off the top-up one swipe too late.
        if queue.count - 1 < topUpThreshold {
            scheduleTopUp()
        }
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
                lastFetchedCounts[.llm] = result.items.count
                return result.items
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
        isTopUpRunning = true
        topUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.topUpTask = nil
                self.isTopUpRunning = false
            }
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
        tmdbAllInLibrary = false
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
        topUpTask?.cancel()
        topUpTask = nil
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
