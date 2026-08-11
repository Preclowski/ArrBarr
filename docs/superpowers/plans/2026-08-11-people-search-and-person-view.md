# People: person view, actor search, unified cast pipeline

Date: 2026-08-11. Status: designed, not implemented.

## Goals

- A dedicated **person view** (photo, bio, filmography) reachable from cast
  strips, search and (later) chat — cast heads stop ejecting to the browser.
- **Search by actor**: in universal search, a strong person match adds a
  "Starring X" section of *title rows* (never person cards); an explicit
  "People" filter or `person:` prefix shows person rows.
- **Search scope filter** on the input: All (default) / Movie / Series /
  Album / People / Whisparr — scoping which backends fire at all.
- **Rewrite the cast pipeline** — today cast fetching is duplicated across
  `DetailView` (2 funcs) and `SearchAddPanel`, with no caching and no shared
  mapping. One provider, one cache, every surface a consumer.
- macOS **person tooltip** on cast heads.
- Series cast reliability: fall back to TMDB `/find` by tvdbId when Sonarr
  doesn't ship `tmdbId`.

Non-goals: crew (directors etc.) beyond what credits already carry; person
data persistence across launches; Whisparr/Lidarr people.

## Layered design

### 1. TMDBClient additions (wire layer)

- `personDetails(id:)` → `TMDBPersonDetails`: `biography`, `birthday`,
  `deathday`, `place_of_birth`, `imdb_id`, `popularity`. Localized biography
  with `language=en` fallback when the localized one is empty (two-request
  worst case, cached).
- Decode more of what's already on the wire (no new calls):
  - `TMDBPerson`: `popularity`, `known_for` (top-3 titles — free "known for").
  - `TMDBCreditPerson`: `order` (billing position).
- `tvExternalIds(tmdbId:)` → tvdbId (the reverse of the existing
  `tvIdFromTVDB`) for resolving a filmography series row into Sonarr.

### 2. `PersonStore` (cache + lazy loading) — the single owner of people data

`@MainActor final class PersonStore` (singleton like `PosterStore`), holding:

```swift
struct PersonBundle {
    var summary: TMDBPerson              // from search or a credit tap
    var details: TMDBPersonDetails?      // lazy: /person/{id}
    var movieCredits: [TMDBMovieSummary]?// lazy: /person/{id}/movie_credits
    var tvCredits: [TMDBTVSummary]?      // lazy: /person/{id}/tv_credits
}
```

- **Request coalescing**: an in-flight `Task` map keyed by
  `(personId, facet)` — a tooltip hover and a simultaneous view push share
  one fetch. This is the core lazy-loading contract: *nothing* is fetched
  until a consumer asks, and no facet is fetched twice.
- **Bounded**: LRU cap (~50 people), session-lifetime only. Headshots ride
  the existing `PosterStore` (memory+disk) — no new image cache.
- Library cross-ref lives here too: `ownedCredits(for:)` joins movie credits
  against `radarrLibraryByTMDBId()` (already exists) and series against the
  local Sonarr library by title+year (exact tvdb mapping is resolved lazily,
  per tapped row, via `tvExternalIds`).
- Demo mode: `DemoMocks+People` fixtures served from the same store paths.

### 3. `CastProvider` — the "actors rewrite"

Kill the three duplicated fetchers (`DetailView.fetchMovieCast`,
`DetailView.fetchSeriesCast`, `SearchAddPanel.loadCast`). One service:

```swift
@MainActor enum CastProvider {
    static func movieCast(arrId: Int?, tmdbId: Int?) async -> [CastMember]
    static func seriesCast(tmdbId: Int?, tvdbId: Int?) async -> [CastMember]
}
```

- Movie: Radarr `/credit` first (no key needed), TMDB fallback — the logic
  DetailView has today, now shared and **cached per title** (small LRU; the
  add panel and the detail view of the same title stop double-fetching).
- Series: TMDB by `tmdbId`; when Sonarr didn't ship one, resolve through
  `tvIdFromTVDB(tvdbId)` (this fallback is the fix for "series show no
  cast"). Requires decoding `tvdbId` in `SonarrSeriesDetail`.
- `CastMember` keeps `tmdbPersonId` (already added) — the hook for taps and
  tooltips.

### 4. Person relevance (scoring)

New `PersonRelevance` beside `SearchRelevance`, unit-tested like it:

- **Person match** (who is "the" person for a text query): reuse
  SearchRelevance's word-order-free, punctuation-folded name matching ×
  `log(1 + popularity)`; prefer `known_for_department == "Acting"` on ties.
  Universal search shows the section only above a conservative threshold —
  "Alien" must not surface random people.
- **Filmography order**: `bayesianRating × log(1 + popularity) ×
  billingWeight(order) + libraryBoost`, release date as tiebreak only.
  `billingWeight` decays with `order` and penalises empty/"Self" characters
  (keeps cameos and talk shows out of the top). Chronological sort offered
  as a toggle on the person view, never the default.
- Never mixed into title ranking — person-driven titles render in their own
  section; the scales aren't comparable.

### 5. Search UX

**Scope filter on the input**: a compact menu chip inside the search field's
trailing edge (mirrors the tab "⋯" pattern): All · Movie · Series · Album ·
People · Whisparr. Default All; resets to All on panel close (a sticky
narrow scope is a support ticket). Scope gates *which clients fire* — Album
scope never hits Radarr, People scope only hits TMDB. Whisparr appears only
when configured (same visibility rule as its tab/section today).

**Universal (All)**: current per-arr lookups unchanged; in parallel, one
`searchPerson` call. Strong match → section under the title results:
`Starring Tom Hanks` header (headshot 24pt + name), top 5–8 credits as
regular `SearchResultRow`s (library badge, add flow — reused as-is; TMDB
summaries map through ONE shared `SearchResult` mapper, extracted from the
near-identical code in `DiscoverSources` / `LocalToolBackend+TMDB` — that's
the no-duplication part), footer `Full filmography →` pushing the person
view.

**People scope / `person:` prefix**: person *rows* are intended here (the
user explicitly asked for people): headshot, name, known-for line; tap →
person view. `person:` extends the existing `SearchInput` prefix parsing
(`imdb:`, `tmdb:` …). No person rows ever appear in All.

**Gating**: everything people-related requires a TMDB key. Without one, the
People scope shows an empty state pointing at Settings; the section and
tooltips simply don't render; cast strips keep working (movies via Radarr).

### 6. Person view

Pushed as a `navigationDestination` on all three surfaces (popover,
detached window — self-drawn back header per the detached-window rule —
and iOS). Layout reuses the detail grammar:

- Header: circular photo (tap = lightbox), name, `age · birthplace` line,
  biography in `ExpandableOverview`, `In library: N` counter chip.
- `Movies / Series` picker (segmented), filmography as `SearchResultRow`s
  ordered by PersonRelevance; skeleton rows while a facet loads.
- Row tap: owned → existing DetailView; not owned → existing add flow.
  Series rows resolve tvdbId lazily on tap (one `tvExternalIds` call).
- Footer links: TMDB page, IMDb page (from `imdb_id`) — the external links
  move HERE from the cast strip.

Entry points: cast heads (everywhere `CastRow` renders — movie detail,
series detail, add panel), the search section footer, person rows, macOS
tooltip footer. `CastRow` gains `onTapPerson: ((CastMember) -> Void)?`;
when nil (no TMDB key) heads stay inert.

### 7. macOS tooltip on cast heads

Same 600ms-hover + `tooltipPopover` recipe as queue rows. Instant layer:
photo, name, "as {character}". Async layer via `PersonStore` (spinner-free
skeleton lines): age/birthplace, 3-line bio, "Known for: …", "In your
library: N". Footer `Filmography →`. Hover does NOT prefetch until the
600ms gate fires — a mouse sweep across 16 heads must not fire 16 fetches.

### 8. Series cast heads

- Fix the silent no-cast case via the `tvdbId` fallback (§3).
- Surfaces: series detail (already renders `CastRow`), add panel (already);
  season view gets the same strip (data identical, one line once
  `CastProvider` exists). Episode overlay stays cast-free (scope).

## Rollout

1. `PersonStore` + `CastProvider` refactor (behaviour-neutral) + series
   tvdbId fallback + shared TMDB→SearchResult mapper. Tests: mapper,
   coalescing.
2. Person view + cast-head navigation (external links move into the view).
3. Search: scope filter chip (client gating) — independent value even
   without people.
4. Universal "Starring X" section + People scope + `person:` prefix +
   PersonRelevance (tests mirror SearchRelevanceTests).
5. macOS tooltip.
6. Demo fixtures (`DemoMocks+People`) + localization keys + CHANGELOG.

## Risks

- TMDB dependency becomes user-visible outside AI — empty states must sell
  the fix ("add a TMDB key"), not just apologise.
- `SearchViewModel` grows a fifth result source; keep the person path in
  its own extension file to avoid a god-object.
- Person-section threshold tuning needs real-world queries; ship behind a
  conservative threshold and loosen with feedback.
