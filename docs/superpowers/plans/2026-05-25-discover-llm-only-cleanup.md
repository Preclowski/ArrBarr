# Discover — LLM-Only Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the visual composer from the Discover picker, make the tab bar always visible inside Discover, and reduce the source set to LLM-only (plus the Library source for "already own" cross-reference).

**Architecture:** All Discover code lives on the `discover/tab` branch (the existing implementation). This plan operates on that branch. Picker collapses to a single free-form text field bound to `DiscoverViewModel.moodText`; submit triggers `reshuffle()` and pushes the user into the existing `.tinder` stage. The LLM source becomes the sole new-card producer; TMDB Discover sources and the entire suggestion / autocomplete / custom-tag machinery in the VM are deleted.

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftPM (ArrCore package) / XCTest.

**Spec:** `docs/superpowers/specs/2026-05-25-discover-llm-only-cleanup-design.md`

---

## Pre-flight

- [ ] **Step 0: Switch to the `discover/tab` branch**

This entire plan modifies files that exist only on `discover/tab`. Verify and switch:

```bash
git fetch
git checkout discover/tab
git pull --ff-only
git status   # expect clean working tree
```

Expected: `On branch discover/tab`, clean status.

---

## File map

| Path | Role | Change |
| --- | --- | --- |
| `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` | popover host, tab bar | drop `hideTabBarDeepInDiscover` + its guard; drop TMDB source wiring in `configureDiscover` |
| `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift` | filter picker | full rewrite — single TextField + submit button |
| `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift` | tinder host | simplify `filterSummaryChip` text + `clearAllFilters` |
| `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift` | state + orchestration | delete suggestion, custom-tag, person-autocomplete, TMDB-source plumbing; simplify `LLMSource`/`LLMResult` |
| `Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift` | source factories | delete `tmdbMovies` + `tmdbShows`; simplify `llm` (no person resolution, returns `[DiscoverItem]`) |
| `Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift` | prompt build + parse | drop `SuggestedFilters` + `decade` arg; `Response.suggestions` only |
| `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift` | prompt tests | update for new shape |
| `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift` | VM tests | drop suggestion / person / custom-mood tests; keep core fetch + swipe |
| `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` | strings | add picker heading / placeholder / button keys; remove dead keys later (Task 9) |

---

## Build & smoke commands (reuse throughout)

```bash
# SPM tests
cd Packages/ArrCore && swift test
cd ../..

# App build
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build

# Relaunch
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

---

### Task 1: Always show the tab bar inside Discover

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Delete the `hideTabBarDeepInDiscover` computed property**

In `PopoverContentView.swift`, find the property at ~line 534 (declared right before `// MARK: - Tab bar`). It looks like:

```swift
    /// active tinder session exists (chip-tap path). Both cases have a "<"
    /// back arrow the user can use to exit. The .kind stage and fresh
    /// .filters (no active tinder session) keep the tab bar visible so the
    /// user can bail to another tab without being stranded.
    private var hideTabBarDeepInDiscover: Bool {
        guard selectedTab == .discover else { return false }
        if discoverViewModel.stage == .tinder { return true }
        // .picker stage: only hide if we're editing filters from an
        // active tinder session (chip-tap path) — fromTinderBackBar shows "<".
        if discoverViewModel.current != nil { return true }
        return false
    }
```

Delete the entire block (doc comment + property).

- [ ] **Step 2: Drop the guard in the popover body**

Around line 247 in the same file, the tab bar is rendered behind a conditional:

```swift
                } else if anyArrConfigured {
                    if !hideTabBarDeepInDiscover {
                        tabBar
                    }
                    Group {
```

Change to render `tabBar` unconditionally:

```swift
                } else if anyArrConfigured {
                    tabBar
                    Group {
```

- [ ] **Step 3: Build and smoke**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Expected: build succeeds. Open Discover, submit anything, swipe a card, open the Picks list — tab bar stays visible on every screen.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "$(cat <<'EOF'
fix(discover): always show main tab bar

Drops hideTabBarDeepInDiscover. Users were getting stuck inside Discover
the moment they submitted because the only escape was the floating back
arrow. Tab bar now stays visible across picker / tinder / matched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Simplify the LLM prompt

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift`

The LLM no longer returns structured filters and no longer gets a structured decade hint — the user's prose is the whole input.

- [ ] **Step 1: Rewrite the prompt test suite to the new shape**

Replace the entire content of `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift` with:

```swift
import XCTest
@testable import ArrCore

final class DiscoverLLMPromptTests: XCTestCase {

    // MARK: - build

    func test_build_movie_includesMoodAndCount_andExclusionList() {
        let p = DiscoverLLMPrompt.build(
            mood: "cozy 90s comedy",
            count: 12,
            exclude: ["Toy Story", "Heat"],
            kindHint: .movie
        )
        XCTAssertTrue(p.contains("Mood: cozy 90s comedy"))
        XCTAssertTrue(p.contains("Return exactly 12 distinct movies"))
        XCTAssertTrue(p.contains("Toy Story, Heat"))
        XCTAssertTrue(p.contains("Return only movies"))
        XCTAssertFalse(p.contains("filters"))    // no structured filter schema anymore
        XCTAssertFalse(p.contains("decade"))     // no era constraint anymore
    }

    func test_build_show_returnsOnlyTVShows() {
        let p = DiscoverLLMPrompt.build(
            mood: "moody crime",
            count: 8,
            exclude: [],
            kindHint: .show
        )
        XCTAssertTrue(p.contains("Return only TV shows"))
        XCTAssertTrue(p.contains("Return exactly 8 distinct TV shows"))
    }

    func test_build_emptyExclusion_omitsExclusionSection() {
        let p = DiscoverLLMPrompt.build(
            mood: "anything",
            count: 5,
            exclude: [],
            kindHint: .movie
        )
        XCTAssertFalse(p.contains("Do NOT include"))
    }

    // MARK: - parse

    func test_parse_titlesOnly_returnsSuggestions() throws {
        let raw = #"""
        {"titles":[{"title":"Heat","year":1995},{"title":"Inception","year":2010}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.count, 2)
        XCTAssertEqual(resp.suggestions[0].title, "Heat")
        XCTAssertEqual(resp.suggestions[0].year, 1995)
        XCTAssertEqual(resp.suggestions[1].title, "Inception")
    }

    func test_parse_titleKindAnnotation_isHonoured() throws {
        let raw = #"""
        {"titles":[{"title":"Breaking Bad","year":2008,"kind":"show"}]}
        """#
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.first?.kind, .show)
    }

    func test_parse_stripsMarkdownFences() throws {
        let raw = """
        ```json
        {"titles":[{"title":"Akira","year":1988}]}
        ```
        """
        let resp = try DiscoverLLMPrompt.parse(raw)
        XCTAssertEqual(resp.suggestions.first?.title, "Akira")
    }

    func test_parse_noJSON_throws() {
        XCTAssertThrowsError(try DiscoverLLMPrompt.parse("hello there")) { err in
            guard case DiscoverLLMPrompt.ParseError.noJSONObjectFound = err else {
                return XCTFail("Unexpected error: \(err)")
            }
        }
    }
}
```

- [ ] **Step 2: Run the test suite — expect failures**

```bash
cd Packages/ArrCore && swift test --filter DiscoverLLMPromptTests; cd ../..
```

Expected: compile errors (`SuggestedFilters` referenced elsewhere is fine to stay for now; the test file itself should fail because of the new `build` signature without `decade:`).

- [ ] **Step 3: Rewrite `DiscoverLLMPrompt.swift`**

Replace the entire file contents with:

```swift
import Foundation

public enum DiscoverLLMPrompt {

    public struct Suggestion: Equatable, Sendable {
        public let title: String
        public let year: Int?
        /// Optional kind annotation from the LLM response.
        /// `nil` means the caller infers the kind from the current mediaSelection.
        public let kind: DiscoverItemKind?
    }

    public struct Response: Equatable, Sendable {
        public let suggestions: [Suggestion]
    }

    public enum ParseError: Error {
        case noJSONObjectFound
        case malformedJSON(underlying: Error)
    }

    public static func build(mood: String,
                             count: Int,
                             exclude: [String],
                             kindHint: DiscoverMediaSelection = .movie) -> String {
        var lines: [String] = []
        switch kindHint {
        case .movie:
            lines.append(
                "You recommend movies for a tinder-style picker. " +
                "Reply with a single JSON object, no prose, no markdown: " +
                "{ \"titles\": [ { \"title\": string, \"year\": int|null } ] }."
            )
            lines.append("Return only movies — no TV shows.")
        case .show:
            lines.append(
                "You recommend TV shows for a tinder-style picker. " +
                "Reply with a single JSON object, no prose, no markdown: " +
                "{ \"titles\": [ { \"title\": string, \"year\": int|null } ] }."
            )
            lines.append("Return only TV shows — no movies.")
        }
        lines.append("Mood: \(mood)")
        let kindLabel: String
        switch kindHint {
        case .movie: kindLabel = "movies"
        case .show:  kindLabel = "TV shows"
        }
        lines.append("Return exactly \(count) distinct \(kindLabel) in `titles`.")
        if !exclude.isEmpty {
            lines.append("Do NOT include any of these already-shown titles:")
            lines.append(exclude.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ raw: String) throws -> Response {
        let cleaned = stripFences(raw)
        guard let jsonSlice = extractFirstObject(from: cleaned) else {
            throw ParseError.noJSONObjectFound
        }
        struct TitleRow: Decodable { let title: String; let year: Int?; let kind: String? }
        struct Root: Decodable { let titles: [TitleRow] }
        do {
            let root = try JSONDecoder().decode(Root.self, from: Data(jsonSlice.utf8))
            let suggestions = root.titles.map { row -> Suggestion in
                let kind: DiscoverItemKind? = row.kind.flatMap { raw in
                    switch raw.lowercased() {
                    case "movie": return .movie
                    case "show", "tv", "series": return .show
                    default: return nil
                    }
                }
                return Suggestion(title: row.title, year: row.year, kind: kind)
            }
            return Response(suggestions: suggestions)
        } catch {
            throw ParseError.malformedJSON(underlying: error)
        }
    }

    private static func stripFences(_ s: String) -> String {
        var out = s
        if let r = out.range(of: "```json") { out.removeSubrange(out.startIndex..<r.upperBound) }
        out = out.replacingOccurrences(of: "```", with: "")
        return out
    }

    private static func extractFirstObject(from s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if c == "\\" { escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the prompt tests — expect pass**

```bash
cd Packages/ArrCore && swift test --filter DiscoverLLMPromptTests; cd ../..
```

Expected: all 6 tests pass. The package may still fail to compile overall because `DiscoverSources.llm` and `DiscoverViewModel` reference the removed `SuggestedFilters`/`filters` API — those are fixed in Task 4 / 3. That's fine; we'll commit and continue.

- [ ] **Step 5: Commit**

(The package as a whole won't build yet — that's expected mid-refactor. Don't run a full `swift test` until Task 5 lands.)

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift
git commit -m "$(cat <<'EOF'
refactor(discover): minimal LLM prompt — titles only

Drop SuggestedFilters and the decade hint from the prompt schema. The
LLM-only flow doesn't need structured filter callbacks; the user's
prose is the entire input. Tests rewritten for the new shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Strip suggestion / custom-tag / person-autocomplete machinery from the VM

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

We delete everything that exists only to feed the visual composer. The VM keeps: `stage`, `moodText`, `filter` (now constant-default, kept because the library source typealias takes one), `current`, `queue`, `matched`, `picksMilestoneTick`, `mediaSelection`, `hasPickedKind`, `autoJumpEnabled`, fetch / swipe / topup machinery, error/loading state.

- [ ] **Step 1: Rewrite the VM test suite to drop dead surface area**

Open `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`. Remove every test that targets one of:

- `SuggestedFilter`, `suggestedFilters`, `suggestionsByCategory`
- `customMoods` / `customPeople` / `customTagsByCategory` (`addCustomMood`, `addCustomPerson`, `addCustomTag`, removal/usage variants)
- `selectedPersonNames` / `togglePerson` / `isPersonSelected`
- `applySuggestedFilters` (was internal; tests may reach it indirectly via the LLM-applied filter path — drop those tests too)
- `LLMResult.suggestedFilters` or `resolvedPersonIds`

Keep tests that target:

- `start()`, `reshuffle()`, `swipe(right:)`, `startSwipe`/`finishSwipe`
- `removeMatch`, `clearMatched`
- `picksMilestoneTick` behavior on every-10th right swipe
- Round-robin merge / dedup
- Source failure handling (`failedSources`, `sourceErrors`)

For each retained test that constructs an `LLMSource` closure, update the return value from
`DiscoverViewModel.LLMResult(items: ..., suggestedFilters: nil, resolvedPersonIds: [])`
to just `items` (the typealias becomes `([String], String) async throws -> [DiscoverItem]` — see Step 2).

- [ ] **Step 2: Slim `DiscoverViewModel.swift`**

Apply these changes to `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`. Read the file first to ensure exact line targeting; the deletions are mechanical.

a) **Delete the entire `SuggestedFilter` struct** (top of the file, lines ~7-16). Doc comment + struct definition.

b) **Replace the `LLMResult` struct** (lines ~28-39) with:

```swift
    // MARK: - LLM result type
    // (Was a struct wrapping items + filter callbacks. Now the LLM source
    // returns [DiscoverItem] directly — kept as a typealias-style remnant
    // only if you need a wrapper later. For now the typealias below takes
    // its place.)
```

…then delete the `LLMResult` struct entirely. (Remove all references in this file; the typealias change in (e) is what callers see.)

c) **Delete these persistence keys** from the `Persistence keys` block (lines ~42-50):

```swift
    private static let customMoodsKey = "ArrBarr.discoverCustomMoods"
    private static let customPeopleKey = "ArrBarr.discoverCustomPeople"
    private static let customTagsByCategoryKey = "ArrBarr.discoverCustomTagsByCategory"
    private static let personNameCacheKey = "ArrBarr.discoverPersonNameCache"
    private static let moodUsageKey = "ArrBarr.discoverMoodUsage"
    private static let personUsageKey = "ArrBarr.discoverPersonUsage"
```

Keep `hasPickedKindKey`, `autoJumpEnabledKey`, `mediaSelectionKey`.

d) **Delete these `@Published` properties** from the Published state block:

```swift
    @Published public private(set) var customMoods: [String] = []
    @Published public private(set) var customPeople: [String] = []
    @Published public private(set) var customTagsByCategory: [String: [String]] = [:]
    @Published public private(set) var personNameCache: [String: Int] = [:]
    @Published public private(set) var selectedPersonNames: Set<String> = []
    @Published public private(set) var moodUsageCount: [String: Int] = [:]
    @Published public private(set) var personUsageCount: [String: Int] = [:]
```

e) **Replace the source typealiases** (around line 165) with:

```swift
    public typealias TMDBSource = @MainActor (DiscoverFilter, Int) async throws -> [DiscoverItem]
    public typealias LibrarySource = @MainActor (DiscoverFilter) async throws -> [DiscoverItem]
    public typealias LLMSource = @MainActor ([String], String) async throws -> [DiscoverItem]
```

(`LLMResult` is gone; LLM source returns `[DiscoverItem]` directly.)

f) **Update `init`** (line ~182) to drop the loads for the deleted persisted state. Remove every line that decodes `customMoodsKey` / `customPeopleKey` / `customTagsByCategoryKey` / `personNameCacheKey` / `moodUsageKey` / `personUsageKey`. Keep `hasPickedKind`, `autoJumpEnabled`, `mediaSelection` init.

g) **Delete these public methods entirely** (everything in the `Custom per-category tags`, `Custom moods`, `Custom people`, `Suggested filters`, and `Person filter helpers` MARK blocks, roughly lines 215-470):

- `addCustomTag(category:label:)`, `removeCustomTag(category:label:)`, `persistCustomTags()`
- `addCustomMood(_:)`, `removeCustomMood(_:)`, `bumpMoodUsage(_:)`
- `addCustomPerson(_:)`, `removeCustomPerson(_:)`, `bumpPersonUsage(_:)`
- `suggestedFilters` computed property
- `suggestionsByCategory(llmAvailable:)`
- `aiStarterPrompts` static, `curatedPool(mediaSelection:)` static
- `activeFilterIds()`, `combinedUsage()`
- `togglePerson(name:)`, `isPersonSelected(name:)`, `applyPersonIdSelection(_:selected:)`

h) **Update `fetchItems(source:)`** (around line 180 after the deletions shift line numbers). In the `.llm` branch, replace:

```swift
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
```

with:

```swift
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
```

i) **Delete `applySuggestedFilters(_:personIds:)`** entirely (the doc-commented private method that consumed `DiscoverLLMPrompt.SuggestedFilters`).

j) Verify `userChangedFilter()` and `mediaSelectionChanged()` still exist — leave them; the picker submit path still calls a tick increment via `userSubmittedMood()`. Drop `userChangedFilter()` ONLY if no remaining caller references it (search the package after edits).

- [ ] **Step 3: Build the package**

```bash
cd Packages/ArrCore && swift build 2>&1 | tail -40; cd ../..
```

Expected: errors only in `DiscoverSources.swift`, `DiscoverPickerView.swift`, `DiscoverTabView.swift`, `PopoverContentView.swift` (consumers of removed APIs). Errors INSIDE `DiscoverViewModel.swift` itself must be zero.

- [ ] **Step 4: Run VM tests in isolation**

```bash
cd Packages/ArrCore && swift test --filter DiscoverViewModelTests; cd ../..
```

Expected: package still won't fully build because of view-layer consumers — `swift test` may fail at link step. If so, accept the failure and proceed; we re-run the full suite at the end of Task 5. Make sure the VM file itself has no compile errors by checking the build output of Step 3.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift
git commit -m "$(cat <<'EOF'
refactor(discover): strip suggestion + custom-tag + person machinery from VM

Drops SuggestedFilter, suggestionsByCategory, custom moods/people/tags
state, person autocomplete (togglePerson/personNameCache/selectedNames),
curated pools, and the LLMResult wrapper. LLMSource now returns
[DiscoverItem] directly. VM keeps only the fetch/swipe/topup core.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Strip TMDB Discover sources and simplify the LLM source

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift`

- [ ] **Step 1: Delete `tmdbMovies` and `tmdbShows`**

In `DiscoverSources.swift`, delete:

- The whole `// MARK: - TMDB Movie source` section and the `static func tmdbMovies(...)` factory.
- The whole `// MARK: - TMDB TV source` section and the `static func tmdbShows(...)` factory.

Keep: `// MARK: - Radarr Library source`, `// MARK: - Sonarr Library source`, helpers section.

- [ ] **Step 2: Simplify the `llm` factory**

Replace the existing `// MARK: - LLM source` block and `public static func llm(...)` with:

```swift
    // MARK: - LLM source

    /// LLM source. The LLM returns a list of title suggestions; we resolve
    /// each one to a Radarr/Sonarr lookup record (poster, ratings, runtime)
    /// and emit a `DiscoverItem`. `kindHint` controls the prompt style and
    /// which lookup backend is used.
    @MainActor
    public static func llm(
        provider: LLMProvider,
        radarrLookup: @escaping @MainActor (String) async throws -> [RadarrLookupRecord],
        sonarrLookup: @escaping @MainActor (String) async throws -> [SonarrLookupRecord],
        kindHint: DiscoverMediaSelection = .movie,
        count: Int = 20
    ) -> DiscoverViewModel.LLMSource {
        return { exclude, mood in
            let prompt = DiscoverLLMPrompt.build(
                mood: mood, count: count, exclude: exclude, kindHint: kindHint
            )
            let response = try await provider.respond(prompt: prompt, tools: [], history: [])
            let parsed: DiscoverLLMPrompt.Response
            do {
                parsed = try DiscoverLLMPrompt.parse(response.text)
            } catch {
                return []
            }
            var out: [DiscoverItem] = []
            for s in parsed.suggestions {
                let resolvedKind: DiscoverItemKind = s.kind ?? (kindHint == .show ? .show : .movie)
                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                switch resolvedKind {
                case .movie:
                    let hits = (try? await radarrLookup(term)) ?? []
                    guard let first = hits.first else { continue }
                    let tmdbId = first.tmdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
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
                        posterURL: poster,
                        source: .radarr,
                        inLibraryArrId: nil
                    )
                    out.append(DiscoverItem(result: result, action: .addToRadarr,
                                            originLabel: .llm, kind: .movie))
                case .show:
                    let hits = (try? await sonarrLookup(term)) ?? []
                    guard let first = hits.first else { continue }
                    let tvdbId = first.tvdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
                    let result = SearchResult(
                        id: tvdbId, foreignId: tvdbId == 0 ? "" : String(tvdbId),
                        title: first.title, subtitle: nil,
                        year: first.year,
                        rating: first.ratings?.value,
                        imdb: nil, rottenTomatoes: nil, metacritic: nil,
                        overview: first.overview, runtime: first.runtime,
                        genres: first.genres ?? [], network: first.network,
                        certification: nil,
                        posterURL: poster,
                        source: .sonarr,
                        inLibraryArrId: nil
                    )
                    out.append(DiscoverItem(result: result, action: .addToSonarr,
                                            originLabel: .llm, kind: .show))
                }
            }
            return out
        }
    }
```

Note the removed params: `tmdbClient`, `libraryTmdbIds`, `decade`. No person resolution, no decade lookup, no library-owned dedup at this layer (the library source already handles owned items).

- [ ] **Step 3: Build the package**

```bash
cd Packages/ArrCore && swift build 2>&1 | tail -30; cd ../..
```

Expected: `DiscoverSources.swift` compiles. Remaining errors only in `PopoverContentView.swift` (still calls the deleted `tmdbMovies`/`tmdbShows` and passes the removed `llm` params).

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift
git commit -m "$(cat <<'EOF'
refactor(discover): drop TMDB sources, simplify LLM source

Removes tmdbMovies/tmdbShows factories — without user-driven filters
they degrade to popular-list noise. LLM source no longer accepts
tmdbClient/libraryTmdbIds/decade params and returns [DiscoverItem]
directly. Library source remains the only structured channel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Update `configureDiscover` and rebuild the package green

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Strip the TMDB source block and simplify the LLM call site**

In `PopoverContentView.swift`, find `private func configureDiscover() async {` (~line 1459). Replace the entire body with:

```swift
    private func configureDiscover() async {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let radarrClient = RadarrClient(config: radarrCfg)
        let sonarrClient = SonarrClient(config: sonarrCfg)

        let selection = discoverViewModel.mediaSelection

        var cachedRadarrLibrary: [RadarrLibraryRecord] = []
        var cachedSonarrLibrary: [SonarrLibraryRecord] = []

        if selection == .movie {
            do { cachedRadarrLibrary = try await radarrClient.fetchAllMovies() } catch {}
        }
        if selection == .show {
            do { cachedSonarrLibrary = try await sonarrClient.fetchAllSeries() } catch {}
        }

        let fetchRadarr: @MainActor () async throws -> [RadarrLibraryRecord] = {
            if cachedRadarrLibrary.isEmpty {
                cachedRadarrLibrary = try await radarrClient.fetchAllMovies()
            }
            return cachedRadarrLibrary
        }
        let fetchSonarr: @MainActor () async throws -> [SonarrLibraryRecord] = {
            if cachedSonarrLibrary.isEmpty {
                cachedSonarrLibrary = try await sonarrClient.fetchAllSeries()
            }
            return cachedSonarrLibrary
        }

        let librarySource: DiscoverViewModel.LibrarySource? = selection == .show
            ? DiscoverSources.sonarrLibrary(fetchAll: fetchSonarr)
            : DiscoverSources.radarrLibrary(fetchAll: fetchRadarr)

        let llmSource: DiscoverViewModel.LLMSource? = chatAvailable
            ? DiscoverSources.llm(
                provider: chatHolder.vm.provider,
                radarrLookup: { term in try await radarrClient.lookupMovies(term: term) },
                sonarrLookup: { term in try await sonarrClient.lookupSeries(term: term) },
                kindHint: selection
            )
            : nil

        discoverViewModel.configure(
            tmdb: nil,
            library: librarySource,
            llm: llmSource
        )
        discoverViewModel.configureCredits(apiKey: configStore.tmdbApiKey)
    }
```

(We pass `tmdb: nil` because the VM's `configure` API still accepts the param — actual deletion of the param can come later if desired; YAGNI for now.)

- [ ] **Step 2: Drop the `tmdbAvailable` argument to `DiscoverTabView` (it's no longer used)**

Around line 257-265, the `DiscoverTabView(...)` initializer call may still pass a `tmdbAvailable:` arg. Leave the call site as is FOR NOW — Task 6 simplifies the picker init signature and we'll prune callers there.

- [ ] **Step 3: Build the package**

```bash
cd Packages/ArrCore && swift build 2>&1 | tail -30; cd ../..
```

Expected: still red — `DiscoverPickerView.swift` and possibly `DiscoverTabView.swift` reference removed VM APIs (`viewModel.customMoods`, `viewModel.suggestionsByCategory`, etc.). That's fine; Task 6 rewrites the picker.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "$(cat <<'EOF'
refactor(discover): wire popover to slim source set

Drops TMDB Discover wiring from configureDiscover and updates the LLM
call site for the simplified factory signature. tmdb source param
passed as nil for now.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Rewrite `DiscoverPickerView` as a single text input

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add localization keys**

Open `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` and add three new string entries (matching the format used by neighbouring keys — copy the JSON shape of an existing simple key like `"Discover"`):

- Key: `"What do you feel like watching?"` — English value: `"What do you feel like watching?"`
- Key: `"Discover"` — already exists (tab name); reuse for the button label, no new key needed.
- Key: `"Describe a mood, a vibe, a director, anything"` — English value: `"Describe a mood, a vibe, a director, anything"`

(Polish translations may already exist for `"Discover"`; the new keys can be English-only for now and translated later. The `loc()` helper falls back to the key string.)

- [ ] **Step 2: Replace `DiscoverPickerView.swift` entirely**

Overwrite `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift` with:

```swift
import SwiftUI

// MARK: - DiscoverPickerView

/// LLM-only Discover picker. A single multi-line text field bound to
/// `viewModel.moodText` is the entire input surface. Submit (Enter or
/// the Discover button) drives the parent's `onSubmit` callback which
/// flips the VM into `.tinder` and triggers a reshuffle.
public struct DiscoverPickerView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let onSubmit: () -> Void

    @FocusState private var inputFocused: Bool

    public init(viewModel: DiscoverViewModel,
                llmAvailable: Bool,
                onSubmit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.llmAvailable = llmAvailable
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Text("What do you feel like watching?", bundle: .module)
                .scaledFont(size: 18, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            TextField(
                "",
                text: $viewModel.moodText,
                prompt: Text("Describe a mood, a vibe, a director, anything", bundle: .module),
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .scaledFont(size: 14)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            .onSubmit(submitIfValid)

            Button(action: submitIfValid) {
                Text("Discover", bundle: .module)
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(submitDisabled || !llmAvailable)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    private var submitDisabled: Bool {
        viewModel.moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitIfValid() {
        guard !submitDisabled, llmAvailable else { return }
        viewModel.userSubmittedMood()
        onSubmit()
    }
}
```

- [ ] **Step 3: Update the picker call site in `DiscoverTabView.swift`**

In `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`, around line 41-49 the `DiscoverPickerView(...)` initializer is called with a `tmdbAvailable:` arg. Remove that argument so the call matches the new signature:

```swift
            case .picker:
                DiscoverPickerView(
                    viewModel: viewModel,
                    llmAvailable: llmAvailable,
                    onSubmit: {
                        withAnimation(.smooth(duration: 0.22)) { viewModel.stage = .tinder }
                        Task { await viewModel.reshuffle() }
                    }
                )
```

Also at the top of `DiscoverTabView.swift`, drop the `let tmdbAvailable: Bool` stored property and the matching init param + assignment — it's no longer consumed by anything.

In `PopoverContentView.swift` around line 257, drop the `tmdbAvailable: <expr>` arg from the `DiscoverTabView(...)` initializer call.

- [ ] **Step 4: Build the package**

```bash
cd Packages/ArrCore && swift build 2>&1 | tail -30; cd ../..
```

Expected: all errors resolve. Build succeeds.

- [ ] **Step 5: Run the full test suite**

```bash
cd Packages/ArrCore && swift test; cd ../..
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift \
        Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(discover): single text-input picker

Replaces the chip/composer/suggestion-cloud picker with one multiline
TextField bound to moodText plus a Discover button. Drops tmdbAvailable
plumbing from the picker + tab view. Submit drives the existing tinder
flow unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Simplify `filterSummaryChip` and `clearAllFilters` in `DiscoverTabView`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`

The tinder top bar shows a summary chip that reflects the active filters. With structured filters gone, the chip should show the truncated mood text, and the × should just clear the mood.

- [ ] **Step 1: Simplify `activeFilterSummary`**

Find `private var activeFilterSummary: String` in `DiscoverTabView.swift` (~line 96). Replace its entire body with:

```swift
    private var activeFilterSummary: String {
        let mood = viewModel.moodText.trimmingCharacters(in: .whitespaces)
        guard !mood.isEmpty else { return "" }
        return mood.count > 40 ? String(mood.prefix(40)) + "\u{2026}" : mood
    }
```

- [ ] **Step 2: Simplify `clearAllFilters`**

Find `private func clearAllFilters()` (~line 193). Replace its body with:

```swift
    private func clearAllFilters() {
        viewModel.moodText = ""
        Task { await viewModel.reshuffle() }
    }
```

- [ ] **Step 3: Build + run full tests**

```bash
cd Packages/ArrCore && swift build && swift test; cd ../..
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift
git commit -m "$(cat <<'EOF'
refactor(discover): mood-only summary chip + clear

Tinder top bar's filter-summary chip now shows only the truncated
mood text; × clears just the mood. Structured filter clears removed
with the structured filter UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: End-to-end smoke

**Files:** none

- [ ] **Step 1: Build the app**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Relaunch**

```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 3: Manual checklist (user-driven)**

Verify in the running app:

- Discover tab opens to the new picker — heading text + a focused text field + a disabled Discover button.
- Typing in the field enables the button.
- Hitting Enter (or clicking Discover) flips to tinder mode with a card.
- The main popover tab bar is visible in picker, tinder, AND in the matched (Your picks) view.
- The tinder top bar shows the truncated prompt as a chip; tapping it returns to the picker with the prompt pre-filled; the × clears the mood.
- Discover button is disabled when the chat provider is not configured (`llmAvailable == false`).

Report any failures back as a bug to fix before moving on.

- [ ] **Step 4: Final commit only if any inline fixups were needed**

If the smoke run uncovered small issues that needed fixing, commit them now with a descriptive message. Otherwise skip.

---

### Task 9 (optional cleanup): Prune dead localization keys

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

The previous picker introduced many strings ("More filters", "Genre", "Decade", per-category labels, "+", "Add a mood", suggestion-row headers, AI starter prompt labels, etc.) that are now unreferenced. Removing them is housekeeping, not correctness.

- [ ] **Step 1: Identify unreferenced keys**

```bash
# For each key in the xcstrings file, grep the Swift sources. Anything
# with zero hits is a candidate for removal.
cd Packages/ArrCore
python3 -c '
import json, subprocess, sys
data = json.load(open("Sources/ArrCore/Resources/Localizable.xcstrings"))
for key in sorted(data.get("strings", {}).keys()):
    res = subprocess.run(
        ["grep", "-rqlE", f"\"{key}\"", "Sources/ArrCore"],
        capture_output=True
    )
    if res.returncode != 0:
        print(key)
'
cd ../..
```

Expected: a list of dead keys.

- [ ] **Step 2: Remove dead keys from the xcstrings JSON**

Open the file and delete the corresponding entries under `"strings"`. Save.

- [ ] **Step 3: Build + tests**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
cd Packages/ArrCore && swift test; cd ../..
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
chore(discover): drop dead localization keys

Removes strings introduced for the old chip composer that no longer
have a Swift caller after the LLM-only rewrite.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (executor: verify before declaring done)

- [ ] `swift test` is green in `Packages/ArrCore`.
- [ ] `xcodebuild ... build` succeeds.
- [ ] App launches; Discover tab works as described in Task 8 Step 3.
- [ ] No references to `SuggestedFilter`, `suggestionsByCategory`, `customMoods`, `selectedPersonNames`, `tmdbMovies`, `tmdbShows`, `hideTabBarDeepInDiscover` anywhere in the package (`git grep` returns 0 hits).
- [ ] No references to `DiscoverLLMPrompt.SuggestedFilters` or `LLMResult` (`git grep` returns 0 hits).
