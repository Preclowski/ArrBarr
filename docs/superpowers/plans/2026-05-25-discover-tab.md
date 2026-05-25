# Discover Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Tinder-style "Discover" tab to ArrBarr's popover that surfaces movie suggestions from TMDB Discover, the user's Radarr library, and (optionally) an LLM mood query — blended via VM-level round-robin with per-source swipe actions.

**Architecture:** Three independent async source functions live on `DiscoverViewModel`. The VM round-robins them into a queue, dedupes by `id`, and tops up when the queue runs low. Cards reuse `SearchResult` wrapped in a thin `DiscoverItem`. Card body reuses `MediaHeaderCard` + `RemotePoster`. LLM uses a stateless call with an `exclude` array — no multi-turn conversation premise.

**Tech Stack:** Swift / SwiftUI, existing `TMDBClient`, `RadarrClient`, `LLMProvider`, `SearchClient`, `MediaHeaderCard`, `RemotePoster`. Tests in `Packages/ArrCore/Tests/ArrCoreTests/`.

**Spec:** `docs/superpowers/specs/2026-05-25-discover-tab-design.md`

---

## File Map

**Create:**
- `Packages/ArrCore/Sources/ArrCore/Models/DiscoverItem.swift` — `DiscoverItem` + `DiscoverAction` + `DiscoverFilter`
- `Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift` — pure prompt builder + JSON parser
- `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverFilterBar.swift`
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverCardView.swift` — thin composition over `MediaHeaderCard` + action row
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverItemTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

**Modify:**
- `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` — add `.discover` to `Tab` enum, wire `DiscoverViewModel`, branch in `selectedTab` switch
- `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` (or wherever loc strings live — read it before editing) — add new keys

---

## Task 1: Orientation + Discover tab scaffold (empty view)

**Why first:** lock in the wiring point before any sources exist; a visible empty tab proves PopoverContentView integration works.

**Files:**
- Read: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` (find how `tmdbApiKey`, `radarr`, `openai` configs are accessed and the `radarrClient`/equivalent factory pattern if any)
- Read: `Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift` (study the VM lifecycle pattern — `setup(...)` injection, `@Published` arrays, source-per-arr fanout)
- Read: `Packages/ArrCore/Sources/ArrCore/Views/MediaHeaderCard.swift` and `Views/RemotePoster.swift` (so card composition in Task 9 reuses them faithfully)
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`

- [ ] **Step 1: Read orientation files**

Read the four files listed above. Note the exact ConfigStore property names you'll need later — at minimum: how to get the Radarr `ServiceConfig`, how to get the TMDB API key, how to detect LLM availability, and how the radarr/sonarr clients are constructed in `SearchViewModel.setup`.

- [ ] **Step 2: Add `.discover` case to the `Tab` enum**

In `PopoverContentView.swift` around line 103:

```swift
enum Tab: String, CaseIterable {
    case queue = "Queue"
    case upcoming = "Upcoming"
    case chat = "Chat"
    case discover = "Discover"
}
```

- [ ] **Step 3: Add a `discoverAvailable` gate matching `chatAvailable`'s style**

Right after `chatAvailable` (around line 83) add:

```swift
/// Discover needs at least Radarr (the library source + add-to-radarr
/// action both require it). TMDB-only / LLM-only modes are gated
/// inside the VM, not here.
private var discoverAvailable: Bool { radarrConfigured }
```

And include it in `visibleTabs`:

```swift
private var visibleTabs: [Tab] {
    Tab.allCases.filter { tab in
        switch tab {
        case .chat: return chatAvailable
        case .discover: return discoverAvailable
        default:    return true
        }
    }
}
```

- [ ] **Step 4: Add an empty `DiscoverTabView` stub**

Create `Views/DiscoverTabView.swift`:

```swift
import SwiftUI

public struct DiscoverTabView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text("Discover", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Branch on `.discover` in the tab switch**

In `PopoverContentView.swift`, find the `switch selectedTab` block (~line 207) and add the discover branch:

```swift
switch selectedTab {
case .queue: queueContent
case .upcoming: upcomingContent
case .chat:
    chatTabContent
case .discover:
    DiscoverTabView()
}
```

- [ ] **Step 6: Build, kill, relaunch and visually verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Expected: the popover shows a "Discover" tab; clicking it lands on the empty stub view.

- [ ] **Step 7: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift
git commit -m "feat(discover): scaffold tab and empty view"
```

---

## Task 2: `DiscoverItem` + `DiscoverFilter` models with tests

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/DiscoverItem.swift`
- Create: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverItemTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiscoverItemTests.swift`:

```swift
import XCTest
@testable import ArrCore

final class DiscoverItemTests: XCTestCase {
    private func mockSearchResult(id: Int = 42, title: String = "Drive",
                                  year: Int? = 2011) -> SearchResult {
        SearchResult(
            id: id, foreignId: String(id), title: title, subtitle: nil,
            year: year, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: "drive overview", runtime: 100,
            genres: ["Crime"], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
    }

    func test_dedupKey_usesTmdbIdFromForeignId() {
        let item = DiscoverItem(result: mockSearchResult(id: 42), action: .addToRadarr)
        XCTAssertEqual(item.dedupKey, "tmdb:42")
    }

    func test_dedupKey_fallsBackToTitleYearWhenNoForeignId() {
        let result = SearchResult(
            id: 0, foreignId: "", title: "Untitled", subtitle: nil,
            year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr, inLibraryArrId: nil
        )
        let item = DiscoverItem(result: result, action: .addToRadarr)
        XCTAssertEqual(item.dedupKey, "title:untitled|1999")
    }

    func test_filter_passesItem_whenNoConstraints() {
        let filter = DiscoverFilter()
        XCTAssertTrue(filter.matches(year: 2011, monitored: false))
    }

    func test_filter_passesItem_inDecadeRange() {
        let filter = DiscoverFilter(decade: .twoThousandTens)
        XCTAssertTrue(filter.matches(year: 2011, monitored: false))
        XCTAssertFalse(filter.matches(year: 1995, monitored: false))
        XCTAssertFalse(filter.matches(year: nil, monitored: false))
    }

    func test_filter_monitoredOnly_excludesUnmonitored() {
        let filter = DiscoverFilter(monitoredOnly: true)
        XCTAssertTrue(filter.matches(year: 2011, monitored: true))
        XCTAssertFalse(filter.matches(year: 2011, monitored: false))
        XCTAssertFalse(filter.matches(year: 2011, monitored: nil))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Packages/ArrCore && swift test --filter DiscoverItemTests
```

Expected: build fails — `DiscoverItem` and `DiscoverFilter` are undefined.

- [ ] **Step 3: Implement the models**

Create `Models/DiscoverItem.swift`:

```swift
import Foundation

public enum DiscoverAction: Equatable, Sendable {
    /// Card represents a movie not in Radarr. Swipe-right opens the
    /// existing SearchAddPanel overlay.
    case addToRadarr
    /// Card represents a movie already in Radarr. Swipe-right opens
    /// DetailView via the existing DetailRequest pipeline.
    case openDetail(arrId: Int)
}

public struct DiscoverItem: Identifiable, Equatable, Sendable {
    public let result: SearchResult
    public let action: DiscoverAction
    /// Source label for the bottom-of-card chip ("From TMDB" / "From your
    /// library" / "From AI").
    public let originLabel: Origin

    public enum Origin: String, Sendable {
        case tmdb, library, llm
    }

    public var id: String { dedupKey }

    /// Stable identity across sources. Prefer the TMDB id (foreignId)
    /// when present so a TMDB-source card and an LLM-source card for the
    /// same movie collide.
    public var dedupKey: String {
        if !result.foreignId.isEmpty {
            return "tmdb:\(result.foreignId)"
        }
        let title = result.title.lowercased()
        let year = result.year.map(String.init) ?? "?"
        return "title:\(title)|\(year)"
    }

    public init(result: SearchResult, action: DiscoverAction, originLabel: Origin = .tmdb) {
        self.result = result
        self.action = action
        self.originLabel = originLabel
    }
}

public enum DiscoverDecade: String, CaseIterable, Identifiable, Sendable {
    case any        = "Any"
    case eighties   = "1980s"
    case nineties   = "1990s"
    case twoThousands = "2000s"
    case twoThousandTens = "2010s"
    case twoThousandTwenties = "2020s"
    public var id: String { rawValue }
    /// `nil` for `.any`, otherwise the inclusive [start, end] decade range.
    public var range: ClosedRange<Int>? {
        switch self {
        case .any: return nil
        case .eighties: return 1980...1989
        case .nineties: return 1990...1999
        case .twoThousands: return 2000...2009
        case .twoThousandTens: return 2010...2019
        case .twoThousandTwenties: return 2020...2029
        }
    }
}

public struct DiscoverFilter: Equatable, Sendable {
    public var decade: DiscoverDecade
    public var monitoredOnly: Bool
    public init(decade: DiscoverDecade = .any, monitoredOnly: Bool = false) {
        self.decade = decade
        self.monitoredOnly = monitoredOnly
    }
    public func matches(year: Int?, monitored: Bool?) -> Bool {
        if let range = decade.range {
            guard let y = year, range.contains(y) else { return false }
        }
        if monitoredOnly {
            guard monitored == true else { return false }
        }
        return true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd Packages/ArrCore && swift test --filter DiscoverItemTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/DiscoverItem.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverItemTests.swift
git commit -m "feat(discover): DiscoverItem, DiscoverFilter, DiscoverDecade models"
```

---

## Task 3: LLM prompt builder + JSON parser (pure, testable)

**Why a separate file:** the prompt + parsing are the riskiest LLM logic. Isolating them as pure functions lets us test them without any provider.

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift`
- Create: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ArrCore

final class DiscoverLLMPromptTests: XCTestCase {
    func test_buildPrompt_includesMoodAndAskedCount() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "short 90s comedy",
            decade: .nineties,
            count: 20,
            exclude: []
        )
        XCTAssertTrue(prompt.contains("short 90s comedy"))
        XCTAssertTrue(prompt.contains("20"))
        XCTAssertTrue(prompt.contains("1990"))
    }

    func test_buildPrompt_listsExcludesWhenPresent() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "noir",
            decade: .any,
            count: 20,
            exclude: ["Drive (2011)", "Heat (1995)"]
        )
        XCTAssertTrue(prompt.contains("Drive (2011)"))
        XCTAssertTrue(prompt.contains("Heat (1995)"))
    }

    func test_buildPrompt_omitsExcludeSectionWhenEmpty() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "anything", decade: .any, count: 20, exclude: [])
        XCTAssertFalse(prompt.lowercased().contains("do not include"))
    }

    func test_parse_extractsTitlesFromCleanJSON() throws {
        let raw = """
        [{"title":"Drive","year":2011,"reason":"x"},
         {"title":"Heat","year":1995,"reason":"y"}]
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "Drive")
        XCTAssertEqual(parsed[0].year, 2011)
        XCTAssertEqual(parsed[1].title, "Heat")
    }

    func test_parse_toleratesCodeFences() throws {
        let raw = """
        Here you go:
        ```json
        [{"title":"Drive","year":2011,"reason":"x"}]
        ```
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "Drive")
    }

    func test_parse_toleratesTrailingProse() throws {
        let raw = """
        [{"title":"Drive","year":2011,"reason":"x"}]
        Hope this helps!
        """
        let parsed = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(parsed.count, 1)
    }

    func test_parse_throwsOnNoArray() {
        XCTAssertThrowsError(try DiscoverLLMPrompt.parse("not json at all"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Packages/ArrCore && swift test --filter DiscoverLLMPromptTests
```

Expected: build fails — `DiscoverLLMPrompt` is undefined.

- [ ] **Step 3: Implement the prompt builder + parser**

Create `Services/DiscoverLLMPrompt.swift`:

```swift
import Foundation

public enum DiscoverLLMPrompt {

    public struct Suggestion: Equatable, Sendable {
        public let title: String
        public let year: Int?
    }

    public enum ParseError: Error {
        case noJSONArrayFound
        case malformedJSON(underlying: Error)
    }

    /// Build a single-shot user prompt for the LLM source. Stateless —
    /// any "more suggestions" call passes the cumulative exclude list.
    public static func build(
        mood: String,
        decade: DiscoverDecade,
        count: Int,
        exclude: [String]
    ) -> String {
        var lines: [String] = []
        lines.append(
            "You recommend movies for a tinder-style picker. " +
            "Respond ONLY as a JSON array of objects with keys " +
            "{\"title\": string, \"year\": int|null, \"reason\": string}. " +
            "No prose, no markdown."
        )
        lines.append("Mood: \(mood)")
        if let range = decade.range {
            lines.append("Era constraint: movies released between \(range.lowerBound) and \(range.upperBound).")
        }
        lines.append("Return exactly \(count) distinct movies.")
        if !exclude.isEmpty {
            lines.append("Do NOT include any of these already-shown titles:")
            lines.append(exclude.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Tolerant JSON parse: strips ``` fences, finds the first `[` ...
    /// matching `]`, decodes. Trailing prose after the array is ignored.
    public static func parse(_ raw: String) throws -> [Suggestion] {
        let cleaned = stripFences(raw)
        guard let jsonSlice = extractFirstArray(from: cleaned) else {
            throw ParseError.noJSONArrayFound
        }
        let data = Data(jsonSlice.utf8)
        struct Row: Decodable { let title: String; let year: Int? }
        do {
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return rows.map { Suggestion(title: $0.title, year: $0.year) }
        } catch {
            throw ParseError.malformedJSON(underlying: error)
        }
    }

    private static func stripFences(_ s: String) -> String {
        // Strip ```json ... ``` and bare ``` ... ``` blocks. Keep the
        // contents — those are the candidate JSON.
        var out = s
        if let r = out.range(of: "```json") {
            out.removeSubrange(out.startIndex..<r.upperBound)
        }
        out = out.replacingOccurrences(of: "```", with: "")
        return out
    }

    private static func extractFirstArray(from s: String) -> String? {
        // Find the first '[' and its matching ']' accounting for nested
        // brackets inside strings/objects.
        guard let start = s.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if c == "\\" { escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd Packages/ArrCore && swift test --filter DiscoverLLMPromptTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift
git commit -m "feat(discover): LLM prompt builder + tolerant JSON parser"
```

---

## Task 4: `DiscoverViewModel` — round-robin, dedup, top-up

This is the biggest task. The VM holds three async source closures (the closures are injected so tests can substitute them — no need for a `DiscoverSourceProtocol`).

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- Create: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
        // Drain past the top-up threshold (5 remaining).
        for _ in 0..<7 { await vm.swipe(right: false) }
        // Allow the top-up Task to settle.
        try? await Task.sleep(nanoseconds: 50_000_000)
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
            llm: { _, _ in llmCalled = true; return [] }
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Packages/ArrCore && swift test --filter DiscoverViewModelTests
```

Expected: build fails — `DiscoverViewModel` is undefined.

- [ ] **Step 3: Implement `DiscoverViewModel`**

Create `ViewModels/DiscoverViewModel.swift`:

```swift
import Foundation
import SwiftUI

@MainActor
public final class DiscoverViewModel: ObservableObject {

    public enum Source: Hashable, CaseIterable, Sendable {
        case tmdb, library, llm
    }

    // MARK: - Published state

    @Published public private(set) var current: DiscoverItem?
    @Published public private(set) var queue: [DiscoverItem] = []
    @Published public var filter = DiscoverFilter()
    @Published public var moodText: String = ""
    @Published public private(set) var failedSources: Set<Source> = []
    @Published public private(set) var llmPoolExhausted: Bool = false
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    // MARK: - Source closures

    /// `(filter, page)` → items. `page` is 1-based, advanced by VM.
    public typealias TMDBSource = @MainActor (DiscoverFilter, Int) async throws -> [DiscoverItem]
    /// `(filter)` → items. The library source produces its full pool
    /// up-front; pagination is meaningless against a finite library.
    public typealias LibrarySource = @MainActor (DiscoverFilter) async throws -> [DiscoverItem]
    /// `(exclude, mood)` → items. Stateless. VM passes the cumulative
    /// exclude list and the current `moodText`. Returns empty array
    /// when mood is empty (gate is enforced by the VM; the closure can
    /// assume mood is non-empty when called).
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
    private var rrIndex = 0
    private var topUpTask: Task<Void, Never>?
    private let topUpThreshold = 5
    private let perSourceQuota = 10

    public init() {}

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

    public func swipe(right: Bool) async {
        guard let item = current else { return }
        await performSwipeAction(item, right: right)
        advanceIfNeeded()
        if queue.count < topUpThreshold {
            scheduleTopUp()
        }
    }

    public func requestMoreLLM() async {
        guard llm != nil else { return }
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
        if tmdb != nil && !failedSources.contains(.tmdb) { out.append(.tmdb) }
        if library != nil && !failedSources.contains(.library) && !libraryDrained {
            out.append(.library)
        }
        if llm != nil && !failedSources.contains(.llm) && !llmDormant && !moodText.isEmpty {
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
                items = try await llm!(llmShownTitles, moodText)
                if items.isEmpty {
                    llmDormant = true
                    llmPoolExhausted = true
                } else {
                    llmShownTitles.append(contentsOf: items.map(titleYearKey))
                }
            }
            append(items)
        } catch {
            failedSources.insert(source)
            errorMessage = "Discover source failed: \(source) (\(error))"
        }
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
        // If the swipe handler called us after consuming `current`,
        // ensure the next is loaded.
        if current == nil, !queue.isEmpty {
            current = queue.removeFirst()
        }
    }

    private func performSwipeAction(_ item: DiscoverItem, right: Bool) async {
        // VM doesn't directly execute the action — it surfaces it via
        // `pendingAction` for the view to handle through existing app
        // pipelines (DetailRequest, SearchAddPanel overlay). Keeping
        // side effects in the View layer matches how SearchView already
        // works and avoids dragging ConfigStore + NotificationCenter
        // into the VM.
        if right {
            pendingAction = item.action
            pendingActionItem = item
        }
        // Either way, drop the current card.
        current = nil
    }

    @Published public private(set) var pendingAction: DiscoverAction?
    @Published public private(set) var pendingActionItem: DiscoverItem?

    /// Called by the view after it has handled `pendingAction`.
    public func clearPendingAction() {
        pendingAction = nil
        pendingActionItem = nil
    }

    private func scheduleTopUp() {
        // Avoid stacking top-up tasks while one is in flight.
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
        pendingAction = nil
        pendingActionItem = nil
        topUpTask?.cancel()
        topUpTask = nil
    }

    private func titleYearKey(_ item: DiscoverItem) -> String {
        let year = item.result.year.map(String.init) ?? ""
        return year.isEmpty ? item.result.title : "\(item.result.title) (\(year))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd Packages/ArrCore && swift test --filter DiscoverViewModelTests
```

Expected: PASS. If `test_topUp_fetchesMoreWhenQueueBelowThreshold` is flaky, bump the sleep to `200_000_000`.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift
git commit -m "feat(discover): DiscoverViewModel with round-robin, dedup, top-up"
```

---

## Task 5: TMDB source closure (real wiring)

The VM accepts a closure; this task writes the production closure that wraps `TMDBClient.discoverMovies` and maps `TMDBMovieSummary` → `SearchResult` → `DiscoverItem`.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift` — add a `DiscoverSources` enum/struct with static factory functions OR add a top-level `Discover` namespace. Put production wiring there to keep VM testable.

- [ ] **Step 1: Create a `Discover` factory namespace**

Append to `DiscoverViewModel.swift` (or create a new file `Services/DiscoverSources.swift` — your call; keep it adjacent to the VM):

```swift
public enum DiscoverSources {

    /// TMDB Discover source. Drops anything already in the local Radarr
    /// library (callers must pass an up-to-date `libraryTmdbIds`).
    @MainActor
    public static func tmdb(
        apiKey: String,
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>
    ) -> DiscoverViewModel.TMDBSource {
        let client = TMDBClient(apiKey: apiKey)
        return { filter, page in
            let range = filter.decade.range
            let summaries = try await client.discoverMovies(
                startYear: range?.lowerBound,
                endYear: range?.upperBound,
                sortBy: "popularity.desc"
            )
            let owned = libraryTmdbIds()
            return summaries.compactMap { s -> DiscoverItem? in
                if owned.contains(s.id) { return nil }
                let result = SearchResult(
                    id: s.id, foreignId: String(s.id),
                    title: s.title, subtitle: nil,
                    year: s.releaseYear,           // helper on TMDBMovieSummary
                    rating: s.voteAverage,
                    imdb: nil, rottenTomatoes: nil, metacritic: nil,
                    overview: s.overview, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: TMDBClient.imageURL(path: s.posterPath),
                    source: .radarr, inLibraryArrId: nil
                )
                return DiscoverItem(result: result, action: .addToRadarr, originLabel: .tmdb)
            }
        }
    }

    /// Library source. `radarr` produces a `[RadarrLibraryRecord]`;
    /// we filter, shuffle, and wrap.
    @MainActor
    public static func library(
        radarr: @escaping @MainActor () async throws -> [RadarrLibraryRecord]
    ) -> DiscoverViewModel.LibrarySource {
        return { filter in
            let all = try await radarr()
            let filtered = all.filter { rec in
                filter.matches(year: rec.year, monitored: rec.monitored)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let posterURL: URL? = rec.images?.first(where: { $0.coverType == "poster" })
                    .flatMap { URL(string: $0.remoteUrl ?? "") }
                let result = SearchResult(
                    id: arrId, foreignId: rec.tmdbId.map(String.init) ?? "",
                    title: title, subtitle: nil,
                    year: rec.year, rating: nil, imdb: nil,
                    rottenTomatoes: nil, metacritic: nil,
                    overview: nil, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: posterURL, source: .radarr, inLibraryArrId: arrId
                )
                return DiscoverItem(
                    result: result,
                    action: .openDetail(arrId: arrId),
                    originLabel: .library
                )
            }
        }
    }

    /// LLM source. Stateless single-shot. Returns empty when the call
    /// fails to parse — caller (VM) treats this as pool exhaustion.
    @MainActor
    public static func llm(
        provider: LLMProvider,
        radarrLookup: @escaping @MainActor (String) async throws -> [RadarrLookupRecord],
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>,
        decade: @escaping @MainActor () -> DiscoverDecade,
        count: Int = 20
    ) -> DiscoverViewModel.LLMSource {
        return { exclude, mood in
            let prompt = DiscoverLLMPrompt.build(
                mood: mood, decade: decade(), count: count, exclude: exclude
            )
            let response = try await provider.respond(prompt: prompt, tools: [], history: [])
            guard let suggestions = try? DiscoverLLMPrompt.parse(response.text) else {
                return []
            }
            let owned = libraryTmdbIds()
            var out: [DiscoverItem] = []
            for s in suggestions {
                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                let hits = (try? await radarrLookup(term)) ?? []
                guard let first = hits.first else { continue }
                let tmdbId = first.tmdbId ?? 0
                let inLibrary = tmdbId != 0 && owned.contains(tmdbId)
                let posterURL: URL? = first.images?
                    .first(where: { $0.coverType == "poster" })
                    .flatMap { URL(string: $0.remoteUrl ?? "") }
                let result = SearchResult(
                    id: tmdbId, foreignId: tmdbId == 0 ? "" : String(tmdbId),
                    title: first.title, subtitle: nil,
                    year: first.year,
                    rating: first.ratings?.tmdb?.value,
                    imdb: first.ratings?.imdb?.value,
                    rottenTomatoes: first.ratings?.rottenTomatoes?.value,
                    metacritic: first.ratings?.metacritic?.value,
                    overview: first.overview, runtime: first.runtime,
                    genres: first.genres ?? [], network: first.studio,
                    certification: first.certification,
                    posterURL: posterURL,
                    source: .radarr,
                    inLibraryArrId: nil
                )
                let action: DiscoverAction = inLibrary
                    // openDetail wants the arrId, not the tmdbId — for
                    // already-owned LLM hits we don't know it without a
                    // second roundtrip. Surface as .addToRadarr so the
                    // existing SearchAddPanel detects the dup and the
                    // user lands on the right action surface.
                    ? .addToRadarr
                    : .addToRadarr
                _ = inLibrary // silence unused; left for clarity
                out.append(DiscoverItem(result: result, action: action, originLabel: .llm))
            }
            return out
        }
    }
}
```

> **Note on `TMDBMovieSummary.releaseYear`:** check whether this helper exists in `TMDBClient.swift` (around lines 26–50). If not, add it as a tiny extension in the same file:
>
> ```swift
> extension TMDBMovieSummary {
>     public var releaseYear: Int? {
>         guard let releaseDate, releaseDate.count >= 4 else { return nil }
>         return Int(releaseDate.prefix(4))
>     }
> }
> ```

> **Note on `ArrImage` shape:** verify the property name is `remoteUrl` and `coverType` by grepping; adjust if the existing model uses `url` / `type`.

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -40
```

Expected: build succeeds. If `ArrImage` field names differ, fix the references.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Sources/ArrCore/Services/TMDBClient.swift
git commit -m "feat(discover): production source closures (TMDB, Library, LLM)"
```

---

## Task 6: `DiscoverFilterBar` view

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverFilterBar.swift`

- [ ] **Step 1: Implement the filter bar**

```swift
import SwiftUI

public struct DiscoverFilterBar: View {
    @Binding var filter: DiscoverFilter
    @Binding var moodText: String
    let llmAvailable: Bool
    let onReshuffle: () -> Void

    public init(filter: Binding<DiscoverFilter>,
                moodText: Binding<String>,
                llmAvailable: Bool,
                onReshuffle: @escaping () -> Void) {
        self._filter = filter
        self._moodText = moodText
        self.llmAvailable = llmAvailable
        self.onReshuffle = onReshuffle
    }

    public var body: some View {
        HStack(spacing: 8) {
            decadePicker
            monitoredToggle
            if llmAvailable { moodField }
            Spacer(minLength: 4)
            Button(action: onReshuffle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Reshuffle", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var decadePicker: some View {
        Menu {
            Picker(selection: $filter.decade) {
                ForEach(DiscoverDecade.allCases) { d in
                    Text(d.rawValue).tag(d)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(filter.decade.rawValue)
                    .scaledFont(size: 11, weight: .medium)
                Image(systemName: "chevron.down").scaledFont(size: 8, weight: .bold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var monitoredToggle: some View {
        Button {
            filter.monitoredOnly.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: filter.monitoredOnly ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Monitored", bundle: .module)
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundStyle(filter.monitoredOnly ? Color.accentColor : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(
                filter.monitoredOnly
                ? Color.accentColor.opacity(0.18)
                : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var moodField: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .scaledFont(size: 11)
                .foregroundStyle(.purple)
            TextField("", text: $moodText, prompt:
                Text("Mood…", bundle: .module))
                .textFieldStyle(.plain)
                .scaledFont(size: 11)
                .frame(minWidth: 80, maxWidth: 140)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -20
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverFilterBar.swift
git commit -m "feat(discover): filter bar (decade, monitored, mood, reshuffle)"
```

---

## Task 7: `DiscoverCardView` — card body + action buttons

Reuses `MediaHeaderCard` (or `RemotePoster` + text composition; choose whichever fits the popover's ~400pt width best — read both before writing).

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverCardView.swift`

- [ ] **Step 1: Read the existing primitives**

Open `Views/MediaHeaderCard.swift` and `Views/RemotePoster.swift`. Note their initializers and what data they require. If `MediaHeaderCard` cleanly accepts a `SearchResult`-shaped input, prefer it; otherwise compose `RemotePoster` + text directly.

- [ ] **Step 2: Implement the card**

```swift
import SwiftUI

public struct DiscoverCardView: View {
    let item: DiscoverItem
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void

    public init(item: DiscoverItem,
                onSwipeRight: @escaping () -> Void,
                onSwipeLeft: @escaping () -> Void) {
        self.item = item
        self.onSwipeRight = onSwipeRight
        self.onSwipeLeft = onSwipeLeft
    }

    public var body: some View {
        VStack(spacing: 12) {
            poster
            titleBlock
            overview
            originChip
            actionRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var poster: some View {
        // Use RemotePoster directly — narrow popover, want to control size.
        RemotePoster(url: item.result.posterURL, requiresAuth: false)
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleBlock: some View {
        VStack(spacing: 2) {
            Text(item.result.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let y = item.result.year {
                Text(verbatim: "\(y)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = item.result.overview, !text.isEmpty {
            Text(text)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
    }

    private var originChip: some View {
        HStack(spacing: 4) {
            Image(systemName: originIcon)
                .scaledFont(size: 10, weight: .semibold)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var originIcon: String {
        switch item.originLabel {
        case .tmdb:    return "film"
        case .library: return "books.vertical"
        case .llm:     return "sparkles"
        }
    }
    private var originLabel: LocalizedStringKey {
        switch item.originLabel {
        case .tmdb:    return "From TMDB"
        case .library: return "From your library"
        case .llm:     return "From AI"
        }
    }

    private var actionRow: some View {
        HStack(spacing: 24) {
            Button(action: onSwipeLeft) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 32, weight: .regular)
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button(action: onSwipeRight) {
                Image(systemName: rightActionIcon)
                    .scaledFont(size: 32, weight: .regular)
                    .foregroundStyle(Color.green.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var rightActionIcon: String {
        switch item.action {
        case .addToRadarr: return "plus.circle.fill"
        case .openDetail:  return "play.circle.fill"
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -20
```

Expected: succeeds. If `RemotePoster` requires a different init, adjust to match its actual signature.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverCardView.swift
git commit -m "feat(discover): card view (poster, overview, origin chip, actions)"
```

---

## Task 8: Flesh out `DiscoverTabView` — filter bar + card stack + state surfaces

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`

- [ ] **Step 1: Replace the stub with the full view**

```swift
import SwiftUI

public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, Int) -> Void

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onAddToRadarr: @escaping (SearchResult) -> Void,
                onOpenDetail: @escaping (DiscoverItem, Int) -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.onAddToRadarr = onAddToRadarr
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        VStack(spacing: 0) {
            DiscoverFilterBar(
                filter: Binding(get: { viewModel.filter },
                                set: { viewModel.filter = $0 }),
                moodText: Binding(get: { viewModel.moodText },
                                  set: { viewModel.moodText = $0 }),
                llmAvailable: llmAvailable,
                onReshuffle: { Task { await viewModel.reshuffle() } }
            )
            Divider()

            ScrollView {
                content
                    .padding(.vertical, 12)
            }
        }
        .task(id: filterFingerprint) {
            await viewModel.reshuffle()
        }
        .onChange(of: viewModel.pendingAction) { _, action in
            guard let action, let item = viewModel.pendingActionItem else { return }
            switch action {
            case .addToRadarr:
                onAddToRadarr(item.result)
            case .openDetail(let arrId):
                onOpenDetail(item, arrId)
            }
            viewModel.clearPendingAction()
        }
    }

    /// Triggers `task(id:)` to re-fetch when filter or mood change. Hash
    /// of the inputs collapses to a stable Int the modifier accepts.
    private var filterFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.filter.decade)
        hasher.combine(viewModel.filter.monitoredOnly)
        hasher.combine(viewModel.moodText)
        return hasher.finalize()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.current == nil {
            ProgressView().controlSize(.small).padding(.top, 40)
        } else if let item = viewModel.current {
            DiscoverCardView(
                item: item,
                onSwipeRight: { Task { await viewModel.swipe(right: true) } },
                onSwipeLeft:  { Task { await viewModel.swipe(right: false) } }
            )
            .padding(.horizontal, 12)
            if viewModel.llmPoolExhausted && llmAvailable && !viewModel.moodText.isEmpty {
                Button {
                    Task { await viewModel.requestMoreLLM() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("More AI suggestions", bundle: .module)
                    }
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            if !viewModel.failedSources.isEmpty {
                Text(failureBadgeText)
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .scaledFont(size: 22, weight: .light)
                    .foregroundStyle(.tertiary)
                Text("No more cards", bundle: .module)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 60)
        }
    }

    private var failureBadgeText: String {
        let names = viewModel.failedSources.map { src -> String in
            switch src {
            case .tmdb:    return "TMDB"
            case .library: return "Library"
            case .llm:     return "AI"
            }
        }.sorted().joined(separator: ", ")
        return "\(names) unavailable"
    }
}
```

- [ ] **Step 2: Build (it won't compile yet because Task 1's stub init signature differs from this one)**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -30
```

Expected: build error in `PopoverContentView.swift` — `DiscoverTabView()` no longer compiles. Task 9 fixes the call site.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift
git commit -m "feat(discover): tab view with filter bar, card stack, state surfaces"
```

---

## Task 9: Wire `DiscoverViewModel` into `PopoverContentView`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Add the VM as a `@StateObject`**

Right next to `@StateObject private var searchViewModel = SearchViewModel()` (line 28):

```swift
@StateObject private var discoverViewModel = DiscoverViewModel()
```

- [ ] **Step 2: Configure the VM on appear**

In `.onAppear` (around line 116), after `searchViewModel.setup(...)` add:

```swift
configureDiscover()
```

Add a new helper method (place it next to other private helpers near the bottom of the file):

```swift
private func configureDiscover() {
    let radarrCfg = configStore.radarr
    let radarrClient = RadarrClient(config: radarrCfg)   // confirm constructor — see SearchViewModel.setup for pattern

    // Library tmdb ids — cached, refreshed once per session.
    var cachedLibrary: [RadarrLibraryRecord] = []
    let libraryFn: @MainActor () async throws -> [RadarrLibraryRecord] = {
        if cachedLibrary.isEmpty {
            cachedLibrary = try await radarrClient.fetchAllMovies()
        }
        return cachedLibrary
    }
    let ownedIds: @MainActor () -> Set<Int> = {
        Set(cachedLibrary.compactMap(\.tmdbId))
    }

    discoverViewModel.configure(
        tmdb: configStore.tmdbEnabled
            ? DiscoverSources.tmdb(apiKey: configStore.tmdbApiKey,
                                   libraryTmdbIds: ownedIds)
            : nil,
        library: DiscoverSources.library(radarr: libraryFn),
        llm: chatAvailable
            ? DiscoverSources.llm(
                provider: chatHolder.vm.provider,  // confirm accessor
                radarrLookup: { term in try await radarrClient.lookupMovie(term: term) }, // confirm method name
                libraryTmdbIds: ownedIds,
                decade: { [vm = discoverViewModel] in vm.filter.decade }
            )
            : nil
    )
}
```

> **Verify the unknowns marked "confirm" by grepping:**
> - `RadarrClient` init: `grep -n "public init\|init(" Packages/ArrCore/Sources/ArrCore/Services/RadarrClient.swift`
> - `ChatViewModelHolder.vm.provider` accessor: `grep -n "provider\|LLMProvider" Packages/ArrCore/Sources/ArrCore/ViewModels/ChatViewModel*.swift`
> - Radarr lookup method: `grep -n "lookup\|movie/lookup" Packages/ArrCore/Sources/ArrCore/Services/RadarrClient.swift`
>
> Adjust the closure bodies above to match the real signatures.

- [ ] **Step 3: Replace the `.discover` branch in `selectedTab` switch**

Change:

```swift
case .discover:
    DiscoverTabView()
```

to:

```swift
case .discover:
    DiscoverTabView(
        viewModel: discoverViewModel,
        llmAvailable: chatAvailable,
        onAddToRadarr: { result in
            // Reuse the existing SearchAddPanel overlay — same path
            // every other "tap to add" flow uses.
            self.searchResult = result
        },
        onOpenDetail: { item, arrId in
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: .radarr,
                    entityId: arrId,
                    title: item.result.title,
                    posterURL: item.result.posterURL,
                    posterRequiresAuth: false
                )
            )
        }
    )
```

- [ ] **Step 4: Build, kill, relaunch**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -40
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Expected: app launches; Discover tab shows the filter bar + first card from TMDB (assuming Radarr + TMDB key configured). Swipe-left advances to the next. Swipe-right on a TMDB card opens the SearchAddPanel overlay.

- [ ] **Step 5: Manual verification checklist**

In the running app, verify:
1. Tab "Discover" appears when Radarr is configured.
2. With only Radarr configured (no TMDB key, no LLM): only Library cards show.
3. With TMDB key configured: TMDB and Library cards alternate.
4. With LLM provider + non-empty mood: LLM cards mix in.
5. Swipe-right on TMDB card opens add overlay.
6. Swipe-right on Library card opens DetailView.
7. ←/→ keyboard arrows swipe (when popover has focus).
8. Decade filter narrows results visibly.
9. Reshuffle button replaces the current stack.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "feat(discover): wire DiscoverViewModel into PopoverContentView"
```

---

## Task 10: Localization strings

**Files:**
- Modify: the project's `Localizable.xcstrings` (or per-language `.strings` files) — find them with `find Packages/ArrCore -name "Localizable*" -o -name "*.xcstrings"`

- [ ] **Step 1: Identify the existing localization file format**

```bash
find Packages/ArrCore -name "Localizable*" -o -name "*.xcstrings" | head
```

- [ ] **Step 2: Add the new keys**

Add (in whatever format the project uses) translations for:
- `Discover`
- `Mood…`
- `Monitored`
- `Reshuffle`
- `From TMDB`
- `From your library`
- `From AI`
- `More AI suggestions`
- `No more cards`

Match the existing precedent — if other UI strings are present in `pl`, `de`, `es`, `fr`, add all of them. If only English, English is fine for MVP.

- [ ] **Step 3: Build to verify no string warnings**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -i "string\|loc" | head -20
```

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Resources/
git commit -m "feat(discover): localization strings"
```

---

## Task 11: Full test sweep + final manual verification

- [ ] **Step 1: Run the full test suite**

```bash
cd Packages/ArrCore && swift test 2>&1 | tail -30
```

Expected: all tests pass, including pre-existing ones.

- [ ] **Step 2: Build + relaunch + smoke test**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Run through the manual checklist from Task 9 Step 5 once more. Note any rough edges as follow-up.

- [ ] **Step 3: Final commit (if any tweaks)**

```bash
git status
# commit any leftovers
```

---

## Self-Review Notes (carried out by author of plan)

- **Spec coverage:** every section of the spec maps to a task — sources (5), VM (4), filter bar (6), card (7), tab view (8), wiring (9), localization (10), tests (sprinkled). Tests cover dedup, round-robin, top-up, per-source failure, LLM exhaustion + exclude accumulation, mood-empty gating. The "more LLM suggestions" button and pool exhaustion are covered.
- **Placeholders:** none of "TBD/TODO/implement later" — but Tasks 5 and 9 do contain explicit "confirm by grepping" markers where the spec author legitimately doesn't know exact symbol names (RadarrClient init, ChatViewModelHolder.vm.provider accessor, RadarrClient lookup method name, ArrImage field names). These are flagged inline with the exact grep command to resolve them — they are an honest "verify before assuming" instruction, not a placeholder.
- **Type consistency:** `DiscoverViewModel.Source` is the type used by `failedSources`; `DiscoverItem.Origin` is the type on items themselves — they're separate by design (failure state is about the closure, origin is about the data) but kept naming distinct on purpose. `TMDBSource`/`LibrarySource`/`LLMSource` are the closure typealiases used in `configure`.
- **Library source filter scope:** matches spec — decade + monitoredOnly only. Genre/runtime explicitly deferred per spec MVP scope.
- **Reuse:** `SearchResult`, `MediaHeaderCard` / `RemotePoster`, `SearchAddPanel`, `DetailRequest`, `TMDBClient.discoverMovies`, `RadarrClient.fetchAllMovies`, `RadarrClient` lookup, `LLMProvider.respond` — all reused.
