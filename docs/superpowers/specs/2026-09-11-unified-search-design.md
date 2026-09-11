# Unified search (design B: one engine, one surface, host supplies local context)

**Date:** 2026-09-11
**Scope:** macOS popover / detached window and iOS. Queue tab and Library tab.
**Supersedes** the Library half of `2026-08-17-library-unified-search-design.md`
(the "own `SearchViewModel` instance" decision there is reversed here).

## Problem

Search is reachable from two tabs and behaves differently on each. Both run
the same `SearchViewModel` *class*, but as separate *instances* wired three
different ways (Queue macOS, Queue iOS, Library). The duplication is not in
the engine but around it:

- Three copies of "mirror the text field into the VM, run `onQueryChange`";
  two of them reset the scope on an empty field, one does not.
- Two normalizers (`SearchRelevance.normalize`, `TitleMatch.fold`) plus a
  third, weaker substring match for queue rows. "wall e" finds WALL·E in the
  Library grid but not in the queue.
- Two full-library caches: `LibraryIndex` (ownership badges, chat tools,
  TTL 10 min) and `LibraryViewModel` (the grid, TTL 5 min). An add
  invalidates only the first, and only for Radarr/Sonarr, so the grid
  reads "not owned" for up to 5 minutes.
- Two dedup functions, two loading/empty branches, three copies of "open
  the detail, with the Lidarr artist special case".
- User-visible: scope chips and the "In library" toggle exist in Queue on
  both platforms but in Library only on iOS; that iOS Library toggle
  returns nothing (its instance has no `library`); Library search pays for
  a TMDB people request it never renders; Queue search takes over the
  window, Library search does not.

## Decision

One search. One `SearchViewModel` instance per root, one bar component, one
results surface, one local-title matcher, one library cache, one detail
router. The tabs differ in exactly one input: the **local context** they
hand the surface (live queue rows vs. the browsed library). Everything
below that line looks and behaves identically, and on both tabs a live
query **takes over the window** the way the Queue tab does today.

## Architecture

### 1. Ownership

- **macOS:** `PopoverContentView` keeps its single `SearchViewModel`
  (already `@State` there, already wired with `library = libraryViewModel`)
  and passes it to *both* `QueueTabContent` and `LibraryTabContent`.
  `LibraryTabContent`'s private `searchVM` is deleted.
- **iOS:** `iOSAppRoot` already builds one instance for both tabs;
  `LibraryTab` now passes it *into* `LibraryTabContent` instead of letting
  the content create its own.
- **The query lives in the VM.** `PopoverContentView.queueFilter` and
  `LibraryTabContent.filterText` are deleted; every field binds to
  `searchVM.query` (`@Bindable`). `query` gets a `didSet` that calls
  `onQueryChange()` (the pattern `scope` and `libraryOnly` already use), so
  the three `onChange` mirror sites disappear.
- **Scope reset moves into the VM:** `onQueryChange` on an empty trimmed
  query sets `scope = .all` without re-entering itself (guard the `didSet`
  reaction; a second empty-query pass must not run). `libraryOnly` stays
  sticky, as documented today.
- `PopoverContentView.isFiltering` becomes `searchVM.isActive`
  (`!query.trimmed.isEmpty`), one definition, used by the tab-bar hide, the
  focus logic and both tabs.
- `focusInputForCurrentTab` focuses the shared bar on Queue *and* Library.
  The `@FocusState` for the macOS capsule stays in `PopoverContentView` and
  is passed down, as today for Queue.
- Entry points (`.arrBarrSearchQuery`, chat `.arrBarrOpenSearchAdd`,
  `.arrBarrTriggerAdd`, ⌘N) keep targeting this one instance; they no longer
  need to know which tab hosts the field, but ⌘N and the search intent still
  switch to Queue (unchanged behaviour, one fewer reason to differ).

### 2. One bar

- **macOS `SearchCapsule`** (new, `Views/SearchCapsule.swift`): leading
  `SearchFieldLeadingIcon` (spinner while `isSearching && isActive`),
  `TextField` bound to `searchVM.query`, clear button, and the scope menu
  (scopes from `SearchScope.available(for:)` + divider + "In library"
  toggle) lifted out of `QueueTabContent.scopeMenu`. Chrome:
  `.glassyFloatingBar(focused:)`. Prompt: `search.global.prompt`
  everywhere; `search.searchMoviesAndTv.label` is deleted if it has no
  other use.
- **iOS `SearchField`** view modifier (the existing private
  `QueueSearchField`, made shared): `.searchable(text: $searchVM.query,
  isPresented:, placement: .toolbar, prompt: search.global.prompt)` +
  `MinimizedSearchToolbar` + `autocorrectionDisabled`. `SearchScopeBar`
  stays as is and both tabs render it above their content.
- `QueueTabContent.availableScopes`, `.scopeMenu`, `.queueFilterBar` and
  `LibraryTabContent.filterBar` are deleted in favour of the above.

### 3. One results surface

`QueueSearchResultsView` is renamed `SearchResultsSurface` and generalized:

```swift
enum LocalHit: Identifiable {
    case queue(QueueRowEntry)      // live download, progress chrome
    case library(LibraryEntry)     // owned title from the browsed library
}

struct SearchResultsSurface: View {
    var searchVM: SearchViewModel
    var localHits: [LocalHit]              // host-supplied, already filtered + ordered
    let onSelectQueueItem: (QueueItem) -> Void
    let onSelectAddResult: (SearchResult) -> Void
    var onSelectPerson: (PersonRef) -> Void
}
```

Section order, unchanged from the Queue surface today: local hits → people
rows → primary "Starring X" → one merged, relevance-sorted block of library
+ add-new lookup rows → secondary "Starring X" → settled-empty state.
Local hits render at full opacity (they are never stale); lookup rows wear
`lookupReloadDim` while a refinement runs. `.queue` hits render with
`QueueSearchRow`; `.library` hits render with `SearchResultRow` through
`SearchResult(libraryEntry:)` and tap-route like any owned row.

**Narrowing** is `searchVM.scope` only. The surface's separate
`scope: QueueItem.Source?` parameter and the source-configured helpers it
duplicates (`isConfigured`, `configuredSources`) go: lookup results for an
unconfigured arr are already empty, and `SearchScope.allows` already gates
the clients. `PopoverContentView.queueScope` is deleted if nothing sets it
(verify at implementation time; if the non-search queue list still uses it,
it stays there and only leaves the search surface).

**Dedup** collapses to one function:

```swift
SearchResultDedup.removingLocalDuplicates(results: [SearchResult],
                                           localHits: [LocalHit]) -> [SearchResult]
```

A lookup row drops iff it is owned (`inLibraryArrId != nil`) and
`(source, inLibraryArrId)` is in the local key set (queue rows contribute
`(source, entityId)` for every item in a group; library hits contribute
`(source, arrId)`). Add-new rows, rows owned by another arr, and owned rows
the local match missed all stay — hiding an owned title still reads as "you
don't own it". `removingQueueDuplicates` and `removingGridDuplicates` are
deleted; their tests are folded into tests of the new function.

**Takeover host.** Both tabs render the same wrapper while
`searchVM.isActive`: pinned `searchModeHeader` (back chevron clears the
query, "queue.searching.button" title — rename the key to
`search.searching.header` since it is no longer queue-only) above a
`ScrollView` holding the surface and the "nothing rendered yet" spinner.
This wrapper is extracted from `QueueTabContent.queueOrSearch` into
`SearchTakeoverView` (macOS) and reused by the Library tab; the iOS
equivalent is the `isSearching` branch each tab already switches on.
`PopoverContentView` hides the tab bar for `.queue` **and** `.library` when
`searchVM.isActive`. On the Library tab the top strip (arr picker, status
chips, view mode, sort) is hidden under takeover on macOS too, matching
what `LibraryFilterStrip` already does on iOS.

### 4. Local context per host

- **Queue tab:** `viewModel.items(for:)` for every configured source,
  filtered by `TitleMatch.indexedFilter` over a per-item fold of
  `title + episodeTitle + subtitle` (queue lists are small; folding per
  keystroke is fine), Sonarr rows grouped with `QueueGrouping.group`, as
  today. The plain `range(of:options:)` substring match is deleted.
- **Library tab:** `visibleEntries` as today — the browsed arr's entries in
  the current sort axis, status chips applied, `TitleMatch.indexedFilter`
  over `searchIndex` — wrapped as `.library` hits. The grid itself is not
  shown under takeover; these rows *are* its answer. A user who wants the
  grid back clears the query (chevron / clear button).
- Nothing else differs between the tabs.

### 5. One matcher

- `SearchRelevance.normalize` is deleted; `SearchRelevance` calls
  `TitleMatch.fold` (same fold plus width-insensitivity — strictly a
  superset; punctuation-to-space semantics are identical).
- `SearchRelevance.splitYear` and `isPlausibleYear` move to `TitleMatch`
  as `public static func splitTrailingYear(_:)` / `isPlausibleYear(_:)`.
  `SearchRelevance` calls them. `TitleMatch.best`'s year *penalty* is a
  different concern (caller already knows the year) and stays.
- `SearchRelevance.score` (banded ranking of remote results) and
  `TitleMatch.score` (coarse ranking for chat library tools) remain
  separate: they rank different inputs for different consumers, and merging
  them would change chat tool behaviour, which is out of scope.

### 6. One library cache

`LibraryIndex` becomes the single fetch-and-cache for all four arrs;
`LibraryViewModel` becomes a projection of it.

- `LibraryIndex` gains `artists(config:)` (`LidarrLibraryRecord`) and
  `whisparrMovies(config:)` (`WhisparrLibraryRecord`) with the same
  slot/in-flight/TTL/keep-stale-on-failure rules as movies/series.
  `invalidate(_:)` handles all four sources.
- `LibraryIndex` exposes a per-source **version**: `version(for:) -> Int`,
  bumped on every fresh fetch commit and on every `invalidate`.
- `LibraryViewModel.loadIfNeeded(source:config:force:)` reads records from
  `LibraryIndex` instead of the clients, records the index version it
  unified from, and reloads when `LibraryIndex.version(for:)` differs or
  when `entries[source]` is nil. Its own `fetchedAt`/`ttl` are deleted.
  `force` calls `LibraryIndex.invalidate` first. Radarr alternate titles
  (`alternateTitleMap`) stay a `LibraryViewModel` concern, refetched only
  when the movie list actually changed (version differs).
- `SearchClient.fetchLibraryOwnership` reads Lidarr/Whisparr through two new
  `ArrLibraryMaps` functions (`lidarrByForeignArtistHash`,
  `whisparrByForeignId`) that read the index — the direct `/artist` and
  `/movie` fetches in `SearchClient` are deleted. The hash rule
  (`abs(hashValue) & 0x7fffffff`) moves into one place, `ArrLibraryMaps`,
  and the `SearchClient.unifyLidarr` side keeps producing the same key.
- After `addMovie` / `addSeries` / `addArtist` / `addAlbum` / `addScene`,
  `LibraryIndex.shared.invalidate(source)` runs for the relevant source
  (today only Radarr/Sonarr). The Library grid then refreshes on its next
  `loadIfNeeded` (tab appear or ⌘R), and realtime `fileImported`
  invalidations reach the grid for free.

### 7. One detail router

```swift
DetailRequest.open(source: QueueItem.Source, arrId: Int, title: String,
                   posterURL: URL?, posterRequiresAuth: Bool, isLidarrAlbum: Bool = false)
```

Owns the "Lidarr artist vs everything else" branch once. `DetailRequest.tap`,
`SearchViewModel.navigateToAdded` and `LibraryEntry.openDetail` all call it;
their private copies of the branch are deleted.

## Data flow (one keystroke)

1. Field writes `searchVM.query` → `didSet` → `onQueryChange()` (parse,
   generation bump, sticky loader, 300 ms debounce, or instant
   library-only answer as today).
2. Host recomputes `localHits` synchronously in `body` from its own model
   (queue rows / library entries) using `TitleMatch.indexedFilter`.
3. `SearchResultsSurface` dedups lookup rows against `localHits`, sorts
   with `SearchRelevance.sortedByRelevance`, renders sections.
4. Tap: owned → `DetailRequest.tap` → `DetailRequest.open`; add-new →
   `onSelectAddResult` → `SearchAddPanel` (hosted by the root, as today),
   which after a successful add invalidates `LibraryIndex` and navigates
   through `DetailRequest.open`.

## Error handling

Unchanged: `SearchViewModel` swallows cancellation, surfaces one
`errorMessage` per generation, `SearchLookupEmptyState` renders it.
`LibraryIndex` keeps a stale snapshot on a failed refetch; `LibraryViewModel`
keeps rendering its last entries and sets `loadFailed` only when it has
nothing, exactly as today. A version bump with a failed fetch leaves the
grid on its previous entries (the index returns the stale slot, whose
version did not advance, so no re-unify runs).

## Deletions (must be gone when done)

`LibraryTabContent.searchVM`, `.filterText`, `.filterBar`, `.remoteResults`,
`.lookupSection`, `.trimmedFilter`; `QueueTabContent.queueFilterBar`,
`.scopeMenu`, `.availableScopes`, the `onChange(of: queueFilter)` mirror;
`PopoverContentView.queueFilter`, `.isFiltering`; iOS `QueueTab`'s
`onChange(of: searchVM.query)` and `LibraryTabContent`'s
`onChange(of: filterText)`; `QueueSearchResultsView.matchesFilter`,
`.isConfigured`, `.configuredSources`, `.scopedSources`;
`SearchResultDedup.removingQueueDuplicates`, `.removingGridDuplicates`;
`SearchRelevance.normalize`, `.splitYear`, `.isPlausibleYear`;
`LibraryViewModel.fetchedAt`, `.ttl`; the Lidarr/Whisparr fetch branches in
`SearchClient.fetchLibraryOwnership`; the three private Lidarr-artist
branches replaced by `DetailRequest.open`; string keys
`library.moreResults.header` and `search.searchMoviesAndTv.label` if
unused afterwards (check with `Tools/loc`).

## Testing

SwiftUI bodies do not render under `swift test`; the surface is verified in
the running app. Unit coverage, all Swift Testing:

- `SearchResultDedupTests`: rewritten for `removingLocalDuplicates` —
  queue-group ids drop owned rows; library hits drop same-arr owned rows;
  cross-arr owned rows and add-new rows survive.
- `TitleMatchTests` (new or extended): `splitTrailingYear` keeps "1917",
  splits "dune 2024", keeps "blade runner 2049"; `fold` width-insensitivity.
- `SearchRelevanceTests`: existing cases keep passing through the
  `TitleMatch` fold (accents, "spider man").
- `LibraryIndexTests` (new): version bumps on commit and on invalidate;
  failed refetch keeps the stale slot and its version; all four sources
  invalidate.
- `LibraryViewModelTests` (new): `loadIfNeeded` re-unifies only when the
  index version changed; `force` invalidates first.
- `SearchViewModelTests`: setting `query` runs a search without an explicit
  `onQueryChange`; emptying the query resets `scope` to `.all` exactly once
  and leaves `libraryOnly` alone.
- `SearchClientTests` (ownership): Lidarr/Whisparr ownership maps come from
  `ArrLibraryMaps`, with the same hash key the lookup rows carry.

Manual pass in the app after each step (rebuild, kill, relaunch): type on
Queue and on Library on macOS; both take over, both show the scope menu and
"In library"; adding a title from Library search shows it owned in the grid
on return; "wall e" finds WALL·E in a queue row.

## Out of scope

Merging `SearchRelevance.score` with `TitleMatch.score`; Spotlight
indexing; media-server search; changing the `libraryOnly` semantics; iOS
Library takeover of the navigation bar beyond what `.searchable` already
does.
