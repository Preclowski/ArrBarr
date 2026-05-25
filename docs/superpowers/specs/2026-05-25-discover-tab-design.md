# Discover Tab — Design Spec

**Date:** 2026-05-25
**Status:** Approved, ready for plan

## Goal

Add a Tinder-style "Discover" tab to ArrBarr's popover that surfaces movie suggestions from three sources, blended fairly, with source-appropriate swipe actions.

## Sources

| Source | What it returns | Swipe right (👍) | Swipe left (👎) |
|---|---|---|---|
| **Radarr Discover** | Movies *not* in library, from Radarr's recommendations / import-list endpoint (exact endpoint TBD during plan, depending on Radarr API version) | Add to Radarr (monitor + `searchMovie`) | Skip for this session |
| **Library (existing)** | Random movies *in* library, matching active filters — a mood picker over what you already own | Open `DetailView` | Skip |
| **LLM** | Blind recommendations from the configured `ChatProvider`; we client-side dedupe against the library | Radarr `movie/lookup` → add | Skip |

LLM source is hidden if no provider is configured.

## Surface

New tab in `PopoverContentView` alongside Queue / Upcoming / History. No separate window.

## Architecture

New module inside `Packages/ArrCore/Sources/ArrCore`:

```
Models/
  DiscoverCard.swift            # unified card (poster, title, year, overview, runtime, genres, source, payload)
  DiscoverFilter.swift          # genres / decade / runtime / monitored + moodText
Services/
  DiscoverSourceProtocol.swift  # async fetch(count, filter, seed) -> [DiscoverCard]
  RadarrDiscoverSource.swift    # /api/v3/movie/discover (recommendations)
  RadarrLibrarySource.swift     # uses existing fetchAllMovies + local filter
  LLMDiscoverSource.swift       # ChatProvider prompt -> JSON titles -> Radarr lookup for enrichment
  DiscoverBucket.swift          # mixing, seed, prefetch, dedup
ViewModels/
  DiscoverViewModel.swift
Views/
  DiscoverTabView.swift
  DiscoverCardView.swift        # poster + overview + badges + action buttons
  DiscoverFilterBar.swift
```

`DiscoverCard.source` is an enum:

```swift
enum CardSource {
    case radarrDiscover(tmdbId: Int)
    case library(movieId: Int)
    case llm(title: String, year: Int?)
}
```

The view renders all cards identically; only the action buttons and labels differ per source.

## Mixing Algorithm — Bucket + Seed

```
SessionSeed = UInt64 (time-based on tab open; reseeded on pull-to-refresh or filter change)
bucket = []
for source in enabledSources:
    bucket += try await source.fetch(count: 10, filter, seed)
queue = bucket.shuffled(using: SeededRNG(seed))
```

- **Fair share:** equal quota (10) per source per fetch. If a source fails, the others still play; a small "LLM unavailable" badge surfaces in the filter bar.
- **Top-up:** when `queue.count < 5`, asynchronously fetch 10 more from each source, shuffle the *new* slice with the same seed, and append — current card position is preserved.
- **Dedup in session:** `Set<String>` keyed by `tmdbId` or `lowercased(title)+year`. LLM duplicates of library titles are filtered here (counted against quota → we fetch more to compensate).
- **Determinism:** seed enables reproducible debug sessions and future undo.
- **Prefetch:** next 3 posters preloaded via existing `RemotePoster`.

## Filter Bar

The diagram below shows the full vision. In MVP the mood field and reshuffle button are deferred (see Scope).

Top of the tab:

```
[ Genre ▾ ] [ Decade ▾ ] [ Runtime ▾ ] [ ✨ mood: ____________ ]   [↻ reshuffle]
```

- The mood field is shown only when an LLM provider is configured.
- Semantics: **OR** between structured filters and mood. A card passes if it matches the structured filters *or* matches the LLM's interpretation of the mood text.
- Structured filters apply locally to each source's output.
- Mood text is appended to the LLM source's prompt. For Discover/Library, the mood is translated into hint-filters by the LLM once per session (no LLM available → mood ignored for those sources).
- Any filter change → new seed → bucket reset.

## LLM Source Details

- Prompt asks for JSON: `[{title, year, reason}]`.
- For each returned title we call Radarr `movie/lookup?term=...` to enrich with poster, `tmdbId`, overview — so the card UI stays uniform.
- If a returned `tmdbId` is present in `fetchAllMovies()`, dedupe (skip silently, fetch more to keep quota).
- Lookup failure → skip that title.

## State & Errors

- `DiscoverViewModel` exposes `@Published var current: DiscoverCard?`, `queue`, `isLoading`, `error`.
- No cross-session persistence — every session starts fresh (intentional; repeats are acceptable since mood changes day-to-day).
- Per-source errors degrade gracefully: failing source is dropped from the bucket for the session, others continue. A small badge in the filter bar surfaces this.

## Tests (ArrCoreTests)

- `DiscoverBucketTests`: seed determinism; in-session dedup; top-up behavior; fair share when one source fails.
- `LLMDiscoverSourceTests`: JSON parsing; dedupe against library; fallback when Radarr lookup returns nothing.
- `DiscoverFilterTests`: OR semantics between structured filters and mood text.

## Scope

**MVP** (this plan):
- New tab, three sources, bucket+seed mixing, swipe right/left with source-specific actions
- Structured filter bar (genre / decade / runtime)
- No mood field, no cross-session history

**Deferred (separate future work):**
- Mood field + LLM-driven filter translation for Discover/Library
- "Watch later" list of right-swipes
- Cross-session swipe persistence
- Undo last swipe
- Swipe animations / drag gestures (MVP uses buttons + ←/→ keyboard)

## Localization

All UI strings go through `loc("Key")` per project convention.
