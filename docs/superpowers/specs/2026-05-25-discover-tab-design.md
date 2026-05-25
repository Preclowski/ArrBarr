# Discover Tab — Design Spec

**Date:** 2026-05-25 (revised after architecture review)
**Status:** Approved, ready for plan

## Goal

Add a Tinder-style "Discover" tab to ArrBarr's popover that surfaces movie suggestions from three sources — blended fairly, with source-appropriate swipe actions, reusing as much existing machinery as possible.

## Sources

| Source | What it returns | Swipe right (👍) | Swipe left (👎) |
|---|---|---|---|
| **TMDB Discover** | Movies *not* in user's library, via existing `TMDBClient.discoverMovies(...)` | Add to Radarr (same flow as Search tab uses) | Skip for this session |
| **Library** | Random movies *in* library (Radarr `fetchAllMovies`), filtered by decade + monitored toggle | Open `DetailView` | Skip |
| **LLM** | Stateless completion call seeded by user's mood text; returns N titles, each enriched via Radarr `movie/lookup` | Add to Radarr (if not already there) / Open detail (if owned) | Skip |

LLM source is hidden when no provider is configured *or* when the mood field is empty.

## Surface

New tab in `Views/PopoverContentView.swift` alongside Queue / Upcoming / History / Search. Mirrors the shape of the Search tab.

## Reuse Map (deduplication-first)

| Need | Existing primitive | New code? |
|---|---|---|
| Unified result model | `Models/SearchTypes.swift` → `SearchResult` (title, year, overview, runtime, genres, poster, ratings, `inLibraryArrId`) | None — wrap in `DiscoverItem` |
| TMDB discover endpoint | `Services/TMDBClient.swift` → `discoverMovies(...)` | None |
| LLM call | `Services/LLMProvider.swift` → `respond(prompt:tools:history:)` | None — stateless single-shot |
| Movie lookup for LLM titles | `Services/RadarrClient.swift` → `movie/lookup` (also wrapped by `SearchClient`) | None |
| Add movie to Radarr | Existing flow from Search tab | None |
| Card body rendering | `Views/MediaHeaderCard.swift` + `Views/RemotePoster.swift` | None — just compose |
| Open detail | Existing `DetailView` push from PopoverContentView | None |
| Tab wiring pattern | `Views/SearchView.swift` + `ViewModels/SearchViewModel.swift` (closest precedent) | Mirror |

## Architecture

New files inside `Packages/ArrCore/Sources/ArrCore/`:

```
Models/
  DiscoverItem.swift          # { result: SearchResult; action: DiscoverAction }
ViewModels/
  DiscoverViewModel.swift     # three async sources + round-robin + dedup
Views/
  DiscoverTabView.swift       # filter bar + current-card stack + action buttons
  DiscoverFilterBar.swift     # decade picker, monitored toggle, mood field
```

No new protocol abstraction over sources — the three are too different to share a contract usefully, and the VM is small enough to call them directly.

```swift
enum DiscoverAction {
    case addToRadarr        // TMDB / LLM-when-not-owned
    case openDetail         // Library / LLM-when-owned
}

struct DiscoverItem: Identifiable {
    let id: String           // tmdbId-or-titleYear, used as dedup key
    let result: SearchResult
    let action: DiscoverAction
}
```

## ViewModel — round-robin without a bucket

```swift
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var current: DiscoverItem?
    @Published var queue: [DiscoverItem] = []
    @Published var filter = DiscoverFilter()
    @Published var moodText: String = ""
    @Published var llmPoolExhausted = false
    @Published var error: String?

    private var seenIds = Set<String>()
    private var llmExclude: [String] = []     // titles already shown by LLM
    private var rrIndex = 0                    // round-robin pointer

    func start() async { … }                   // first 10 per source
    func nextSourceIndex() -> Int { … }        // skips exhausted/dormant sources
    func topUpIfNeeded() async { … }           // when queue < 5
    func swipe(_ item: DiscoverItem, right: Bool) async { … }
    func requestMoreLLM() async { … }          // re-call with updated exclude list
}
```

Round-robin order: `[tmdb, library, llm]`, skipping any source that is exhausted (TMDB page run out) or dormant (LLM with no mood / pool empty). Dedup is a single `Set<String>` keyed by the item's `id`. No seeded RNG, no shared "bucket" type, no source protocol.

## LLM Source — stateless with exclude-list

The architecture review surfaced that `LLMProvider` has no server-side session, so any "more suggestions" call has to resend its own exclude context. Embrace it instead of fighting it.

**Request shape (one shot per "more" press):**
- System: "You recommend movies for a tinder-style picker. Reply only as JSON array `[{title, year, reason}]`."
- User: `"Mood: <user mood text>. Active filters: <decade if set>. Suggest 20 movies. Do NOT include any of these already-shown titles: <comma-separated exclude list>."`

**Drain:**
1. Parse JSON → titles.
2. For each: `RadarrClient.movie/lookup?term="<title> <year>"`. Use first match. If lookup finds `tmdbId` already in the local Radarr library, mark the resulting `DiscoverItem.action = .openDetail`; otherwise `.addToRadarr`.
3. Append exclude list with `"title (year)"` for every produced item.
4. Lookup miss → drop title silently.

**Pool exhaustion / "more" button:** when the LLM pool is drained, the source goes dormant and a "✨ more LLM suggestions" button appears under the current card. Click → another stateless call with the cumulative exclude list. The exclude list grows linearly with shown titles; for a typical session (<60 titles) this is well within prompt budget.

**Mood change:** clears exclude list, clears LLM pool, marks source active.

## Filter Bar

```
[ Decade ▾ ] [ ◯ Monitored only ] [ ✨ mood: ____________ ]   [↻ reshuffle]
```

- **Decade** + **Monitored only** apply to TMDB Discover (year range) and Library (in-memory filter on `RadarrLibraryRecord`). LLM ignores them (mood is its only directive).
- **Mood** is the LLM trigger and is shown only when a provider is configured. Empty mood = LLM dormant.
- **Reshuffle** = clear queue, re-fetch all active sources, reset seen-set kept *only* for this session.

No genre or runtime filter in MVP — `RadarrLibraryRecord` carries neither and we explicitly chose not to extend `fetchAllMovies` for MVP. Discoverable in a follow-up if needed.

## State & Errors

- Per-source error degrades that source for the session and surfaces a small badge in the filter bar; the other sources continue.
- No cross-session persistence. Every tab open starts fresh.
- LLM JSON parse failures → drop the response, surface "LLM gave invalid response", stay dormant until next "more" click.

## Tests (ArrCoreTests)

- `DiscoverViewModelTests`:
  - Round-robin skips exhausted / dormant sources.
  - Dedup never yields the same `id` twice in a session.
  - Top-up fires when queue drops below threshold and doesn't reorder current card.
  - Per-source failure drops that source only.
- `LLMDiscoverTests`:
  - Prompt builder produces correct exclude list across multiple "more" calls.
  - JSON parsing is tolerant of trailing prose / code fences.
  - Items already in Radarr library get `.openDetail` action; rest get `.addToRadarr`.
  - Mood change clears state.

## Scope

**MVP (this plan):**
- New tab; three sources (TMDB Discover, Library, LLM); round-robin + dedup in the VM.
- Filter bar: decade + monitored + mood (mood gates LLM).
- Card body via `MediaHeaderCard` + `RemotePoster`; swipe via two buttons + ←/→ keyboard.
- Swipe-right actions per source as described.
- "More LLM suggestions" button when LLM pool empties.

**Deferred:**
- Genre / runtime filters (would require enriching `RadarrLibraryRecord` via fuller `fetchAllMovies` payload).
- "Watch later" list of right-swipes.
- Cross-session swipe history.
- Undo last swipe.
- Drag gesture / animated card stack (MVP uses buttons + keyboard).

## Localization

All UI strings via `loc("Key")` per project convention.
