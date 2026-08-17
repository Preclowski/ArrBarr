# Agent Tools & Quiz Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chat agent's library tools precise and cheap (sort/limit server-side), make Quiz decks build fast (parallel resolution, zero-HTTP library decks), fix the series anchor id bug, and lay the swipe-signal foundation for taste-aware discovery.

**Architecture:** All changes live in ArrCore. Tool schemas change in `ChatToolCatalog`, implementations in `LocalToolBackend+*`, deck plumbing in `DiscoverSources`/`DiscoverViewModel`, persistence in a new `SwipeSignalStore`. No new external dependencies.

**Tech Stack:** Swift 6 tools / v5 language mode, Swift Testing (`@Test`/`#expect`), SwiftPM tests in `Packages/ArrCore`.

**Restore point:** commit `a6a4e59` (2.0.0-rc3).

Design provenance: three-round discussion + architect review + UX review (2026-08-17
chat session). Key decisions: keep per-service tools (no merged `library_query`);
no lazy deck resolution (owned-filter must finish before seed); pool-then-draw
randomness for decks, deterministic sort for chat; skips are cooldowns (14 d)
not permanent; `/recommendations` over `/similar` for anchors.

---

## Phase 1 — performance & correctness quick wins

### Task 1: Bounded-parallel pick resolution in `discover_in_quiz`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend+Discover.swift` (the sequential `for pick in capped` loop, ~line 72; also fix the lying "60 parallel lookups" comment)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverQuizToolTests.swift` (extend if present, else covered by build + existing tests)

- [x] Replace the sequential loop with a `withTaskGroup` fan-out capped at 8 concurrent lookups, preserving input order via `(index, DiscoverItem?)` results. Same mapping code, same owned cross-ref (`libraryMapFetch` awaited once before the group).
- [x] Same treatment for the inner `for s in summaries.prefix(5)` loops inside `fetchSimilarForAnchors` (already parallel across anchors; make them parallel within an anchor too, cap shared).
- [x] `(cd Packages/ArrCore && swift test)` green.
- [x] Commit: `perf(discover): resolve quiz picks in parallel, not one by one`

### Task 2: Parallelize `DiscoverSources.llm` resolution

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift` (~lines 148–197)

- [x] Same bounded task-group pattern for the per-suggestion `radarrLookup`/`sonarrLookup` calls; order preserved.
- [x] Tests green; commit: `perf(discover): parallel lookup resolution in the Discover tab's LLM source`

### Task 3: `sort` + `limit` on the library list tools

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LibraryFilter.swift` (add `sort`/`limit` to `LibraryQuery`; add `LibrarySort` enum: `rating`, `year`, `title`, `added`, `random`; apply after facet filters)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend+Library.swift` (parse args, honor limit, header states sort + counts)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ChatToolCatalog.swift` (schema + description updates for `radarr_get_movies`, `sonarr_get_series`)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibraryFilterTests.swift`

- [x] Failing tests first: sort by rating desc, year asc/desc, limit caps rows, `added` parses arr ISO dates, unrated sorts as 6.0 average under `rating`.
- [x] Implement; header line becomes e.g. `Radarr library — 10 of 412 movies match unwatched · sorted by rating desc:`.
- [x] Catalog: `sortBy` (enum string) + `limit` (integer, default 100/cap 100 for filtered, honored for samples too) documented so "top 10" is one call.
- [x] Tests green; commit: `feat(tools): sort and limit on the library list tools`

### Task 4: Series anchors use real TMDB ids + `/recommendations`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/TMDBClient.swift` (add `recommendedMovies(movieId:)`, `recommendedTV(seriesId:)` — same shape as `similarMovies`/`similarTV`)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend+Discover.swift` (`fetchSimilarForAnchors` calls the recommendations endpoints)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift`, `LocalToolBackend+Discover.swift` — populate `SearchResult.tmdbTVId` on series rows built from lookup/library records (field exists, quiz paths leave it nil)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ChatToolCatalog.swift` (`anchor_tmdb_ids` description: for series these MUST be TMDB tv ids, which tool output now carries)

- [x] `(cd Packages/ArrCore && swift test)` green.
- [x] Commit: `fix(discover): series anchors walk TMDB recommendations with real TMDB ids`

### Task 5: `tmdb:`/`tvdb:` lookup shortcut for known ids

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend+Discover.swift`, `LocalToolBackend+ArrTools.swift` (`suggestItems` parses optional `tmdbId`; term becomes `tmdb:N` / `tvdb:N` when present)
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ChatToolCatalog.swift` (`items` schema gains optional `tmdbId`)

- [x] Tests green; commit: `feat(tools): exact-id lookup terms for suggest/quiz picks`

## Phase 2 — deck sources & card UX

### Task 6: Library-sourced decks (zero HTTP)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/LocalToolBackend+Discover.swift` — when `library_mode == "library"`, `items` becomes optional; fill from `LibraryIndex` + `LibraryFilter` with new optional `genre`/`startYear`/`endYear`/`unwatched` args; pool-then-draw: top 60 by rating → shuffle → take 20.
- Modify: `ChatToolCatalog.swift` (schema/description)
- Test: pool-then-draw is pure → unit test the draw helper.

- [x] Commit: `feat(quiz): library decks come straight from the cached snapshot`

### Task 7: "Why this card" reason line

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Models/DiscoverItem.swift` (add `reason: String?`)
- Modify: `LocalToolBackend+Discover.swift` (curated items accept optional `reason` from the model; anchor items get "Similar to <anchor title>"; library items "From your library")
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift` (card renders the line when present)
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` (new keys)

- [x] Commit: `feat(quiz): every card can say why it was picked`

### Task 8: Persistent swipe signals with cooldown

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/SwipeSignalStore.swift` — UserDefaults-backed, capped (500), entries `{key, kind: kept|skipped|veto, date, count}`; skip cooldown 14 days, 2+ skips → 90 days, veto permanent; `isSuppressed(key:)`, `record(...)`, `reset()`.
- Modify: `DiscoverViewModel.swift` (record swipes; expose for deck filtering)
- Modify: `LocalToolBackend+Discover.swift` (deck assembly drops suppressed keys, reports count)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SwipeSignalStoreTests.swift`

- [x] Commit: `feat(quiz): swipes persist — skips cool down instead of vanishing`

## Phase 3 — taste profile & panels (follow-up plan)

Deliberately split out; each needs its own UI design pass:
- Taste-profile generation (FoundationModelsProvider, on-device) + Settings pane (profile paragraph, signals list, watch-history aggregates + search/exclude).
- Chat→quiz handoff card (no popover hijack) + MCP surface-appropriate output.
- Cold-start starter deck; session length cap; catalog token-cost measurement and system-prompt consolidation.
