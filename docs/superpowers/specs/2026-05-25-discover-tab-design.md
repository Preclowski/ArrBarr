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
| **LLM** | Mood-driven recommendations from the configured `ChatProvider` — user describes what they're in the mood for, LLM returns a batch of 30 titles maintained as a session pool; we client-side dedupe against the library | Radarr `movie/lookup` → add | Skip |

LLM source is hidden if no provider is configured. It is also dormant when the mood field is empty — without a mood, the bucket mixes only Discover + Library.

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
enabledSources = [Discover, Library]
if mood not empty and llmConfigured: enabledSources += [LLM]

bucket = []
for source in enabledSources:
    bucket += try await source.fetch(count: 10, filter, seed)
queue = bucket.shuffled(using: SeededRNG(seed))
```

- **Fair share:** equal quota (10) per source per fetch. If a source fails, the others still play; a small "LLM unavailable" badge surfaces in the filter bar.
- **Top-up:** when `queue.count < 5`, asynchronously fetch 10 more from each *available* source, shuffle the new slice with the same seed, and append — current card position is preserved.
- **LLM as pool, not as endpoint:** the LLM source does *not* hit the API on every top-up. It hits it once per session to fill a 30-title pool, then `fetch(count: 10)` just drains 10 from that pool. When the pool is empty, the source goes dormant and is dropped from `enabledSources` until the user clicks "more LLM suggestions" (see LLM Source Details).
- **Dedup in session:** `Set<String>` keyed by `tmdbId` or `lowercased(title)+year`. LLM duplicates of library titles are filtered here (counted against quota → we drain more from the pool to compensate).
- **Determinism:** seed enables reproducible debug sessions and future undo.
- **Prefetch:** next 3 posters preloaded via existing `RemotePoster`.

## Filter Bar

Top of the tab:

```
[ Genre ▾ ] [ Decade ▾ ] [ Runtime ▾ ] [ ✨ mood: ____________ ]   [↻ reshuffle]
```

- The mood field is shown only when an LLM provider is configured.
- The mood field is the **trigger** for the LLM source: empty mood = no LLM cards in the mix; filled mood = LLM source becomes active and seeds its pool.
- Semantics between structured filters and mood: **OR**. A card passes the filter if it matches the structured filters *or* matches the LLM's interpretation of the mood text. This intentionally widens the pool (the mood can pull in things outside your strict filters).
- Structured filters apply locally to each source's output.
- The mood text is the LLM source's primary prompt. Additionally, on first activation in a session, the LLM is asked once to translate the mood into hint-filters (genres, era, runtime hints) that we apply to Discover/Library output as the "OR mood" branch. This translation is cached for the session.
- Any filter change (structured or mood) → new seed → bucket reset and (for mood change) a fresh LLM conversation.

## LLM Source Details

**Session-scoped conversation.** The LLM source maintains a multi-turn `ChatProvider` conversation for the duration of the discover session. This is the cheapest way to avoid repeats without resending the full exclude-list on every refill.

**First turn (on mood entry or mood change):**
- System prompt: explain we're picking movies for a tinder-style UI; respond strictly as JSON `[{title, year, reason}]`; return 30 distinct titles.
- User message: the mood text, plus any active structured filters as soft hints.
- Response: 30 titles → parsed into a session pool.

**Second turn — "translate mood" (same first response can include this, or a separate quick call):**
- Ask the model to also emit hint-filters (`{genres: [...], decade: ..., runtimeRange: ...}`) representing the mood, cached for the session and OR'd against the structured filter bar when running Discover/Library.

**Drain:**
- `LLMDiscoverSource.fetch(count: 10)` pops 10 from the pool, runs Radarr `movie/lookup?term=...` on each to enrich with poster, `tmdbId`, overview (uniform card UI).
- If a returned `tmdbId` is already in `fetchAllMovies()` → dedup silently and drain another from the pool.
- Lookup failure → skip that title, drain another.

**Pool exhaustion:**
- Source goes dormant; bucket continues with Discover + Library only.
- A "✨ more LLM suggestions" button appears under the card. Click → next turn in the *same* conversation: "give me 30 more, different from before". The model has the conversation context, so we don't have to resend any exclude-list. Append to pool, mark source active again.

**Mood change:**
- New mood = new conversation (old context is no longer relevant). Fresh 30, fresh hint-filters.

## State & Errors

- `DiscoverViewModel` exposes `@Published var current: DiscoverCard?`, `queue`, `isLoading`, `error`.
- No cross-session persistence — every session starts fresh (intentional; repeats are acceptable since mood changes day-to-day).
- Per-source errors degrade gracefully: failing source is dropped from the bucket for the session, others continue. A small badge in the filter bar surfaces this.

## Tests (ArrCoreTests)

- `DiscoverBucketTests`: seed determinism; in-session dedup; top-up behavior; fair share when one source fails; LLM-dormant flow when pool empty.
- `LLMDiscoverSourceTests`: JSON parsing; pool drain; dedupe against library; fallback when Radarr lookup returns nothing; "more suggestions" appends to pool; mood change resets conversation.
- `DiscoverFilterTests`: OR semantics between structured filters and LLM hint-filters.

## Scope

**MVP** (this plan):
- New tab, three sources, bucket+seed mixing, swipe right/left with source-specific actions
- Structured filter bar (genre / decade / runtime)
- Mood field gating LLM source; session-scoped LLM conversation with 30-title pool and "more suggestions" button
- LLM-driven hint-filter translation OR'd with structured filters
- No cross-session history

**Deferred (separate future work):**
- "Watch later" list of right-swipes
- Cross-session swipe persistence
- Undo last swipe
- Swipe animations / drag gestures (MVP uses buttons + ←/→ keyboard)

## Localization

All UI strings go through `loc("Key")` per project convention.
