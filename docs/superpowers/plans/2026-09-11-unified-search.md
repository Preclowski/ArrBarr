# Unified Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the two divergent search surfaces (Queue tab, Library tab; macOS popover + iOS) into one engine, one bar, one results surface, one local-title matcher, one library cache and one detail router — per `docs/superpowers/specs/2026-09-11-unified-search-design.md`. The tabs differ in exactly one input: the **local context** they hand the surface (live queue rows vs the browsed library). Both tabs take over the window while a query is live.

**Architecture:** One `SearchViewModel` instance per root (`PopoverContentView` on macOS, `iOSAppRoot` on iOS), passed into both tabs. The query lives in the VM (`query` gets a `didSet` → `onQueryChange()`); `searchVM.isActive` is the single "a query owns the surface" predicate. `SearchResultsSurface` renders lookup rows deduped against host-supplied `[LocalHit]`. `LibraryIndex` becomes the single fetch-and-cache for all four arrs with a per-source `version(for:)`; `LibraryViewModel` becomes a version-driven projection of it. `DetailRequest.open` owns the "Lidarr artist vs everything else" branch once. `TitleMatch` owns folding and trailing-year splitting; `SearchRelevance` delegates.

**Tech Stack:** Swift 6 tools / language mode v5, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM local packages (`Packages/ArrCore`, `Packages/ArrMCPServer`), Xcode project for the three app targets.

---

## File structure

### Created

| File | Responsibility |
| --- | --- |
| `Packages/ArrCore/Sources/ArrCore/Models/LocalHit.swift` | `LocalHit` (queue row / library entry), `OwnershipKey`, and `LocalHit.queueHits(...)` — the one definition of the queue tab's local context. |
| `Packages/ArrCore/Sources/ArrCore/Views/SearchCapsule.swift` | The macOS floating search capsule: leading icon/spinner, `TextField` bound to `searchVM.query`, clear button, scope + "In library" menu. |
| `Packages/ArrCore/Sources/ArrCore/Views/SearchTakeoverView.swift` | The shared takeover host: pinned "Searching" header (back chevron clears the query) above a `ScrollView` holding the surface and the cold-start spinner. |
| `Packages/ArrCore/Sources/ArrCore/Views/SearchResultsSurface.swift` | Renamed + generalized `QueueSearchResultsView`: local hits → people → primary "Starring X" → merged lookup rows → secondary "Starring X" → settled-empty. (`git mv` from `QueueSearchResultsView.swift`.) |
| `Packages/ArrCore/Tests/ArrCoreTests/LibraryIndexTests.swift` | Version bumps, keep-stale-on-failure, all four sources invalidate. |
| `Packages/ArrCore/Tests/ArrCoreTests/LibraryViewModelTests.swift` | `loadIfNeeded` re-unifies only on a version change; `force` invalidates first. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelQueryTests.swift` | `query` didSet runs the search; empty query resets `scope` exactly once and leaves `libraryOnly` alone. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchClientOwnershipTests.swift` | Lidarr/Whisparr ownership maps come from `ArrLibraryMaps` with the same hash key the lookup rows carry. |

### Modified

| File | Change |
| --- | --- |
| `Packages/ArrCore/Sources/ArrCore/Services/TitleMatch.swift` | Gains `splitTrailingYear(_:)` and `isPlausibleYear(_:)`. |
| `Packages/ArrCore/Sources/ArrCore/Services/SearchRelevance.swift` | `normalize` / `splitYear` / `isPlausibleYear` deleted; delegates to `TitleMatch`. |
| `Packages/ArrCore/Sources/ArrCore/Services/PersonRelevance.swift` | Six `SearchRelevance.normalize` call sites → `TitleMatch.fold`. |
| `Packages/ArrCore/Sources/ArrCore/Services/LibraryIndex.swift` | Artist + Whisparr slots, per-source `version(for:)`, `fetchFailed(_:)`, invalidate for all four sources. |
| `Packages/ArrCore/Sources/ArrCore/Services/ArrLibraryMaps.swift` | `lidarrByForeignArtistHash`, `whisparrByForeignId`, `foreignHashKey`. |
| `Packages/ArrCore/Sources/ArrCore/Services/SearchClient.swift` | `fetchLibraryOwnership` reads all four maps from `ArrLibraryMaps`; the direct `/artist` + `/movie` fetches go; unify helpers use `ArrLibraryMaps.foreignHashKey`. |
| `Packages/ArrCore/Sources/ArrCore/Services/AppNotifications.swift` | `DetailRequest.open(...)`; `tap` delegates to it. |
| `Packages/ArrCore/Sources/ArrCore/ViewModels/LibraryViewModel.swift` | Projection of `LibraryIndex`; `fetchedAt`/`ttl` deleted. |
| `Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift` | `query` didSet, `isActive`, non-re-entrant scope reset, `navigateToAdded` → `DetailRequest.open`, add* invalidate all four sources. |
| `Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift` | One `removingLocalDuplicates`; the two old functions deleted. |
| `Packages/ArrCore/Sources/ArrCore/Views/QueueTabContent.swift` | Filter bar / scope menu / takeover extracted; binds to the shared VM query. |
| `Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift` | Private `searchVM`, `filterText`, `filterBar`, `remoteResults`, `lookupSection`, `trimmedFilter` deleted; shared VM, takeover, `SearchCapsule` / `SearchField`. |
| `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` | `queueFilter`, `queueScope`, `isFiltering` deleted; tab bar hides for Queue **and** Library; focus both. |
| `Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift` | `QueueSearchField` → shared `SearchField`; `QueueTab`/`LibraryTab` rewired; the `onChange(of: searchVM.query)` mirror deleted. |
| `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` | `queue.searching.button` → `search.searching.header`; `search.searchMoviesAndTv.label` and `library.moreResults.header` removed. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift` | Rewritten for `removingLocalDuplicates`. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchRelevanceTests.swift` | `normalize`/`splitYear` assertions retargeted at `TitleMatch`. |
| `Packages/ArrCore/Tests/ArrCoreTests/LibrarySearchTests.swift` | `TitleMatchTests` gains `splitTrailingYear` + width-insensitivity cases. |
| `Packages/ArrCore/Tests/ArrCoreTests/DirectorCreditsTests.swift` | One `SearchRelevance.normalize` call → `TitleMatch.fold`. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelCancellationTests.swift` | Drops the now-redundant explicit `onQueryChange()` calls. |
| `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelStaleResultsTests.swift` | Same. |

### Deleted

| File | Reason |
| --- | --- |
| `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift` | `git mv`'d to `SearchResultsSurface.swift`. |

---

## Task 1: TitleMatch owns folding and year splitting

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/TitleMatch.swift` (add after `normalize`, ~line 83)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SearchRelevance.swift` (delete lines 55–71 `normalize`, 233–264 `splitYear`/`isPlausibleYear`; retarget call sites at lines 79, 273, 310)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/PersonRelevance.swift` (lines 14, 35, 48, 53, 69, 71)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibrarySearchTests.swift` (extend `TitleMatchTests`)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchRelevanceTests.swift` (lines 37–44, 366–368, 445–500)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/DirectorCreditsTests.swift` (line 105)

- [ ] **Step 1: Write the TitleMatch year tests first.** Append to `TitleMatchTests` in `LibrarySearchTests.swift`:

```swift
    @Test("A trailing year splits off; a title that IS a year does not")
    func splitsTrailingYear() {
        // "1917" is the film, not an empty query filtered to 1917.
        #expect(TitleMatch.splitTrailingYear("1917").year == nil)
        #expect(TitleMatch.splitTrailingYear("1917").query == "1917")

        let dune = TitleMatch.splitTrailingYear("dune 2024")
        #expect(dune.query == "dune")
        #expect(dune.year == 2024)

        // Leading years are part of the title — scanning the whole query
        // would bury Kubrick under a 2001 release-year filter.
        let odyssey = TitleMatch.splitTrailingYear("2001 a space odyssey")
        #expect(odyssey.query == "2001 a space odyssey")
        #expect(odyssey.year == nil)

        // 2049 is not a plausible release year, so the title keeps its last word.
        #expect(TitleMatch.splitTrailingYear("blade runner 2049").year == nil)
        #expect(TitleMatch.splitTrailingYear("blade runner 2049").query == "blade runner 2049")
    }

    @Test("isPlausibleYear brackets 1880…(now + 5)")
    func plausibleYearBounds() {
        let now = Calendar.current.component(.year, from: Date())
        #expect(TitleMatch.isPlausibleYear("1880"))
        #expect(TitleMatch.isPlausibleYear(Substring(String(now))))
        #expect(!TitleMatch.isPlausibleYear("1879"))
        #expect(!TitleMatch.isPlausibleYear(Substring(String(now + 6))))
        #expect(!TitleMatch.isPlausibleYear("24"))
        #expect(!TitleMatch.isPlausibleYear("20x4"))
    }

    @Test("fold is width-insensitive as well as accent- and punctuation-insensitive")
    func foldIsWidthInsensitive() {
        // Full-width Latin (a Japanese release title's ASCII half) folds to
        // the same tokens the user types on a normal keyboard.
        #expect(TitleMatch.fold("ＡＫＩＲＡ") == "akira")
        #expect(TitleMatch.fold("Spider-Man: No Way Home") == "spider man no way home")
        #expect(TitleMatch.fold("WALL·E") == "wall e")
    }
```

- [ ] **Step 2: Run the tests and watch them fail to compile.** `(cd Packages/ArrCore && swift test --filter TitleMatchTests)` — expected: build error, `splitTrailingYear` / `isPlausibleYear` are not members of `TitleMatch`.

- [ ] **Step 3: Add the year helpers to `TitleMatch`.** Insert after `normalize`'s `articles` set (~line 87):

```swift
    // MARK: - Year disambiguation

    /// Splits a folded query into "the words to match on" and "the year the
    /// user typed", when there is one.
    ///
    /// Two guards, both load-bearing:
    ///
    ///   - **Trailing token only.** People type the year after the title
    ///     ("dune 2024"), never before it. Scanning the whole query would
    ///     read "2001 A Space Odyssey" as a 2001 film — and since a year
    ///     mismatch is a heavy demotion downstream, that would bury the one
    ///     record the user actually wanted.
    ///   - **Never the only token.** `1917` stays a search for the FILM
    ///     rather than an empty query with a year attached.
    public static func splitTrailingYear(_ foldedQuery: String) -> (query: String, year: Int?) {
        var tokens = foldedQuery.split(separator: " ")
        guard tokens.count > 1, let last = tokens.last, isPlausibleYear(last) else {
            return (foldedQuery, nil)
        }
        let year = Int(tokens.removeLast())
        return (tokens.joined(separator: " "), year)
    }

    /// 1880…(this year + 5). The upper bound is what keeps "Blade Runner
    /// 2049" intact — 2049 is not a plausible release year, so the title
    /// keeps its last word instead of being read as a year filter.
    public static func isPlausibleYear(_ token: Substring) -> Bool {
        guard token.count == 4, let n = Int(token) else { return false }
        let currentYear = Calendar.current.component(.year, from: Date())
        return n >= 1880 && n <= currentYear + 5
    }
```

- [ ] **Step 4: Run the TitleMatch tests.** `(cd Packages/ArrCore && swift test --filter TitleMatchTests)` — expected: all pass, including the pre-existing normalization/filter cases.

- [ ] **Step 5: Point `SearchRelevance` at `TitleMatch`.** Delete `SearchRelevance.normalize` (the whole `static func normalize` body, lines 55–71 including its doc comment), and delete `splitYear` + `isPlausibleYear` (lines 233–264, keeping the `// MARK: - Year disambiguation` comment out of the file since the section now lives in `TitleMatch`). Then update the three remaining uses:

  - In `score(_:normalizedQuery:)`, line 79: `let title = TitleMatch.fold(result.title)`
  - In `rank(_:against:)`, `.text` case: `let (text, year) = TitleMatch.splitTrailingYear(TitleMatch.fold(q))`
  - In `sortedByRelevance(_:input:)`, `.text` case: `let normalized = TitleMatch.fold(q)`

  And replace the doc line that referenced `splitYear` (inside `yearMismatchPenalty`'s comment) with:

```swift
    /// Only safe because `TitleMatch.splitTrailingYear` reads the TRAILING
    /// token only, so "2001 a space odyssey" is never mistaken for a
    /// year-qualified query and demoted to nothing.
```

  Also update the enum's own doc line to say the folding lives in `TitleMatch`:

```swift
/// Diacritic-, case-, width- and punctuation-insensitive throughout (the fold
/// is `TitleMatch.fold`, shared with the library filter), so "spiderman"
/// reaches "Spider-Man" and "pozeracz" reaches "Pożeracz".
```

- [ ] **Step 6: Point `PersonRelevance` at `TitleMatch.fold`.** In `Services/PersonRelevance.swift` replace every `SearchRelevance.normalize(` with `TitleMatch.fold(` (lines 14, 35, 48, 53, 69, 71) and fix the doc comment on line 9 to read `reusing TitleMatch.fold`. `TitleMatch.fold` is a strict superset of the old normalizer (same punctuation-to-space rule, plus width insensitivity), so person ranking is unchanged for every input the old one handled.

- [ ] **Step 7: Retarget the existing tests.** In `SearchRelevanceTests.swift` replace `SearchRelevance.normalize(` → `TitleMatch.fold(` (lines 37, 38, 43, 44, 366, 367, 368) and `SearchRelevance.splitYear(` → `TitleMatch.splitTrailingYear(` (lines 445, 446, 452, 488, 500). In `DirectorCreditsTests.swift` line 105, `let q = TitleMatch.fold("nolan")`.

- [ ] **Step 8: Run the full suite.** `(cd Packages/ArrCore && swift test)` — expected: every test passes, `SearchRelevance` no longer declares `normalize`, `splitYear` or `isPlausibleYear`.

- [ ] **Step 9: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/TitleMatch.swift \
        Packages/ArrCore/Sources/ArrCore/Services/SearchRelevance.swift \
        Packages/ArrCore/Sources/ArrCore/Services/PersonRelevance.swift \
        Packages/ArrCore/Tests/ArrCoreTests/LibrarySearchTests.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchRelevanceTests.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DirectorCreditsTests.swift
git commit -m "refactor(search): one title fold, one year split

TitleMatch owns fold + splitTrailingYear; SearchRelevance and
PersonRelevance delegate instead of carrying a second normalizer.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 2: LibraryIndex caches all four arrs and carries a version

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LibraryIndex.swift` (whole file)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibraryIndexTests.swift` (create)

- [ ] **Step 1: Write `LibraryIndexTests.swift` first.**

```swift
import Testing
import Foundation
@testable import ArrCore

/// Stubs one host so suites running in parallel keep their own traffic, and
/// counts `/movie` hits so "did it refetch?" is an assertion rather than a
/// guess. Each test uses its own port: `LibraryIndex` keys every slot on the
/// config fingerprint, so a distinct base URL is a distinct cache.
private final class LibraryIndexStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    private var _failing = false

    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
    }
    func countMovie() { lock.lock(); defer { lock.unlock() }; _movieHits += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; _movieHits = 0; _failing = false }
}

private final class LibraryIndexStub: URLProtocol, @unchecked Sendable {
    static let state = LibraryIndexStubState()
    static let host = "libraryindex.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        if url.path.contains("/movie") { Self.state.countMovie() }
        if Self.state.failing {
            let response = HTTPURLResponse(url: url, statusCode: 500,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("boom".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Data(#"[{"id":1,"tmdbId":603,"title":"The Matrix","hasFile":true}]"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LibraryIndex", .serialized)
struct LibraryIndexTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(LibraryIndexStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A fresh commit bumps the source's version; a cache hit does not")
    func versionBumpsOnCommit() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17101)
        #expect(await index.version(for: .radarr) == 0)

        let first = await index.movies(config: cfg)
        #expect(first.count == 1)
        #expect(await index.version(for: .radarr) == 1)

        // Second read is served from the slot — no request, no bump.
        _ = await index.movies(config: cfg)
        #expect(await index.version(for: .radarr) == 1)
        #expect(LibraryIndexStub.state.movieHits == 1)
    }

    @Test("Invalidate bumps the version and forces the next read to refetch")
    func invalidateBumpsAndRefetches() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17102)
        _ = await index.movies(config: cfg)
        await index.invalidate(.radarr)
        #expect(await index.version(for: .radarr) == 2)

        _ = await index.movies(config: cfg)
        #expect(LibraryIndexStub.state.movieHits == 2)
        #expect(await index.version(for: .radarr) == 3)
    }

    @Test("A failed refetch keeps the stale snapshot and does not bump")
    func failedRefetchKeepsStale() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17103)
        _ = await index.movies(config: cfg)
        let afterFirst = await index.version(for: .radarr)

        await index.invalidate(.radarr)
        let afterInvalidate = await index.version(for: .radarr)
        LibraryIndexStub.state.failing = true

        // A momentarily unreachable arr must not read as "your library is
        // empty" — that is "you own nothing" everywhere downstream.
        let stale = await index.movies(config: cfg)
        #expect(stale.count == 1)
        #expect(await index.version(for: .radarr) == afterInvalidate)
        #expect(afterInvalidate == afterFirst + 1)
        #expect(await index.fetchFailed(.radarr))
    }

    @Test("All four sources have a version and all four invalidate")
    func allFourSourcesInvalidate() async {
        let index = LibraryIndex()
        for source in QueueItem.Source.allCases {
            #expect(await index.version(for: source) == 0)
            await index.invalidate(source)
            #expect(await index.version(for: source) == 1)
        }
    }
}
```

- [ ] **Step 2: Run and watch it fail.** `(cd Packages/ArrCore && swift test --filter LibraryIndexTests)` — expected: build error, `version(for:)` / `fetchFailed(_:)` do not exist and `.lidarr`/`.whisparr` do not invalidate.

- [ ] **Step 3: Rewrite `LibraryIndex` reads as one generic committer.** Replace the storage and the two read methods with:

```swift
    private var movieSlot: Slot<RadarrLibraryRecord>?
    private var seriesSlot: Slot<SonarrLibraryRecord>?
    private var artistSlot: Slot<LidarrLibraryRecord>?
    private var whisparrSlot: Slot<WhisparrLibraryRecord>?
    /// One in-flight fetch per source. Without it, three tools called in the
    /// same turn each start their own fetch of a cold cache.
    private var movieFetch: Task<[RadarrLibraryRecord]?, Never>?
    private var seriesFetch: Task<[SonarrLibraryRecord]?, Never>?
    private var artistFetch: Task<[LidarrLibraryRecord]?, Never>?
    private var whisparrFetch: Task<[WhisparrLibraryRecord]?, Never>?

    /// Monotonic per-source counter, bumped on every fresh commit and every
    /// invalidate. `LibraryViewModel` unifies against it: same version means
    /// the records behind it are the same objects, so re-unifying a 3000-title
    /// library would be pure waste.
    private var versions: [QueueItem.Source: Int] = [:]
    /// True when the LAST fetch for a source threw. The reads return `[]` (or
    /// a stale snapshot) either way, so this is the only thing that can tell
    /// "the arr is unreachable" from "the library is genuinely empty" — the
    /// Library tab's error state depends on the difference.
    private var failedSources: Set<QueueItem.Source> = []

    public func version(for source: QueueItem.Source) -> Int { versions[source] ?? 0 }

    public func fetchFailed(_ source: QueueItem.Source) -> Bool {
        failedSources.contains(source)
    }
```

- [ ] **Step 4: Write the four reads against one shared commit rule.** Replace `movies(config:)` and `series(config:)` and add the two new ones:

```swift
    public func movies(config: ServiceConfig) async -> [RadarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = movieSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = movieFetch { return commit(await inFlight.value, .radarr, &movieSlot, fingerprint) }
        let task = Task<[RadarrLibraryRecord]?, Never> {
            try? await RadarrClient(config: config).fetchAllMovies()
        }
        movieFetch = task
        let records = await task.value
        movieFetch = nil
        let out = commit(records, .radarr, &movieSlot, fingerprint)
        LibraryStats.shared.setMovieCount(out.count)
        return out
    }

    public func series(config: ServiceConfig) async -> [SonarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = seriesSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = seriesFetch { return commit(await inFlight.value, .sonarr, &seriesSlot, fingerprint) }
        let task = Task<[SonarrLibraryRecord]?, Never> {
            try? await SonarrClient(config: config).fetchAllSeries()
        }
        seriesFetch = task
        let records = await task.value
        seriesFetch = nil
        let out = commit(records, .sonarr, &seriesSlot, fingerprint)
        LibraryStats.shared.setSeriesCount(out.count)
        return out
    }

    /// Lidarr artists. Same slot / in-flight / TTL / keep-stale-on-failure
    /// rules as movies and series — the Library grid and search ownership now
    /// read the artist list from here instead of fetching it twice.
    public func artists(config: ServiceConfig) async -> [LidarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = artistSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = artistFetch { return commit(await inFlight.value, .lidarr, &artistSlot, fingerprint) }
        let task = Task<[LidarrLibraryRecord]?, Never> {
            try? await LidarrClient(config: config).fetchAllArtists()
        }
        artistFetch = task
        let records = await task.value
        artistFetch = nil
        return commit(records, .lidarr, &artistSlot, fingerprint)
    }

    /// Whisparr scenes/movies — same rules again.
    public func whisparrMovies(config: ServiceConfig) async -> [WhisparrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = whisparrSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = whisparrFetch { return commit(await inFlight.value, .whisparr, &whisparrSlot, fingerprint) }
        let task = Task<[WhisparrLibraryRecord]?, Never> {
            try? await WhisparrClient(config: config).fetchAllMovies()
        }
        whisparrFetch = task
        let records = await task.value
        whisparrFetch = nil
        return commit(records, .whisparr, &whisparrSlot, fingerprint)
    }

    /// One commit rule for all four sources.
    ///
    /// `nil` means the fetch threw. A failed fetch keeps whatever we had — a
    /// momentarily unreachable arr must not turn into "your library is empty",
    /// which reads as "you own nothing" everywhere downstream — and leaves the
    /// version where it was, so nobody downstream re-unifies for nothing.
    /// An empty-but-successful fetch IS a commit: a genuinely empty library is
    /// an answer, not a failure.
    private func commit<Record: Sendable>(
        _ records: [Record]?,
        _ source: QueueItem.Source,
        _ slot: inout Slot<Record>?,
        _ fingerprint: String
    ) -> [Record] {
        guard let records else {
            failedSources.insert(source)
            if let slot, slot.fingerprint == fingerprint { return slot.records }
            return []
        }
        failedSources.remove(source)
        slot = Slot(records: records, fetchedAt: Date(), fingerprint: fingerprint)
        versions[source, default: 0] += 1
        return records
    }
```

- [ ] **Step 5: Make `invalidate` cover all four sources and bump.** Replace `invalidate(_:)`:

```swift
    /// Expire a source's snapshot. Called when an import lands and after the
    /// app itself changes library state, so the next answer can't contradict
    /// the action the user just watched happen.
    ///
    /// The slot is EXPIRED rather than dropped: the next read refetches, and
    /// if that refetch fails the stale records are still there to fall back
    /// on. Dropping it would turn "the arr is down right after an add" into an
    /// empty library.
    public func invalidate(_ source: QueueItem.Source) {
        switch source {
        case .radarr:   movieSlot?.fetchedAt = .distantPast
        case .sonarr:   seriesSlot?.fetchedAt = .distantPast
        case .lidarr:   artistSlot?.fetchedAt = .distantPast
        case .whisparr: whisparrSlot?.fetchedAt = .distantPast
        }
        versions[source, default: 0] += 1
    }
```

  `Slot.fetchedAt` is already a `var`, so no change to the struct is needed.

- [ ] **Step 6: Run the tests.** `(cd Packages/ArrCore && swift test --filter LibraryIndexTests)` — expected: all four tests pass. Then `(cd Packages/ArrCore && swift test)` — expected: the whole suite still passes (the existing `ArrLibraryMaps` and chat-tool call sites are source-compatible).

- [ ] **Step 7: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/LibraryIndex.swift \
        Packages/ArrCore/Tests/ArrCoreTests/LibraryIndexTests.swift
git commit -m "feat(library): LibraryIndex caches all four arrs and carries a version

Artist + Whisparr slots on the same rules as movies/series, a per-source
version bumped on commit and on invalidate, and a fetchFailed flag so an
unreachable arr can be told from an empty library.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 3: Ownership maps for Lidarr and Whisparr read the index

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ArrLibraryMaps.swift` (append)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SearchClient.swift` (lines 138–182 `fetchLibraryOwnership`; lines 528, 559, 598 hash sites)
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift` (`addArtist`, `addAlbum`, `addScene`)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchClientOwnershipTests.swift` (create)

- [ ] **Step 1: Write `SearchClientOwnershipTests.swift` first.**

```swift
import Testing
import Foundation
@testable import ArrCore

/// Lidarr and Whisparr ownership used to come from two hand-rolled fetches
/// inside `SearchClient`. They now read the shared `LibraryIndex` through
/// `ArrLibraryMaps` — and the key has to stay byte-identical to the one the
/// lookup rows carry, or every owned artist silently reads as addable.
private final class OwnershipStub: URLProtocol, @unchecked Sendable {
    static let host = "ownership.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        let body: String
        if url.path.contains("/artist") {
            body = #"[{"id":11,"foreignArtistId":"mbid-radiohead","artistName":"Radiohead","monitored":true,"statistics":{"trackCount":10,"trackFileCount":10}}]"#
        } else if url.path.contains("/movie") {
            body = #"[{"id":22,"foreignId":"scene-abc","tmdbId":0,"title":"Scene","hasFile":true}]"#
        } else {
            body = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Search ownership maps", .serialized)
struct SearchClientOwnershipTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(OwnershipStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("Lidarr ownership is keyed by the same foreign hash the lookup rows carry")
    func lidarrOwnershipKey() async throws {
        URLProtocol.registerClass(OwnershipStub.self)
        defer { URLProtocol.unregisterClass(OwnershipStub.self) }

        let cfg = config(port: 17201)
        let map = await ArrLibraryMaps.lidarrByForeignArtistHash(config: cfg)
        let key = ArrLibraryMaps.foreignHashKey("mbid-radiohead")
        #expect(map[key]?.arrId == 11)
        #expect(map[key]?.isDownloaded == true)

        // The row side computes the very same key.
        let row = SearchClient.unifyLidarr(
            LidarrLookupRecord.testRecord(foreignArtistId: "mbid-radiohead", artistName: "Radiohead"),
            baseURL: cfg.baseURL)
        #expect(row?.externalId == key)
    }

    @Test("Whisparr ownership prefers tmdbId and falls back to the foreign hash")
    func whisparrOwnershipKey() async throws {
        URLProtocol.registerClass(OwnershipStub.self)
        defer { URLProtocol.unregisterClass(OwnershipStub.self) }

        let cfg = config(port: 17202)
        let map = await ArrLibraryMaps.whisparrByForeignId(config: cfg)
        // tmdbId is 0 on this record, so the foreign hash is the key.
        let key = ArrLibraryMaps.foreignHashKey("scene-abc")
        #expect(map[key]?.arrId == 22)
        #expect(map[key]?.isDownloaded == true)
    }

    @Test("An unconfigured arr yields an empty map rather than a request")
    func unconfiguredIsEmpty() async {
        #expect(await ArrLibraryMaps.lidarrByForeignArtistHash(config: .empty).isEmpty)
        #expect(await ArrLibraryMaps.whisparrByForeignId(config: .empty).isEmpty)
    }
}

private extension LidarrLookupRecord {
    /// The decoder is the only initialiser on the wire type, so the test
    /// builds one through it.
    static func testRecord(foreignArtistId: String, artistName: String) -> LidarrLookupRecord {
        let json = #"{"foreignArtistId":"\#(foreignArtistId)","artistName":"\#(artistName)"}"#
        return try! JSONDecoder().decode(LidarrLookupRecord.self, from: Data(json.utf8))
    }
}
```

  If `LidarrLookupRecord` requires more non-optional fields than `artistName`, extend the JSON literal to satisfy the decoder — read the struct in `Models/ArrTypes.swift` before writing this helper.

- [ ] **Step 2: Run and watch it fail.** `(cd Packages/ArrCore && swift test --filter SearchClientOwnershipTests)` — expected: build error, `lidarrByForeignArtistHash` / `whisparrByForeignId` / `foreignHashKey` do not exist.

- [ ] **Step 3: Add the maps to `ArrLibraryMaps`.** Append inside the enum:

```swift
    /// Stable positive `Int` key for a foreign STRING id (a MusicBrainz artist
    /// id, a Whisparr scene's `foreignId`). `SearchResult.externalId` is an
    /// Int, so the string ids get hashed into it — this is the one definition
    /// of that rule, and both sides of the ownership join must call it or
    /// every owned artist reads as addable.
    ///
    /// `hashValue` is not stable across process launches; it does not have to
    /// be. Both sides compute it in the same process, and nothing persists it.
    public static func foreignHashKey(_ foreignId: String) -> Int {
        abs(foreignId.hashValue) & 0x7fffffff
    }

    /// Lidarr: `hash(foreignArtistId) → ownership`, off the shared snapshot.
    public static func lidarrByForeignArtistHash(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.artists(config: config) {
            if let fid = rec.foreignArtistId, let owned = rec.ownership {
                map[foreignHashKey(fid)] = owned
            }
        }
        return map
    }

    /// Whisparr: `tmdbId → ownership`, falling back to `hash(foreignId)` for
    /// the scene records that carry no TMDB id. Matches what
    /// `SearchClient.unifyWhisparr` stamps on the lookup rows.
    public static func whisparrByForeignId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.whisparrMovies(config: config) {
            let key: Int? = {
                if let tmdbId = rec.tmdbId, tmdbId != 0 { return tmdbId }
                if let fid = rec.foreignId { return foreignHashKey(fid) }
                return nil
            }()
            if let key, let owned = rec.ownership { map[key] = owned }
        }
        return map
    }
```

- [ ] **Step 4: Collapse `SearchClient.fetchLibraryOwnership` to four map reads.** Replace the whole method (and its doc comment):

```swift
    /// `foreignId → LibraryOwnership` for everything in the user's library:
    /// the arr record a row deep-links into, and whether it's downloaded (the
    /// ownership chip). The key matches what `SearchResult.externalId`
    /// carries for each source.
    ///
    /// All four sources read the shared `LibraryIndex` snapshot through
    /// `ArrLibraryMaps` — the same maps chat, Quiz and filmography use — so a
    /// search never pulls a whole library of its own.
    func fetchLibraryOwnership() async throws -> [Int: LibraryOwnership] {
        if DemoMode.isActive { return [:] }
        guard config.isConfigured else { return [:] }
        switch source {
        case .radarr:   return await ArrLibraryMaps.radarrByTMDBId(config: config)
        case .sonarr:   return await ArrLibraryMaps.sonarrByTVDBId(config: config)
        case .lidarr:   return await ArrLibraryMaps.lidarrByForeignArtistHash(config: config)
        case .whisparr: return await ArrLibraryMaps.whisparrByForeignId(config: config)
        }
    }
```

- [ ] **Step 5: Route the three unify hash sites through the one rule.** In `SearchClient.swift` replace `abs(fid.hashValue) & 0x7fffffff` / `abs(foreign.hashValue) & 0x7fffffff` at lines ~528 (`unifyWhisparr`), ~559 (`unifyLidarrAlbum`) and ~598 (`unifyLidarr`) with `ArrLibraryMaps.foreignHashKey(fid)` / `ArrLibraryMaps.foreignHashKey(foreign)`. Grep afterwards: `grep -rn "0x7fffffff" Packages/ArrCore/Sources` must return exactly one line, inside `ArrLibraryMaps.foreignHashKey`.

- [ ] **Step 6: Invalidate the right source after every add.** In `SearchViewModel.swift`:

  - `addScene`, after `whisparrResults.removeAll { $0.id == result.id }`:

```swift
            // Search reads ownership from the index; without this the title
            // just added would read as addable until `LibraryIndex.ttl`, and
            // the Library grid would keep it "not owned" until its next load.
            await LibraryIndex.shared.invalidate(.whisparr)
```

  - `addArtist`, after `lidarrResults.removeAll { $0.id == result.id }`:

```swift
            await LibraryIndex.shared.invalidate(.lidarr)
```

  - `addAlbum`, after `lidarrResults.removeAll { $0.id == result.id }`: the same `await LibraryIndex.shared.invalidate(.lidarr)` (an album add creates the artist too).

  `addMovie` and `addSeries` already invalidate; leave them, but move the explanatory comment on `addMovie` up to the first occurrence so it is not repeated four times.

- [ ] **Step 7: Run the tests.** `(cd Packages/ArrCore && swift test --filter SearchClientOwnershipTests)` — expected: three tests pass. Then `(cd Packages/ArrCore && swift test)` — expected: whole suite green.

- [ ] **Step 8: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ArrLibraryMaps.swift \
        Packages/ArrCore/Sources/ArrCore/Services/SearchClient.swift \
        Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchClientOwnershipTests.swift
git commit -m "refactor(search): Lidarr/Whisparr ownership reads the shared index

ArrLibraryMaps owns the foreign-id hash rule and both new maps; SearchClient
stops fetching /artist and /movie of its own, and every add invalidates its
own source.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 4: LibraryViewModel becomes a projection of LibraryIndex

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/LibraryViewModel.swift` (lines 119–204)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibraryViewModelTests.swift` (create)

- [ ] **Step 1: Write `LibraryViewModelTests.swift` first.**

```swift
import Testing
import Foundation
@testable import ArrCore

/// The grid used to keep its own 5-minute TTL, so an add invalidated the
/// ownership index and the grid went on showing "not owned" for minutes. It
/// now re-unifies exactly when `LibraryIndex.version(for:)` moves.
private final class LibraryVMStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    func countMovie() { lock.lock(); defer { lock.unlock() }; _movieHits += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; _movieHits = 0 }
}

private final class LibraryVMStub: URLProtocol, @unchecked Sendable {
    static let state = LibraryVMStubState()
    static let host = "libraryvm.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        let body: String
        if url.path.hasSuffix("/movie") {
            Self.state.countMovie()
            body = #"[{"id":1,"tmdbId":603,"title":"The Matrix","year":1999,"hasFile":true,"monitored":true}]"#
        } else {
            // qualityprofile, alttitle, anything else the load touches.
            body = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LibraryViewModel", .serialized)
@MainActor
struct LibraryViewModelTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(LibraryVMStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A second load with an unchanged index version does not refetch")
    func stableVersionSkipsReload() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17301)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.entries[.radarr]?.count == 1)
        #expect(LibraryVMStub.state.movieHits == 1)

        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(LibraryVMStub.state.movieHits == 1)
    }

    @Test("Invalidating the index makes the next load re-unify")
    func versionChangeTriggersReload() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17302)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await LibraryIndex.shared.invalidate(.radarr)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(LibraryVMStub.state.movieHits == 2)
        #expect(vm.entries[.radarr]?.count == 1)
    }

    @Test("force invalidates the index first, so ⌘R really refetches")
    func forceInvalidatesFirst() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17303)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await vm.loadIfNeeded(source: .radarr, config: cfg, force: true)
        #expect(LibraryVMStub.state.movieHits == 2)
    }

    @Test("An unreachable arr with nothing cached sets loadFailed")
    func unreachableSetsLoadFailed() async {
        // No stub registered for this host at all, so every request errors.
        let vm = LibraryViewModel()
        let cfg = ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                apiKey: "k", username: "", password: "")
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.loadFailed.contains(.radarr))
        #expect(vm.entries[.radarr] == nil)
    }
}
```

- [ ] **Step 2: Run and watch it fail.** `(cd Packages/ArrCore && swift test --filter LibraryViewModelTests)` — expected: `stableVersionSkipsReload` fails (the TTL, not the version, gates the reload) and `forceInvalidatesFirst` fails (force does not touch the index).

- [ ] **Step 3: Replace the TTL fields with recorded index versions.** In `LibraryViewModel`, delete:

```swift
    private var fetchedAt: [QueueItem.Source: Date] = [:]
    private let ttl: TimeInterval = 300
```

  and put in their place:

```swift
    /// The `LibraryIndex` version each source's `entries` were unified from.
    /// The grid is a PROJECTION of the index, not a second cache: it re-unifies
    /// when — and only when — the index says its records changed. The old
    /// 5-minute TTL of its own is what made an add read "not owned" in the grid
    /// for minutes after the index already knew better.
    private var indexVersions: [QueueItem.Source: Int] = [:]
```

- [ ] **Step 4: Rewrite `loadIfNeeded`.**

```swift
    /// Project `source`'s library into grid entries if the index moved under
    /// us (or we have nothing yet). `force` expires the index first, so ⌘R is
    /// a real refetch and not a re-unify of the same records.
    public func loadIfNeeded(source: QueueItem.Source, config: ServiceConfig, force: Bool = false) async {
        if force { await LibraryIndex.shared.invalidate(source) }
        if !force,
           entries[source] != nil,
           indexVersions[source] == await LibraryIndex.shared.version(for: source) {
            return
        }
        guard !loading.contains(source) else { return }
        loading.insert(source)
        loadFailed.remove(source)
        defer { loading.remove(source) }

        // Profile names resolve qualityProfileId → "HD-1080p" for rows without
        // a file (and for Sonarr/Lidarr, which have no single file). One cheap
        // call. Failure degrades to no quality caption, not a failed load.
        let profiles = await SearchClient.profileNameMap(config: config, source: source)
        let fresh: [LibraryEntry]
        switch source {
        case .radarr:
            let movies = await LibraryIndex.shared.movies(config: config)
            // Alternate titles are what let the filter find a film by its
            // Polish or German name. Best-effort, and only paid when the movie
            // list actually changed — reaching this line at all means the
            // index version moved.
            let alts = await RadarrClient(config: config).alternateTitleMap(for: movies)
            fresh = Self.unify(movies, baseURL: config.baseURL, profiles: profiles, alternateTitles: alts)
        case .sonarr:
            fresh = Self.unify(await LibraryIndex.shared.series(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        case .lidarr:
            fresh = Self.unify(await LibraryIndex.shared.artists(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        case .whisparr:
            fresh = Self.unify(await LibraryIndex.shared.whisparrMovies(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        }

        // The index swallows the error and hands back a stale snapshot (or
        // nothing). Keep any stale cache on screen; the flag only surfaces an
        // error state when there is nothing at all to show. That quietness is
        // right for the UI and wrong for diagnosis, so the failure is said out
        // loud in the log.
        if await LibraryIndex.shared.fetchFailed(source) {
            Self.log.error("\(source.rawValue, privacy: .public) library load failed — index reports an unreachable arr")
            if entries[source] == nil {
                loadFailed.insert(source)
                return
            }
        }

        entries[source] = fresh
        sortCache[source] = nil
        // Pre-warm the default axis so the first Library visit after a fetch
        // renders without paying the sort inside body.
        _ = sorted(source, cacheKey: "title", using: Self.titleAscending)
        indexVersions[source] = await LibraryIndex.shared.version(for: source)
        Self.logAliasCoverage(fresh, source: source)
    }
```

  The `do`/`catch` goes with it — none of the index reads throw.

- [ ] **Step 5: Run the tests.** `(cd Packages/ArrCore && swift test --filter LibraryViewModelTests)` — expected: four tests pass. Then `(cd Packages/ArrCore && swift test)` — expected: whole suite green.

- [ ] **Step 6: Build and relaunch the app** (this changes what the Library grid loads, even though no view changed):

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual check: open Library, switch arrs, ⌘R — the grid still fills for every configured arr.

- [ ] **Step 7: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/LibraryViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/LibraryViewModelTests.swift
git commit -m "refactor(library): the grid is a projection of LibraryIndex

One library cache instead of two. loadIfNeeded re-unifies on an index
version change; force invalidates first. The grid's own TTL is gone, and
with it the minutes-long 'not owned' window after an add.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 5: One detail router — `DetailRequest.open`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/AppNotifications.swift` (`DetailRequest`, lines ~116–158)
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift` (`navigateToAdded`, `addAlbum`)
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift` (`LibraryEntry.openDetail`, lines ~765–788)

- [ ] **Step 1: Add `open` to `DetailRequest`.** Insert above `tap(_:)`:

```swift
    /// The one place that knows "a Lidarr ARTIST is not a Lidarr ALBUM".
    ///
    /// Lidarr's addable/search entity is the artist, so an artist id handed to
    /// the album-shaped `DetailView` fetched `/album/{artistId}` and landed on
    /// an unrelated record. Three call sites each carried their own copy of
    /// that branch; this is it, once.
    public static func open(source: QueueItem.Source, arrId: Int, title: String,
                            posterURL: URL? = nil, posterRequiresAuth: Bool = false,
                            isLidarrAlbum: Bool = false) {
        if source == .lidarr, !isLidarrAlbum {
            post(syntheticArtistItem(artistId: arrId, name: title,
                                     posterURL: posterURL,
                                     posterRequiresAuth: posterRequiresAuth))
            return
        }
        post(syntheticItem(source: source, entityId: arrId, title: title,
                           posterURL: posterURL,
                           posterRequiresAuth: posterRequiresAuth))
    }
```

- [ ] **Step 2: Make `tap` delegate.** Replace the body of `tap(_:)`:

```swift
    public static func tap(_ result: SearchResult) {
        guard let arrId = result.inLibraryArrId else {
            SearchAddRequest.post(result)
            return
        }
        // Library-side rows came through `fetchLibraryOwnership`, which
        // doesn't require auth on poster URLs (they resolve against the arr's
        // own image cache via public CDN paths).
        open(source: result.source, arrId: arrId, title: result.title,
             posterURL: result.posterURL, posterRequiresAuth: false,
             isLidarrAlbum: result.isLidarrAlbum)
    }
```

- [ ] **Step 3: Make `SearchViewModel.navigateToAdded` delegate.** Replace its body:

```swift
    private func navigateToAdded(_ result: SearchResult, source: QueueItem.Source, arrId: Int?) {
        guard let arrId else { return }
        DetailRequest.open(source: source, arrId: arrId, title: result.title,
                           posterURL: result.posterURL, posterRequiresAuth: false)
    }
```

  And in `addAlbum`, replace the hand-built `DetailRequest.post(DetailRequest.syntheticItem(...))` with:

```swift
            // The POST returns the ALBUM record — deep-link straight into the
            // album detail (unlike the artist add, which lands on the artist).
            guard let arrId else { return }
            DetailRequest.open(source: .lidarr, arrId: arrId, title: result.title,
                               posterURL: result.posterURL, isLidarrAlbum: true)
```

- [ ] **Step 4: Make `LibraryEntry.openDetail` delegate.** In `LibraryTabContent.swift`, replace the body inside the `private extension LibraryEntry`:

```swift
    /// Tap routes through `DetailRequest.open` so the arr's full record opens
    /// in the same DetailView the queue rows use (Lidarr → the artist surface).
    func openDetail() {
        DetailRequest.open(source: source, arrId: arrId, title: title,
                           posterURL: posterURL, posterRequiresAuth: posterRequiresAuth)
    }
```

- [ ] **Step 5: Verify the branch is gone in three places.** `grep -rn "syntheticArtistItem" Packages/ArrCore/Sources` — expected: exactly two hits, the declaration and the single use inside `DetailRequest.open`.

- [ ] **Step 6: Run the suite and build.** `(cd Packages/ArrCore && swift test)` — expected: green. Then:

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual check: tap a Lidarr artist tile in Library → the artist surface, not an album.

- [ ] **Step 7: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/AppNotifications.swift \
        Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift \
        Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift
git commit -m "refactor(detail): DetailRequest.open owns the Lidarr artist branch

Three private copies of 'artist, unless it is an album' collapse into one
router that tap, navigateToAdded and LibraryEntry.openDetail all call.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 6: The query lives in the view model

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift` (lines 7, 82–91, 131–148)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelQueryTests.swift` (create)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelCancellationTests.swift` (line ~66)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelStaleResultsTests.swift` (lines ~29–90)

- [ ] **Step 1: Write `SearchViewModelQueryTests.swift` first.**

```swift
import Testing
import Foundation
@testable import ArrCore

/// Three copies of "mirror the field into the VM, then call onQueryChange" —
/// two of which reset the scope on an empty field and one of which did not —
/// collapse into a `didSet` here. The re-entry guard is the subtle half: the
/// reset writes `scope`, whose own `didSet` would otherwise run a second pass
/// over the same empty query.
@Suite("SearchViewModel query")
@MainActor
struct SearchViewModelQueryTests {

    @Test("Assigning query runs the search without an explicit onQueryChange")
    func assignmentRunsTheSearch() {
        let vm = SearchViewModel()
        vm.setup(radarrConfig: ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                             apiKey: "k", username: "", password: ""),
                 sonarrConfig: .empty)
        defer { vm.reset() }

        vm.query = "matrix"
        #expect(vm.parsedInput == .text("matrix"))
        #expect(vm.isSearching)
        #expect(vm.isActive)
    }

    @Test("isActive follows the trimmed query")
    func isActiveFollowsTrimmedQuery() {
        let vm = SearchViewModel()
        #expect(!vm.isActive)
        vm.query = "   "
        #expect(!vm.isActive)
        vm.query = "dune"
        #expect(vm.isActive)
    }

    @Test("Emptying the query resets scope to .all exactly once and keeps libraryOnly")
    func emptyQueryResetsScopeOnce() {
        let vm = SearchViewModel()
        vm.scope = .series
        vm.libraryOnly = true
        let before = vm.queryChangePasses

        vm.query = ""

        #expect(vm.scope == .all)
        // Sticky, as documented — only the scope is per-search.
        #expect(vm.libraryOnly)
        // One pass, not two: the scope reset must not re-enter onQueryChange.
        #expect(vm.queryChangePasses == before + 1)
    }

    @Test("A scope change the user makes still re-runs the search")
    func userScopeChangeStillSearches() {
        let vm = SearchViewModel()
        vm.query = "dune"
        let before = vm.queryChangePasses
        vm.scope = .movie
        #expect(vm.queryChangePasses == before + 1)
    }
}
```

- [ ] **Step 2: Run and watch it fail.** `(cd Packages/ArrCore && swift test --filter "SearchViewModel query")` — expected: build error, `isActive` and `queryChangePasses` do not exist.

- [ ] **Step 3: Add the `didSet`, `isActive` and the re-entry guard.** In `SearchViewModel`, replace the `query` declaration:

```swift
    /// The one query. Every field on every surface binds straight to this, so
    /// there is nothing to mirror and nothing to keep in sync — the `didSet`
    /// IS the trigger that three separate `onChange` sites used to be.
    var query = "" {
        didSet { if query != oldValue { onQueryChange() } }
    }

    /// True while a live query owns the surface. One definition, used by the
    /// tab-bar hide, the focus logic, the takeover host and both tabs.
    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many times `onQueryChange` has run. Not UI state — it exists so the
    /// "an empty query resets the scope EXACTLY once" invariant is testable;
    /// the re-entry it guards against is invisible from the outside otherwise.
    @ObservationIgnored private(set) var queryChangePasses = 0

    /// Set while `onQueryChange` resets the scope itself, so `scope`'s own
    /// `didSet` doesn't bounce back in and run a second pass over the same
    /// (empty) query.
    @ObservationIgnored private var isResettingScope = false
```

  and the `scope` declaration:

```swift
    var scope: SearchScope = .all {
        didSet { if scope != oldValue, !isResettingScope { onQueryChange() } }
    }
```

- [ ] **Step 4: Move the scope reset into `onQueryChange`.** Replace the head of the method and its empty-query branch:

```swift
    func onQueryChange() {
        queryChangePasses += 1
        searchTask?.cancel()
        errorMessage = nil
        searchGeneration += 1
        let myGen = searchGeneration
        parsedInput = QueryParser.parse(query)

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let previous = previousQuery
        previousQuery = trimmed
        guard !trimmed.isEmpty else {
            // Ending the search drops any narrow scope: a scope that outlives
            // the query it was chosen for reads as a bug on the next search.
            // `libraryOnly` is deliberately sticky and stays.
            if scope != .all {
                isResettingScope = true
                scope = .all
                isResettingScope = false
            }
            // Empty query: kill the loader, clear results. Anything mid-flight
            // that hasn't returned will be ignored when it does (its
            // generation no longer matches).
            isSearching = false
            clearResults()
            return
        }
```

  The rest of the method is unchanged.

- [ ] **Step 5: Drop the now-redundant explicit calls in the existing tests.** In `SearchViewModelCancellationTests.startSearch`, delete the `vm.onQueryChange()` line (the assignment above it triggers it). In `SearchViewModelStaleResultsTests`, delete every `vm.onQueryChange()` that directly follows a `vm.query = …` assignment (in `settled(on:)` and in each `@Test`). Leaving them in is harmless but would double the generation bump and hide exactly the behaviour being tested.

- [ ] **Step 6: Run the search tests, then the full suite.** `(cd Packages/ArrCore && swift test --filter SearchViewModel)` — expected: the query, cancellation and stale-results suites all pass. `(cd Packages/ArrCore && swift test)` — expected: green.

- [ ] **Step 7: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/ViewModels/SearchViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelQueryTests.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelCancellationTests.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchViewModelStaleResultsTests.swift
git commit -m "feat(search): the query lives in the view model

query gets a didSet, scope resets on an empty field without re-entering,
and isActive becomes the one 'a query owns the surface' predicate.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 7: One dedup — `LocalHit` and `removingLocalDuplicates`

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/LocalHit.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift` (whole file)
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift` (line 27) and `Views/LibraryTabContent.swift` (line ~256) — keep them compiling
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift` (rewrite)

- [ ] **Step 1: Rewrite `SearchResultDedupTests.swift` first.** Keep the `result(...)` and `queueItem(...)` helpers, add a `source:` parameter to `queueItem`, and replace both `@Test` blocks:

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("SearchResultDedup")
struct SearchResultDedupTests {
    private func result(id: Int, foreignId: String = "foreign", title: String = "title",
                        source: QueueItem.Source = .radarr, inLibraryArrId: Int?) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: foreignId, title: title, subtitle: nil,
            year: nil, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: source,
            inLibraryArrId: inLibraryArrId
        )
    }

    private func queueItem(entityId: Int?, source: QueueItem.Source = .radarr) -> QueueItem {
        QueueItem(
            id: "q\(entityId ?? -1)", source: source, arrQueueId: 1,
            downloadId: nil, downloadProtocol: .unknown,
            downloadClient: nil, indexer: nil,
            title: "t", subtitle: nil,
            seasonNumber: nil, episodeNumber: nil, episodeTitle: nil,
            releaseName: nil,
            status: .downloading, progress: 0.5, sizeTotal: 0,
            sizeLeft: 0, timeLeft: nil,
            customFormats: [], customFormatScore: 0,
            quality: nil, releaseGroup: nil, isUpgrade: false,
            contentSlug: nil,
            entityId: entityId
        )
    }

    private func libraryEntry(arrId: Int, source: QueueItem.Source = .radarr) -> LibraryEntry {
        LibraryEntry(
            id: "\(source.rawValue)-\(arrId)", source: source, arrId: arrId,
            title: "t", year: nil, posterURL: nil, posterRequiresAuth: false,
            state: .complete, sizeOnDisk: 0, fileCount: nil, totalCount: nil,
            fileQuality: nil, profileName: nil, customFormats: [], customFormatScore: 0,
            fileName: nil, genres: [], runtime: nil, certification: nil,
            ratingImdb: nil, ratingTmdb: nil, ratingArr: nil,
            releaseStatus: nil, searchIndex: TitleMatch.searchIndex(["t"])
        )
    }

    // MARK: - Queue hits

    @Test("An owned row the queue is already showing is removed")
    func removesMatchingSingleton() {
        let results = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: 42)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [2])
    }

    @Test("A group contributes every item it packs")
    func removesMatchingGroupMember() {
        let results = [result(id: 1, inLibraryArrId: 7)]
        let group = QueueGroup(id: "g", items: [queueItem(entityId: 5), queueItem(entityId: 7)])
        let hits: [LocalHit] = [.queue(.group(group))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.isEmpty)
    }

    @Test("Queue items with nil entityId never match")
    func nilEntityIdsDontMatch() {
        let results = [result(id: 1, inLibraryArrId: 42)]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: nil)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    // MARK: - Library hits

    @Test("An owned row the browsed library already shows is removed")
    func removesLocallyMatchedLibraryEntry() {
        let results = [
            result(id: 1, source: .radarr, inLibraryArrId: 42),
            result(id: 2, source: .radarr, inLibraryArrId: nil),
        ]
        let hits: [LocalHit] = [.library(libraryEntry(arrId: 42))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [2])
    }

    @Test("An owned row the local match missed is kept")
    func keepsAliasMissedOwnedResult() {
        let results = [result(id: 1, source: .radarr, inLibraryArrId: 42)]
        let hits: [LocalHit] = [.library(libraryEntry(arrId: 7))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    // MARK: - Invariants

    @Test("An id collision across arrs never drops a row")
    func keepsOtherArrOwnedResult() {
        let results = [result(id: 1, source: .sonarr, inLibraryArrId: 42)]
        let hits: [LocalHit] = [
            .library(libraryEntry(arrId: 42, source: .radarr)),
            .queue(.single(queueItem(entityId: 42, source: .radarr))),
        ]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    @Test("Add-new rows are never removed")
    func keepsAddNewResults() {
        let results = [
            result(id: 1, source: .radarr, inLibraryArrId: nil),
            result(id: 2, source: .sonarr, inLibraryArrId: nil),
        ]
        let hits: [LocalHit] = [
            .library(libraryEntry(arrId: 1)),
            .queue(.single(queueItem(entityId: 2))),
        ]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1, 2])
    }

    @Test("No local hits passes everything through unchanged")
    func emptyLocalHits() {
        let results = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: [])
        #expect(out.map(\.externalId) == [1, 2])
    }

    @Test("Preserves the order of survivors")
    func preservesOrder() {
        let results = [
            result(id: 1, inLibraryArrId: 1),
            result(id: 2, inLibraryArrId: 2),
            result(id: 3, inLibraryArrId: 3),
        ]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: 2)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1, 3])
    }
}
```

- [ ] **Step 2: Run and watch it fail.** `(cd Packages/ArrCore && swift test --filter SearchResultDedupTests)` — expected: build error, `LocalHit` and `removingLocalDuplicates` do not exist.

- [ ] **Step 3: Create `Models/LocalHit.swift`.**

```swift
import Foundation

/// One row the HOST already knows about, handed to the search surface as its
/// local context. The tabs differ in exactly this: the Queue tab supplies live
/// download rows, the Library tab supplies owned titles from the browsed
/// library. Everything below this line looks and behaves identically.
public enum LocalHit: Identifiable {
    /// A live download — progress and action chrome, rendered by `QueueSearchRow`.
    case queue(QueueRowEntry)
    /// An owned title from the browsed library, rendered as an owned search row.
    case library(LibraryEntry)

    public var id: String {
        switch self {
        case .queue(let entry):   return "queue.\(entry.id)"
        case .library(let entry): return "library.\(entry.id)"
        }
    }

    /// Every `(source, arr record id)` this hit already answers for. A queue
    /// group answers for every item it packs — a season pack on screen means
    /// the series row underneath it would be a duplicate.
    var ownershipKeys: [OwnershipKey] {
        switch self {
        case .queue(let entry):
            switch entry {
            case .single(let item):
                return item.entityId.map { [OwnershipKey(source: item.source, arrId: $0)] } ?? []
            case .group(let group):
                return group.items.compactMap { item in
                    item.entityId.map { OwnershipKey(source: item.source, arrId: $0) }
                }
            }
        case .library(let entry):
            return [OwnershipKey(source: entry.source, arrId: entry.arrId)]
        }
    }
}

/// Arr-internal record ids only mean anything within one arr, so the source
/// travels with the id. Without it, a Radarr movie #42 on screen would hide a
/// Sonarr series #42 from the results — the one wrong answer this app must
/// never give.
public struct OwnershipKey: Hashable, Sendable {
    public let source: QueueItem.Source
    public let arrId: Int

    public init(source: QueueItem.Source, arrId: Int) {
        self.source = source
        self.arrId = arrId
    }
}

public extension LocalHit {
    /// The Queue tab's local context: every configured source's live rows that
    /// still match the query, Sonarr's grouped into packs.
    ///
    /// Matching is `TitleMatch.indexedFilter` over a per-item fold of title +
    /// episode title + subtitle — the same matcher the library grid uses, so
    /// "wall e" finds WALL·E in a queue row too. Folding per keystroke is fine
    /// here: queue lists are tens of rows, not thousands.
    @MainActor
    static func queueHits(viewModel: QueueViewModel,
                          sources: [QueueItem.Source],
                          query: String) -> [LocalHit] {
        sources.flatMap { source -> [LocalHit] in
            let matched = TitleMatch.indexedFilter(
                viewModel.items(for: source),
                query: query,
                index: { item in
                    [item.title, item.episodeTitle ?? "", item.subtitle ?? ""]
                        .filter { !$0.isEmpty }
                        .map(TitleMatch.fold)
                        .joined(separator: "\n")
                }
            )
            let rows: [QueueRowEntry] = source == .sonarr
                ? QueueGrouping.group(matched)
                : matched.map { .single($0) }
            return rows.map(LocalHit.queue)
        }
    }
}
```

- [ ] **Step 4: Replace `SearchResultDedup` with the one function.**

```swift
import Foundation

/// De-duplication between what the HOST already shows locally (live queue rows
/// or the browsed library) and the arr-lookup rows rendered under them. A row
/// the user can already see must not repeat below it — but ONLY that row drops.
///
/// Add-new hits, titles owned by a *different* arr, and owned titles the local
/// match missed all stay: hiding an owned title reads as "you don't own it",
/// the one wrong answer this app must never give.
public enum SearchResultDedup {
    public static func removingLocalDuplicates(
        results: [SearchResult],
        localHits: [LocalHit]
    ) -> [SearchResult] {
        guard !localHits.isEmpty else { return results }
        let keys = Set(localHits.flatMap(\.ownershipKeys))
        return results.filter { result in
            guard let arrId = result.inLibraryArrId else { return true }
            return !keys.contains(OwnershipKey(source: result.source, arrId: arrId))
        }
    }
}
```

- [ ] **Step 5: Keep the two call sites compiling.** They are rewritten properly in Tasks 8 and 11; for now make them use the new function so the package builds.

  In `Views/QueueSearchResultsView.swift`, replace lines 26–32 with:

```swift
        let localHits = queueRows.map(LocalHit.queue)
        let rawLibrary = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingLocalDuplicates(
            results: rawLibrary, localHits: localHits)
```

  In `Views/LibraryTabContent.swift`, replace the body of `remoteResults` lines ~252–257 with:

```swift
        let localHits = TitleMatch.indexedFilter(allEntries, query: trimmedFilter,
                                                 index: \.searchIndex)
            .map(LocalHit.library)
        let kept = SearchResultDedup.removingLocalDuplicates(results: all, localHits: localHits)
```

  (The `source` capture and `localIds` set go away; the source gate now lives in `OwnershipKey`.)

- [ ] **Step 6: Run the tests, then the full suite.** `(cd Packages/ArrCore && swift test --filter SearchResultDedupTests)` — expected: nine tests pass. `(cd Packages/ArrCore && swift test)` — expected: green. `grep -rn "removingQueueDuplicates\|removingGridDuplicates" Packages ArrBarr ArrBarriOS ArrBarrWidgets Shared` — expected: no hits.

- [ ] **Step 7: Build + relaunch and eyeball both tabs.**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 8: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/LocalHit.swift \
        Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift \
        Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift
git commit -m "refactor(search): one dedup against host-supplied local hits

LocalHit models the one thing the tabs differ in. Two dedup functions with
two different id rules become one, keyed by (source, arr id) so a cross-arr
id collision can never hide an owned title.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 8: `SearchResultsSurface` — the one results surface

**Files:**
- Delete: `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift` (via `git mv`)
- Create: `Packages/ArrCore/Sources/ArrCore/Views/SearchResultsSurface.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/QueueTabContent.swift` (`searchResults`, lines 166–179)
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift` (lines ~376–384)

SwiftUI bodies do not render under `swift test` — this task is verified by a build and a manual pass in the running app.

- [ ] **Step 1: Rename the file.** `git mv Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift Packages/ArrCore/Sources/ArrCore/Views/SearchResultsSurface.swift`

- [ ] **Step 2: Rewrite the type's head, body and helpers.** Replace everything from the doc comment down to the end of `showsEmptyState` with:

```swift
import SwiftUI

/// The one search-results surface, shared by the Queue tab, the Library tab
/// and both platforms.
///
/// Section order: local hits → people rows → primary "Starring X" → one
/// merged, relevance-sorted block of library + add-new lookup rows → secondary
/// "Starring X" → settled-empty state.
///
/// `localHits` is the ONLY thing the hosts differ in: the Queue tab hands in
/// its live download rows, the Library tab the browsed library's matches. They
/// arrive already filtered and ordered by the host, render at full opacity
/// (they are recomputed per keystroke, so they are never stale), and the
/// lookup rows below them are deduped against them.
///
/// Narrowing is `searchVM.scope` and nothing else: lookup results for an
/// unconfigured arr are already empty, and `SearchScope.allows` gates the
/// clients before a request is made.
struct SearchResultsSurface: View {
    var searchVM: SearchViewModel
    /// Host-supplied local context, already filtered and ordered.
    var localHits: [LocalHit]
    /// Tap on a live queue row (drills into detail).
    let onSelectQueueItem: (QueueItem) -> Void
    /// Tap on an add-new (not-in-library) result.
    let onSelectAddResult: (SearchResult) -> Void
    /// Tap on a person row / "Starring X" — host pushes the person view.
    var onSelectPerson: (PersonRef) -> Void = { _ in }

    var body: some View {
        let lookupRows = SearchRelevance.sortedByRelevance(
            SearchResultDedup.removingLocalDuplicates(
                results: allLookupResults, localHits: localHits),
            input: searchVM.parsedInput
        )
        // Refining a query ("matrix" → "matrix 2") keeps the previous rows up
        // while the new lookups run — deliberately, so typing doesn't flicker
        // list ↔ spinner. See `lookupReloadDim` for what those stale rows
        // wear meanwhile.
        let reloading = searchVM.isSearching && !lookupRows.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(localHits) { hit in
                    localRow(hit)
                }
            }
            // People rows (people scope / `person:` prefix) sit above the
            // titles — in that mode the arr clients are gated off, so
            // `lookupRows` is empty and these are the whole result.
            if !searchVM.peopleResults.isEmpty {
                VStack(spacing: 2) {
                    ForEach(searchVM.peopleResults) { person in
                        personRow(person)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                // "Starring X" — an all-scope person match and their top
                // titles. A full-name query ("rhea seehorn") means the person
                // IS the result, so that section leads; a single-token match
                // ("hanks") stays a footnote under the titles it annotates.
                if let starring = searchVM.starring, starring.isPrimary {
                    starringSection(starring)
                }
                ForEach(lookupRows) { r in
                    SearchResultRow(result: r) { route(r) }
                }
                if let starring = searchVM.starring, !starring.isPrimary {
                    starringSection(starring)
                }
            }
            .lookupReloadDim(reloading)

            // Settled empty search: every bucket came back empty and the
            // lookups are done. Without this the surface is just blank rows
            // of nothing, which reads as "still loading" or "broken".
            if showsEmptyState {
                SearchLookupEmptyState(errorMessage: searchVM.errorMessage)
            }
        }
    }

    private var allLookupResults: [SearchResult] {
        searchVM.radarrResults + searchVM.sonarrResults
            + searchVM.lidarrResults + searchVM.whisparrResults
    }

    /// Owned → the detail; addable → the add panel. `DetailRequest.tap` owns
    /// the Lidarr artist-vs-album branch.
    private func route(_ r: SearchResult) {
        if r.inLibraryArrId != nil {
            DetailRequest.tap(r)
        } else {
            onSelectAddResult(r)
        }
    }

    /// A queue hit keeps its download chrome (progress, actions — it doesn't
    /// flatten into a search row); a library hit is an owned title and wears
    /// the same row every other owned result does, routed the same way.
    @ViewBuilder
    private func localRow(_ hit: LocalHit) -> some View {
        switch hit {
        case .queue(let entry):
            let item = entry.representativeItem
            QueueSearchRow(item: item) { onSelectQueueItem(item) }
        case .library(let entry):
            let result = SearchResult(libraryEntry: entry)
            SearchResultRow(result: result) { DetailRequest.tap(result) }
        }
    }

    /// True when the query has settled with nothing to show in ANY bucket —
    /// no local hits, no lookup rows, no people. Requires a live query (an
    /// empty field legitimately shows nothing) and no in-flight search (that
    /// case is the host's loading indicator).
    private var showsEmptyState: Bool {
        guard searchVM.isActive, !searchVM.isSearching else { return false }
        guard !searchVM.hasResults, searchVM.starring == nil else { return false }
        return localHits.isEmpty
    }
```

  Keep `personRef(_:)`, `personRow(_:)` and `starringSection(_:)` as they are, except: in `starringSection`, replace the inline `if r.inLibraryArrId != nil { DetailRequest.tap(r) } else { onSelectAddResult(r) }` closure with `route(r)`.

  Delete outright: the `@EnvironmentObject var configStore`, the `scope` property, `isConfigured(_:)`, `configuredSources`, `scopedSources`, `matchesFilter(_:)`, `entries(for:)`, `libraryResults(for:)`, `newResults(for:)`, `rawSearchResults(for:)` and the `viewModel: QueueViewModel` property.

- [ ] **Step 3: Rewire `QueueTabContent.searchResults`.** Replace it:

```swift
    /// The one search-results surface. Live queue rows that still match sit at
    /// the top (downloads with progress + action chrome — they don't flatten
    /// into a search row), then a single merged, cross-source-sorted block of
    /// library + add-new hits. No section divider; this IS the result list.
    @ViewBuilder
    private var searchResults: some View {
        SearchResultsSurface(
            searchVM: searchViewModel,
            localHits: localHits,
            onSelectQueueItem: { detailItem = $0 },
            onSelectAddResult: { searchResult = $0 },
            onSelectPerson: { personRef = $0 }
        )
        .personDestination($personRef)
    }

    /// This tab's local context: the live queue, matched with the same folder
    /// the library grid uses (so "wall e" finds WALL·E here too).
    private var localHits: [LocalHit] {
        guard searchViewModel.isActive else { return [] }
        return LocalHit.queueHits(viewModel: viewModel,
                                  sources: configuredSources,
                                  query: searchViewModel.query)
    }

    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }
```

- [ ] **Step 4: Rewire the iOS `QueueTab` call site.** In `iOSAppRoot.swift`, replace the `QueueSearchResultsView(...)` block with:

```swift
                        SearchResultsSurface(
                            searchVM: searchVM,
                            localHits: queueLocalHits,
                            onSelectQueueItem: { detailItem = $0 },
                            onSelectAddResult: { searchResult = $0 },
                            onSelectPerson: { personRef = $0 }
                        )
                        .padding(.vertical, 8)
```

  and add to `QueueTab`:

```swift
    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var queueLocalHits: [LocalHit] {
        guard searchVM.isActive else { return [] }
        return LocalHit.queueHits(viewModel: viewModel,
                                  sources: configuredSources,
                                  query: searchVM.query)
    }
```

  Also change `private var isSearching: Bool { … }` to read `searchVM.isActive` at its two use sites and delete the property.

- [ ] **Step 5: Verify the rename took everywhere.** `grep -rn "QueueSearchResultsView" Packages ArrBarr ArrBarriOS ArrBarrWidgets Shared` — expected: no hits.

- [ ] **Step 6: Build, run the suite, relaunch.**

```bash
(cd Packages/ArrCore && swift test)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual pass: on the Queue tab type a title you own and are downloading — the queue row shows once, the lookup row for it is gone. Type "wall e" — the WALL·E queue row (if any) matches.

- [ ] **Step 7: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/SearchResultsSurface.swift \
        Packages/ArrCore/Sources/ArrCore/Views/QueueSearchResultsView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/QueueTabContent.swift \
        Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift
git commit -m "refactor(search): QueueSearchResultsView becomes SearchResultsSurface

The surface takes host-supplied local hits instead of reaching into the
queue view model, and narrows on searchVM.scope alone — the duplicated
source-configured helpers and the weak substring matcher are gone.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 9: `SearchCapsule` and `SearchTakeoverView` (macOS chrome)

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/SearchCapsule.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Views/SearchTakeoverView.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/QueueTabContent.swift` (whole file)

- [ ] **Step 1: Create `SearchCapsule.swift`.**

```swift
import SwiftUI

/// The macOS floating search bar — one component, both tabs.
///
/// Clean glass capsule with the same `.glassyFloatingBar()` chrome as the tab
/// cluster above, so it reads as the same control surface family. The spinner
/// is inline in the bar and not only at the bottom of the list: once results
/// render, a bottom loader sits below the fold and the second search gives the
/// user no visible feedback at all.
struct SearchCapsule: View {
    @Bindable var searchVM: SearchViewModel
    var focused: FocusState<Bool>.Binding
    @EnvironmentObject var configStore: ConfigStore

    private var searchAvailable: Bool {
        QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        HStack(spacing: 8) {
            SearchFieldLeadingIcon(
                spinning: searchAvailable && searchVM.isSearching && searchVM.isActive)
            TextField("", text: $searchVM.query, prompt:
                Text("search.global.prompt", bundle: .module)
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused(focused)
            if searchVM.isActive && searchAvailable {
                scopeMenu
            }
            if !searchVM.query.isEmpty {
                Button { searchVM.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("queue.clearFilter.button", bundle: .module))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: searchVM.isActive)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        .glassyFloatingBar(focused: focused.wrappedValue)
    }

    /// Compact menu chip on the trailing edge — narrows which backends the
    /// query hits, and holds the "In library" toggle. Tinted accent while
    /// anything narrows the search (a non-`all` scope or library-only), so a
    /// stuck narrow search is visible at a glance.
    ///
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` is the ONE combination
    /// that renders a custom SwiftUI label faithfully.
    private var scopeMenu: some View {
        let scope = searchVM.scope
        let libraryOnly = searchVM.libraryOnly
        return Menu {
            ForEach(SearchScope.available(for: configStore)) { s in
                Button { searchVM.scope = s } label: {
                    Label {
                        Text(LocalizedStringKey(s.labelKey), bundle: .module)
                    } icon: {
                        Image(systemName: s == scope ? "checkmark" : s.symbol)
                    }
                }
            }
            Divider()
            Button { searchVM.libraryOnly.toggle() } label: {
                Label {
                    Text("search.libraryOnly.toggle", bundle: .module)
                } icon: {
                    Image(systemName: libraryOnly ? "checkmark" : "books.vertical")
                }
            }
        } label: {
            Image(systemName: libraryOnly ? "books.vertical.fill" : scope.symbol)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(scope == .all && !libraryOnly
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("search.scope.help", bundle: .module))
    }
}
```

- [ ] **Step 2: Create `SearchTakeoverView.swift`.**

```swift
import SwiftUI

/// The takeover host: while a query is live, search owns the window on BOTH
/// tabs. The header is pinned ABOVE the ScrollView so it stays stuck to the
/// top of the popover — in search mode it stands in for the hidden tab bar as
/// the top strip — instead of scrolling away with the results beneath it.
struct SearchTakeoverView<Surface: View>: View {
    @Bindable var searchVM: SearchViewModel
    /// True when at least one arr can answer. Gates the cold-start spinner:
    /// with nothing configured there is nothing to wait for.
    let searchAvailable: Bool
    @ViewBuilder var surface: () -> Surface

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    surface()
                    // Only while nothing is rendered yet. With rows up this
                    // spinner sits below the fold and the user sees no loading
                    // state at all on a re-search — that case is covered by
                    // `lookupReloadDim` inside the surface instead.
                    if searchAvailable, searchVM.isSearching, !searchVM.hasResults {
                        loadingIndicator
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity)
    }

    /// Back chevron clears the query, which is what ends the takeover — the
    /// scope reset rides along inside `onQueryChange`.
    private var header: some View {
        HStack(spacing: 6) {
            FloatingBackButton { searchVM.query = "" }
            Text("search.searching.header", bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("queue.loading.button", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
```

  `search.searching.header` does not exist in the catalog yet — Task 13 renames `queue.searching.button` into it. Until then the header renders its raw key; that is expected and is fixed in Task 13. (Do NOT add the key by hand here — `Tools/loc` owns the catalog.)

- [ ] **Step 3: Rewrite `QueueTabContent` around the shared VM query.** Replace the whole file:

```swift
import SwiftUI

struct QueueTabContent: View {
    var viewModel: QueueViewModel
    var searchViewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore

    var searchFieldFocused: FocusState<Bool>.Binding
    @Binding var detailItem: QueueItem?
    @Binding var historySource: QueueItem.Source?
    @Binding var searchResult: SearchResult?
    /// Queue multi-select mode — owned by PopoverContentView (toggled from its
    /// "⋯" menu), threaded down to the native-`List` queue.
    @Binding var selecting: Bool
    /// Person-view push from a search person row / "Starring X" section.
    @State private var personRef: PersonRef?

    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var searchAvailable: Bool { !configuredSources.isEmpty }

    var body: some View {
        // The capsule floats at the bottom (Apple's recent search/Spotlight
        // direction). ZStack and not `safeAreaInset`: the inset modifier reacts
        // to any identity change in the parent tree — and the results branch
        // re-renders on every keystroke — which re-mounts the TextField and
        // drops focus mid-typing. `ChatView` carries the long-form note.
        ZStack(alignment: .bottom) {
            queueOrSearch
            SearchCapsule(searchVM: searchViewModel, focused: searchFieldFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    /// Non-searching → native `List` (QueueListView, native swipe). Searching →
    /// the shared takeover. Initial load → spinner.
    @ViewBuilder
    private var queueOrSearch: some View {
        if viewModel.isLoading {
            ScrollView {
                loadingIndicator
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else if searchViewModel.isActive {
            SearchTakeoverView(searchVM: searchViewModel, searchAvailable: searchAvailable) {
                searchResults
            }
        } else {
            QueueListView(
                viewModel: viewModel,
                scope: nil,
                onShowDetail: { item in
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                },
                onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                onShowHistory: { source in historySource = source },
                selecting: $selecting
            )
            // Keep the last row clear of the floating capsule.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 58) }
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("queue.loading.button", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func openNeedsYouQueue(_ needs: NeedsYouItem) {
        // Non-arr connection issues (download client / AI) have no arr queue
        // page to open — the user fixes those in Settings.
        guard let source = needs.source else { return }
        let cfg = configStore.config(for: source.serviceKind)
        guard let url = ArrActivityURLBuilder.queueURL(forBase: cfg.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        PlatformURLOpener.open(url)
    }

    /// The one search-results surface. Live queue rows that still match sit at
    /// the top (downloads with progress + action chrome — they don't flatten
    /// into a search row), then a single merged, cross-source-sorted block of
    /// library + add-new hits. No section divider; this IS the result list.
    @ViewBuilder
    private var searchResults: some View {
        SearchResultsSurface(
            searchVM: searchViewModel,
            localHits: localHits,
            onSelectQueueItem: { detailItem = $0 },
            onSelectAddResult: { searchResult = $0 },
            onSelectPerson: { personRef = $0 }
        )
        .personDestination($personRef)
    }

    /// This tab's local context: the live queue, matched with the same folder
    /// the library grid uses (so "wall e" finds WALL·E here too).
    private var localHits: [LocalHit] {
        guard searchViewModel.isActive else { return [] }
        return LocalHit.queueHits(viewModel: viewModel,
                                  sources: configuredSources,
                                  query: searchViewModel.query)
    }
}
```

  `queueFilter`, `queueScope`, `queueFilterBar`, `scopeMenu`, `availableScopes`, `isFiltering`, `searchModeHeader` and both `onChange` mirrors are gone.

- [ ] **Step 4: Patch the one call site so the package still builds.** `PopoverContentView` is rewritten in Task 10; for now change its `QueueTabContent(...)` call to drop `queueFilter:` and `queueScope:` and rename `queueFilterFocused:` to `searchFieldFocused:`. Leave `queueFilter` / `queueScope` / `isFiltering` in `PopoverContentView` for the moment — they are still read by the tab bar and the intent handlers there.

  To keep those working in the interim, change `PopoverContentView`'s `.arrBarrSearchQuery` handler to `searchViewModel.query = q` and its `isFiltering` to `searchViewModel.isActive`, and the tab re-tap reset to `searchViewModel.query = ""`. That is the whole of Task 10's behaviour change anyway; this step just gets there early enough to compile.

- [ ] **Step 5: Build and relaunch.**

```bash
(cd Packages/ArrCore && swift test)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual pass: Queue tab — typing takes over, the scope menu and "In library" are on the capsule, the back chevron clears the field and restores the queue list. The header reads `search.searching.header` until Task 13.

- [ ] **Step 6: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/SearchCapsule.swift \
        Packages/ArrCore/Sources/ArrCore/Views/SearchTakeoverView.swift \
        Packages/ArrCore/Sources/ArrCore/Views/QueueTabContent.swift \
        Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "feat(search): one macOS capsule, one takeover host

SearchCapsule and SearchTakeoverView lift the queue tab's bar and search
header into shared components bound to the view model's query. QueueTabContent
keeps the queue and hands the surface its local hits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 10: PopoverContentView owns one query and focuses both tabs

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` (lines 68–74, 124–143, 319–322, 464–486, 770–777)

- [ ] **Step 1: Delete the root's copies of the query.** Remove:

```swift
    @State private var queueFilter: String = ""
    @State private var queueScope: QueueItem.Source? = nil
```

  and their doc comments, and rename the focus state:

```swift
    /// The macOS search capsule's focus, owned here because ⌘N, the Add intent
    /// and the search intent all aim at it from outside any tab. Passed down to
    /// whichever tab is rendering the capsule.
    @FocusState private var searchFieldFocused: Bool
```

  Nothing ever set `queueScope` to a concrete source — the old scope chips are gone and the only assignment left was `queueScope = nil` — so it goes entirely, and `QueueListView` takes `scope: nil` (already done in Task 9).

- [ ] **Step 2: Replace `isFiltering` with the VM's predicate.** Delete:

```swift
    private var isFiltering: Bool {
        !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
```

  and replace every use with `searchViewModel.isActive`.

- [ ] **Step 3: Focus the shared bar on both tabs.** Replace `focusInputForCurrentTab`:

```swift
    /// Put the caret in the search capsule so the panel is typeable the instant
    /// it opens.
    ///
    /// Queue AND Library: they render the SAME capsule, bound to the same
    /// query, so there is one field to focus and one owner of that focus.
    /// Upcoming has no field; Chat focuses its own composer on appear.
    ///
    /// Hopped to the next main-actor turn rather than set inline: on the
    /// `onAppear` pass the field isn't in the responder chain yet, and an
    /// assignment made before it is there is silently dropped.
    private func focusInputForCurrentTab() {
        guard selectedTab == .queue || selectedTab == .library else { return }
        Task { @MainActor in searchFieldFocused = true }
    }
```

- [ ] **Step 4: Hide the tab bar for Queue and Library.** Replace the guard around `tabBar`:

```swift
                    // Tab bar hides while a query is live — search becomes a
                    // full-size surface on BOTH tabs (the back chevron in the
                    // top strip is the only nav affordance you need). Tabs
                    // reappear the moment the query clears.
                    if !(searchViewModel.isActive
                         && (selectedTab == .queue || selectedTab == .library)) {
                        tabBar
                    }
```

- [ ] **Step 5: Rewire the two tab call sites.**

```swift
                        case .queue:
                            QueueTabContent(
                                viewModel: viewModel,
                                searchViewModel: searchViewModel,
                                searchFieldFocused: $searchFieldFocused,
                                detailItem: $detailItem,
                                historySource: $historySource,
                                searchResult: $searchResult,
                                selecting: $queueSelecting
                            )
                        case .library:
                            LibraryTabContent(
                                viewModel: libraryViewModel,
                                searchVM: searchViewModel,
                                searchResult: $searchResult,
                                searchFieldFocused: $searchFieldFocused
                            )
```

- [ ] **Step 6: Point the entry points and the tab re-tap at the VM.** `.arrBarrTriggerAdd` and ⌘N keep `selectedTab = .queue` + `searchFieldFocused = true` (unchanged behaviour, just the renamed focus). `.arrBarrSearchQuery` becomes:

```swift
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrSearchQuery)) { note in
                guard let q = note.userInfo?["query"] as? String else { return }
                selectedTab = .queue
                // The `didSet` runs the search; there is nothing to mirror.
                searchViewModel.query = q
            }
```

  and the tab-pill re-tap reset:

```swift
                    // Re-tapping the active tab clears a live query — a
                    // "reset to home" affordance that needs no chrome of its
                    // own (Spotify / Apple Music tab-bar idiom).
                    if tab == selectedTab, searchViewModel.isActive {
                        withAnimation(.easeOut(duration: 0.18)) {
                            searchViewModel.query = ""
                        }
                    }
```

  (It applies to Library now too, since Library hosts the same field.)

- [ ] **Step 7: Verify the deletions.** `grep -n "queueFilter\|queueScope\|isFiltering" Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` — expected: no hits.

- [ ] **Step 8: Build and relaunch.**

```bash
(cd Packages/ArrCore && swift test)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual pass: open the popover — the caret is in the capsule. ⌘N focuses it. Type, switch to Library, the query survives; clear it, the tab bar comes back.

- [ ] **Step 9: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "refactor(popover): one query, one focus, tab bar hides on both tabs

queueFilter, queueScope and isFiltering are gone; the root passes the shared
SearchViewModel and its focus to Queue and Library alike.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 11: LibraryTabContent joins the one search

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift` (lines 51–79, 218–300, 493–600, 636–700)

- [ ] **Step 1: Swap the private state for the shared view model.** In the property block, delete `filterText`, `filterFocused`, `searchVM` and rename `isActive` (the tab-visibility flag) to `isTabActive` so it cannot be confused with `searchVM.isActive`. The head becomes:

```swift
struct LibraryTabContent: View {
    var viewModel: LibraryViewModel
    /// The ONE search view model, owned by the root and shared with the Queue
    /// tab. The Library tab used to run its own instance; two owners of one
    /// query fought across every tab switch, and this one had no TMDB key, so
    /// its "In library" toggle answered with nothing.
    var searchVM: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore
    /// Tapping an add-new lookup row routes here — the root presents the shared
    /// `SearchAddPanel` overlay for it, same as the queue surface's rows.
    @Binding var searchResult: SearchResult?
    /// The macOS capsule's focus, owned by the root (it is the same field the
    /// Queue tab renders). Unused on iOS, which uses `.searchable`.
    var searchFieldFocused: FocusState<Bool>.Binding
    /// True while this is the tab on screen. Leaving it closes an EMPTY search
    /// field; one holding a query is kept, so coming back shows the results
    /// again instead of a blank list. macOS always passes the default.
    var isTabActive: Bool = true

    @State private var source: QueueItem.Source = .radarr
    @State private var sourceResolved = false
    @State private var statusFilter: StatusFilter = .all
    @State private var sort: SortMode = .title
    @State private var searchPresented = false
    /// Person-view push from a search person row / "Starring X" section — the
    /// Library tab reaches people now that it runs the full search.
    @State private var personRef: PersonRef?
    @AppStorage("libraryViewMode") private var viewModeRaw = ViewMode.grid.rawValue
```

- [ ] **Step 2: Delete `trimmedFilter`, `remoteResults` and `lookupSection`, and supply `localHits` instead.** Replace `trimmedFilter` and `remoteResults` with:

```swift
    /// This tab's local context: the browsed arr's entries in the current sort
    /// axis with the status chips applied, matched over the alias index.
    /// Under takeover these rows ARE the grid's answer — the grid itself is not
    /// shown, and clearing the query brings it back.
    private var localHits: [LocalHit] {
        guard searchVM.isActive else { return [] }
        return visibleEntries.map(LocalHit.library)
    }

    private var searchAvailable: Bool {
        QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible }
    }
```

  and update `visibleEntries` to read the shared query:

```swift
    private var visibleEntries: [LibraryEntry] {
        let query = searchVM.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sort FIRST, through the view model's memoized per-axis cache —
        // filtering a pre-sorted list preserves order, and the filters are the
        // cheap half (the localized title sort was the ~20ms-per-body-pass
        // hitch felt on tab entry).
        var out = viewModel.sorted(source, cacheKey: sort.cacheKey, using: sort.areInIncreasingOrder)
        out = out.filter { matches($0, filter: statusFilter) }
        if !query.isEmpty {
            // Searches the entry's whole alias set, not its visible title:
            // accents folded ("leon" → "Léon"), and every translated name the
            // arr knows ("leon zawodowiec").
            out = TitleMatch.indexedFilter(out, query: query, index: \.searchIndex)
        }
        return out
    }
```

  Delete `lookupSection(hasLocalRows:)` entirely.

- [ ] **Step 3: Rewrite `body`'s lifecycle.** The `onChange(of: filterText)` mirror and the local `searchVM.setup` go; the root already sets the shared instance up.

```swift
    var body: some View {
        surface
        .personDestination($personRef)
        .onChange(of: isTabActive) { _, nowActive in
            if !nowActive, !searchVM.isActive { searchPresented = false }
        }
        .onAppear {
            // The default `.radarr` may not be configured — snap to the first
            // arr that is, once. (Re-running on every appear would fight a
            // manual pick.)
            if !sourceResolved {
                sourceResolved = true
                if let first = availableSources.first, !availableSources.contains(source) {
                    source = first
                }
            }
            Task { await load() }
        }
        .onChange(of: source) { _, _ in
            // A sort axis the new arr doesn't offer (IMDb on Sonarr) snaps back
            // to the default rather than silently sorting on nils.
            if !availableSorts.contains(sort) { sort = .title }
            Task { await load() }
        }
    }
```

- [ ] **Step 4: Trim `gridOrState` of its lookup branch.** The grid is never shown under takeover, so both the `lookupSection` call and the "with a query live keep the scroll surface up" carve-out go:

```swift
        } else if entries.isEmpty {
            emptyState(symbol: "books.vertical", textKey: "library.empty.title") { EmptyView() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewMode == .grid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(entries) { entry in
                                LibraryTile(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LibraryListRow(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                // Keep the last row clear of the floating capsule.
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
```

- [ ] **Step 5: Rewrite `surface` for both platforms and delete `filterBar`.**

```swift
    /// macOS keeps the floating bottom capsule (the popover has no navigation
    /// bar to hang a field on). iOS uses the system search field, so Library
    /// reads like Queue and like every other iOS app. Either way it is the
    /// SAME field, the same scopes and the same takeover.
    @ViewBuilder
    private var surface: some View {
        #if os(iOS)
        VStack(spacing: 0) {
            // Browsing filters and search scopes are different jobs, so they
            // never share a row: the arr picker + status chips + sort belong to
            // the grid, the scope bar belongs to the query.
            LibraryFilterStrip { topStrip }
            SearchScopeBar(searchVM: searchVM, scopes: SearchScope.available(for: configStore))
            if searchVM.isActive {
                ScrollView {
                    resultsSurface
                        .padding(.vertical, 8)
                    if searchVM.isSearching, !searchVM.hasResults {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 16)
                    }
                }
                .background(Color(.systemBackground))
            } else {
                gridOrState
            }
        }
        .modifier(SearchField(searchVM: searchVM, enabled: true, isPresented: $searchPresented))
        #else
        VStack(spacing: 0) {
            // Under takeover the browsing strip steps aside too — matching what
            // `LibraryFilterStrip` already does on iOS.
            if !searchVM.isActive { topStrip }
            ZStack(alignment: .bottom) {
                if searchVM.isActive {
                    SearchTakeoverView(searchVM: searchVM, searchAvailable: searchAvailable) {
                        resultsSurface
                    }
                } else {
                    gridOrState
                }
                SearchCapsule(searchVM: searchVM, focused: searchFieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        #endif
    }

    private var resultsSurface: some View {
        SearchResultsSurface(
            searchVM: searchVM,
            localHits: localHits,
            // The Library tab has no live queue rows of its own — every local
            // hit here is a `.library` one, which routes itself.
            onSelectQueueItem: { _ in },
            onSelectAddResult: { searchResult = $0 },
            onSelectPerson: { personRef = $0 }
        )
    }
```

  Delete `filterBar` and its `@FocusState`-driven `onAppear` focus hop — the root owns focus now.

- [ ] **Step 6: Patch the two call sites.** `PopoverContentView` already passes the new arguments (Task 10). In `iOSAppRoot.swift`'s `LibraryTab`, add a local focus state to satisfy the (macOS-only) parameter and pass the shared VM:

```swift
private struct LibraryTab: View {
    var searchVM: SearchViewModel
    var libraryViewModel: LibraryViewModel
    var viewModel: QueueViewModel
    var isActive: Bool
    @State private var searchResult: SearchResult?
    @State private var detailItem: QueueItem?
    /// Only the macOS capsule reads this; iOS drives the field through
    /// `.searchable`. Declared so the one component signature serves both.
    @FocusState private var searchFieldFocused: Bool
```

  and in its `else` branch:

```swift
                LibraryTabContent(viewModel: libraryViewModel,
                                  searchVM: searchVM,
                                  searchResult: $searchResult,
                                  searchFieldFocused: $searchFieldFocused,
                                  isTabActive: isActive)
```

- [ ] **Step 7: Verify the deletions.** `grep -n "filterText\|filterBar\|remoteResults\|lookupSection\|trimmedFilter\|searchVM = SearchViewModel()" Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift` — expected: no hits.

- [ ] **Step 8: Build and relaunch.**

```bash
(cd Packages/ArrCore && swift test)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual pass: Library tab on macOS — typing takes over the window (top strip and tab bar gone), the scope menu and "In library" are on the capsule, owned titles show once, add-new rows open `SearchAddPanel`, the back chevron restores the grid. Add a title from Library search and return: the grid shows it owned.

- [ ] **Step 9: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/LibraryTabContent.swift \
        Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift
git commit -m "refactor(library): the Library tab runs the one search

Its private SearchViewModel, filter text, filter bar, lookup section and
grid dedup are gone; it supplies local hits to the shared surface and takes
over the window like the Queue tab.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 12: iOS — one `SearchField`, no mirrors

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift` (lines ~229–236, ~318, ~472–500)

- [ ] **Step 1: Generalize `QueueSearchField` into `SearchField`.** Replace it:

```swift
/// The one iOS search field, used by the Queue and Library tabs. Withdrawn
/// while multi-select owns the toolbar: its magnifier otherwise competes with
/// "Done" for the trailing slot and wins, leaving no way out of the mode.
struct SearchField: ViewModifier {
    @Bindable var searchVM: SearchViewModel
    let enabled: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(
                    text: $searchVM.query,
                    isPresented: $isPresented,
                    placement: .toolbar,
                    prompt: Text("search.global.prompt", bundle: .module)
                )
                // iOS 26 collapses the field into a toolbar magnifier that
                // expands on tap, so search shares a row with the other actions
                // instead of a permanent drawer stealing one from the list.
                // `SearchScopeBar` renders the scopes under it; `.searchScopes`
                // can't, see that type's note.
                .modifier(MinimizedSearchToolbar())
                .autocorrectionDisabled(true)
        } else {
            content
        }
    }
}
```

  The `scopes` parameter is dropped — the modifier never used it.

- [ ] **Step 2: Rewire `QueueTab`.** Replace the modifier and delete the mirror:

```swift
        .modifier(SearchField(searchVM: searchVM, enabled: !selecting,
                              isPresented: $searchPresented))
```

  Delete the whole `.onChange(of: searchVM.query) { … }` block — the `didSet` runs the search and resets the scope. In the `.arrBarrSearchQuery` handler, drop the explicit `searchVM.onQueryChange()`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrSearchQuery)) { note in
            guard let q = note.userInfo?["query"] as? String else { return }
            searchResult = nil
            searchVM.query = q
        }
```

- [ ] **Step 3: Use `searchVM.isActive` in the root's tab switch.** In `iOSAppRoot.body`:

```swift
        .onChange(of: selectedTab) { _, _ in
            // An empty search field left open behind a tab switch is just
            // chrome taking a row; one with a query is a result set worth
            // returning to.
            if !searchVM.isActive { searchPresented = false }
        }
```

- [ ] **Step 4: Verify.** `grep -n "QueueSearchField\|onChange(of: searchVM.query)" Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift` — expected: no hits.

- [ ] **Step 5: Build both schemes.**

```bash
(cd Packages/ArrCore && swift test)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarriOS -configuration Debug -derivedDataPath build -destination 'generic/platform=iOS Simulator' build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 6: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift
git commit -m "refactor(ios): one SearchField, no query mirror

QueueSearchField becomes the shared SearchField on the global prompt, and
the last onChange mirror of searchVM.query goes with it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 13: String catalog — rename and prune

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

The catalog is machine-owned: use `Tools/loc`, never a hand edit that drops a translation. Read `Tools/loc/loc_audit.py` and `Tools/loc/lint_missing_keys.py` headers before starting — they are the two gates.

- [ ] **Step 1: Rename `queue.searching.button` → `search.searching.header`, keeping all six translations.**

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
s = cat["strings"]
# The key is no longer queue-only: both tabs render this header now.
s["search.searching.header"] = s.pop("queue.searching.button")
# Unused after the unification: the iOS field took the global prompt, and the
# Library tab's lookup section (which owned "More results") is gone.
for dead in ("search.searchMoviesAndTv.label", "library.moreResults.header"):
    s.pop(dead, None)
cat["strings"] = dict(sorted(s.items()))
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("keys:", len(s))
PY
```

- [ ] **Step 2: Confirm nothing in code still names the dead keys.**

```bash
grep -rn "queue.searching.button\|search.searchMoviesAndTv.label\|library.moreResults.header" \
  Packages ArrBarr ArrBarriOS ArrBarrWidgets Shared
```

  Expected: no hits.

- [ ] **Step 3: Run both loc gates.**

```bash
python3 Tools/loc/lint_missing_keys.py
python3 Tools/loc/loc_audit.py Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
```

  Expected: `0 code-referenced keys missing from catalog`, and the audit reporting zero empty/new/missing entries. If the audit complains that the renamed key is `new`, clear the `state` on its string units with the same script pattern — the translations are real, only the key moved.

- [ ] **Step 4: Run the localization test and build.**

```bash
(cd Packages/ArrCore && swift test --filter LocalizationTests)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

  Manual pass: type on either tab — the takeover header reads "Searching", not the raw key.

- [ ] **Step 5: Commit.**

```bash
git add Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "chore(loc): search.searching.header, and two keys retired

The takeover header is no longer queue-only; the iOS prompt and the Library
lookup section's 'More results' have no call sites left.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 14: Final sweep

**Files:** none modified unless the sweep finds something.

- [ ] **Step 1: Grep every name on the spec's Deletions list.**

```bash
for s in QueueSearchResultsView removingQueueDuplicates removingGridDuplicates \
         "SearchRelevance.normalize" splitYear queueFilter queueScope \
         filterText filterBar remoteResults lookupSection trimmedFilter \
         QueueSearchField matchesFilter scopedSources configuredSources \
         "queue.searching.button" "search.searchMoviesAndTv.label" \
         "library.moreResults.header" "0x7fffffff"; do
  echo "### $s"
  grep -rn --include="*.swift" --include="*.xcstrings" -- "$s" \
    Packages/ArrCore/Sources Packages/ArrCore/Tests Packages/ArrMCPServer/Sources \
    ArrBarr ArrBarriOS ArrBarrWidgets Shared
done
```

  Expected: no hits at all, except `configuredSources` (a private helper legitimately living in `QueueTabContent`, `LibraryTabContent` and iOS's `QueueTab`) and one `0x7fffffff` inside `ArrLibraryMaps.foreignHashKey`.

- [ ] **Step 2: Check nothing reintroduced a second normalizer or a second library TTL.**

```bash
grep -rn "folding(options" Packages/ArrCore/Sources   # expect: only TitleMatch.fold
grep -rn "fetchedAt\|private let ttl" Packages/ArrCore/Sources/ArrCore/ViewModels/LibraryViewModel.swift
```

  Expected: the fold appears once; `LibraryViewModel` has neither.

- [ ] **Step 3: Run both package suites.**

```bash
(cd Packages/ArrCore && swift test)
(cd Packages/ArrMCPServer && swift test)
```

  Expected: both green.

- [ ] **Step 4: Build all three targets and relaunch.**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarriOS -configuration Debug -derivedDataPath build -destination 'generic/platform=iOS Simulator' build
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarrWidgets -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 5: Walk the spec's manual pass.** On macOS: type on Queue and on Library — both take over, both show the scope menu and "In library". Add a title from Library search — it shows owned in the grid on return. Type "wall e" — the WALL·E queue row matches. Clear with the chevron on both tabs and confirm the scope chip is back on All and "In library" is still where you left it. Open a Lidarr artist from a Library tile and from a search row — both land on the artist surface.

- [ ] **Step 6: Commit anything the sweep fixed** (skip if the tree is clean).

```bash
git add -u Packages/ArrCore/Sources Packages/ArrCore/Tests
git commit -m "chore(search): sweep after the unification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Do not `git add -A`.** The working tree carries unrelated uncommitted changes (Discover, TMDB mapping, MediaServer settings, the in-flight `libraryOnly` work and more). Every commit step above lists its files explicitly; keep it that way.
- **SwiftUI does not render under `swift test`** — `NSHostingView` evaluates zero bodies headless. Every view change is verified by a build plus a look at the running app, which is why each view task carries the rebuild/relaunch pair.
- **`.swipeActions` crashes on a macOS `List`.** Nothing in this plan adds one; don't add one while touching `QueueListView`'s neighbours.
- **`@Environment(\.dismiss)` inside a navigation destination re-renders at ~150 Hz.** The takeover's back affordance is an explicit closure (`searchVM.query = ""`), not `dismiss` — keep it that way.
- **Conventions:** `Logger(category: "…")` only; `Text("key", bundle: .module)` in views and `String(localized:bundle: .module)` / `AppLocalized.string` in models; never an inline user-facing literal; the swipe-to-discover feature is "Quiz" (never the other word); the paid tier is "Control" in user-facing copy.
