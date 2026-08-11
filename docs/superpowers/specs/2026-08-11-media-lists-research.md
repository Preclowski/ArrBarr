# Media lists in search — research

Date: 2026-08-11. Status: research only, no code written.

Question: could ArrBarr surface curated movie/series lists ("IMDb Top 250",
"Best 1000", user lists) — searchable, browsable, and addable to the arrs?

## TL;DR

- **IMDb has no usable API.** The official one is AWS Data Exchange, ~$150k/yr.
  Every "IMDb Top 250 API" is a third party re-serving scraped data.
- **The best source is MDBList** — one free key, `/lists/search`, `/lists/top`,
  `/lists/{id}/items`, official lists, and IMDb/Trakt/Letterboxd lists mirrored
  behind `/external/lists/{id}/items`. Items carry `ids.{imdb,tmdb,tvdb}`, which
  is exactly what `MediaRef` needs.
- **`https://api.radarr.video/v1/list/imdb/top250` is free and unauthenticated**
  and returns full metadata + TMDB poster URLs. Zero-config IMDb Top 250 —
  movies only, four fixed routes.
- **TMDB is already wired** (`TMDBClient`, key in Settings). It gives dynamic
  "chart" lists (top rated / popular / trending / collections / keywords) for
  free, but has **no public-list search**.
- **Trakt is now a bad bet**: as of 2026-07-30 API app creation is VIP-only.
- **Radarr already aggregates the user's own import lists** at
  `GET /api/v3/importlist/movie`. Sonarr has no equivalent.

Recommended shape: TMDB charts + `api.radarr.video` as the always-on tier,
MDBList as an optional key that unlocks list *search*.

## Source evaluation

### 1. IMDb — not viable directly

`developer.imdb.com` sells through AWS Data Exchange, roughly $150k/yr entry.
Not an option. IMDb data reaches us only second-hand, via MDBList or
`api.radarr.video` (both of which resolve IMDb rankings to TMDB ids).

### 2. `api.radarr.video/v1` — free, no key, movies only ⭐

Radarr's own metadata proxy, used by its "IMDb Lists" import list
(`src/NzbDrone.Core/ImportLists/RadarrList2/IMDb/`). Verified live:

| Route | Result |
| --- | --- |
| `GET /v1/list/imdb/top250` | 200, full movie records |
| `GET /v1/list/imdb/popular` | 200 |
| `GET /v1/list/imdb/ur{userId}` | 200 for a real IMDb user id |
| `GET /v1/list/stevenlu` | 200, ~790 KB |

`ls########` lists are explicitly rejected upstream. No other routes exist
(`trending`, `boxoffice`, `anticipated` → 404).

Record shape (already close to `RadarrLookupRecord`):

```json
{ "TmdbId": 10098, "ImdbId": "tt0012349", "Title": "The Kid",
  "Overview": "...", "OriginalTitle": "The Kid", "OriginalLanguage": "en",
  "Runtime": 68, "Popularity": 6.94, "Year": 1921,
  "Images": [{ "CoverType": "Poster", "Url": "https://image.tmdb.org/t/p/original/…" }] }
```

Poster URLs are `image.tmdb.org` paths, so `PosterStore.sourceURL(for:tier:)`
already rewrites them to the right CDN variant. Upstream refresh interval is
12 h — cache accordingly.

Caveat: undocumented, unversioned, movies only. Treat as best-effort with a
graceful empty state, not as a hard dependency.

### 3. MDBList — the only real *list search* ⭐

`https://api.mdblist.com`, OpenAPI at `/schema/`. Auth: `?apikey=` query param
or `Authorization: Bearer`. Free tier **1 000 requests/day** (then €1–5/mo tiers
up to 250 k/day). Key comes from the user's MDBList preferences page.

Relevant endpoints:

| Endpoint | Use |
| --- | --- |
| `GET /lists/search?query=&limit=&offset=` | search public lists by name |
| `GET /lists/top?limit=&append_to_response=poster` | top public lists |
| `GET /lists/official`, `/lists/official/{slug}/items` | MDBList's own curated lists |
| `GET /lists/{listid}` / `/lists/{user}/{name}` | list metadata |
| `GET /lists/{listid}/items` | items — the workhorse |
| `GET /external/lists/{listid}` / `…/items` | mirrored IMDb / Trakt / Letterboxd lists |
| `GET /lists/recommended/{section}/items` | recommendations |

`/lists/{listid}/items` params worth using: `cursor` (preferred; `offset` is
deprecated), `limit` (default 100, max 1000), `mediatype=movie|show`,
`append_to_response=genres,poster,description,ratings`, `extended=ids_only`
(cheap prefetch), `sort=imdbrating|imdbvotes|imdbpopular|added|…`,
`filter_genre`, `released_from`/`released_to`. Score filters are supporter-only.

Response splits into `movies[]` and `shows[]`, each item:

```json
{ "id": 0, "rank": 1, "title": "…", "imdb_id": "tt…", "tvdb_id": 0,
  "ids": { "mdblist": "…", "imdb": "tt…", "tmdb": 0, "tvdb": 0 },
  "mediatype": "movie", "release_year": 1994, "language": "en", "country": "US" }
```

Pagination is signalled by `X-Has-More` / `X-Total-Items` headers plus
`next_cursor` — note that `HTTPClient` would need to expose response headers,
or we page until a short/empty page.

`ids.tmdb` / `ids.tvdb` / `ids.imdb` map 1:1 onto `MediaRef`, so every item can
be resolved through the existing `tmdb:N` / `tvdb:N` arr-lookup path.

This is the piece that makes "search for lists" — as opposed to "browse three
hardcoded charts" — actually possible.

### 4. TMDB — already wired, charts but no list search

`TMDBClient` exists with the key already in Settings (`SecretKey.tmdbKey`,
`ConfigStore.tmdbEnabled`). Free for this use.

What we can add with zero new config:

- `/movie/top_rated`, `/movie/popular`, `/tv/top_rated`, `/tv/popular`
- `/trending/{movie|tv}/{day|week}`
- `/discover/*` with `sort_by=vote_average.desc&vote_count.gte=…` — this is
  literally "best 1000", paginated, and `discoverMovies/discoverTV` already
  exist in `TMDBClient`
- `/collection/{id}` — franchise sets (LOTR, Bond)
- `/list/{list_id}` — a *specific* public TMDB list, if the user pastes an id

What we cannot do: search public TMDB lists. There is no such endpoint.

So TMDB covers "canonical charts" but not "find me a list about X".

### 5. Trakt — avoid

`/lists/trending`, `/lists/popular`, `/lists/{id}/items` are exactly right, and
items carry imdb/tmdb/tvdb ids. But **API app creation went VIP-only on
2026-07-30**, so we cannot ship a client id that every user can rely on, and
asking each user to buy VIP to get one is a non-starter. MDBList mirrors most
popular Trakt lists via `/external/lists/…` anyway.

### 6. The user's own arrs — free bonus tier

Radarr exposes `GET /api/v3/importlist/movie?includeRecommendations=&includeTrending=&includePopular=`
(`Radarr.Api.V3/ImportLists/ImportListMoviesController.cs`), returning every
movie from the user's configured import lists plus recommendations/trending/
popular, each already flagged with `isExisting` / `isExcluded` / list
membership. `POST /api/v3/importlist/movie` adds a batch.

Radarr's import list providers include TMDb List/Popular/Person/Keyword/Company,
Trakt, StevenLu, Simkl, Plex, RSS, and the IMDb presets above.
**Sonarr has no `importlist/series` controller** — only AniList, MyAnimeList,
Plex, Trakt, Custom as sync providers, with no read-back endpoint.

Two things this unlocks:

1. Zero-config "your lists" section for Radarr users, with dedupe already done
   server-side.
2. A "subscribe" action: `POST /api/v3/importlist` to create a real import list
   from a list the user is browsing, so Radarr keeps it synced. Much stronger
   than a one-shot bulk add — this is the feature that would differentiate us
   from just being a nicer list viewer.

## How this fits the existing code

The good news: most of the machinery exists.

- **Item model** — every source above yields imdb/tmdb/tvdb ids, and
  `MediaRef` (`Models/MediaRef.swift`) plus `SearchInput.ref` /
  `QueryParser.parse` already handle `tmdb:N` / `tvdb:N` lookups against the
  arrs. A list item resolves to a `SearchResult` through the exact path
  `SearchViewModel.enrich(_:)` already uses.
- **Rendering** — `PosterMetadataRow` + `RemotePoster` render rows;
  `DiscoverCardView` renders cards. A list-detail screen is a
  `PosterMetadataRow` collection, nothing new.
- **Routing** — `DetailRequest.tap(_ result:)` already forks in-library →
  detail, otherwise → `SearchAddPanel`. List rows get this for free.
- **Adding** — `SearchViewModel.addMovie/addSeries` and the
  `StoreManager.requirePro(.addTitle)` gate already exist. Bulk add is a loop
  over these (or the Radarr batch POST).
- **Posters** — MDBList `append_to_response=poster` and `api.radarr.video`
  both return `image.tmdb.org` URLs; `PosterStore` handles those natively.

What's genuinely missing:

1. **A list model.** There is no `MediaList` type anywhere. `SearchResult` is
   `Sendable` but **not** `Codable`, so anything persisted needs a projection —
   `TitleMetadataStore.Metadata` is the pattern to copy.
2. **A JSON cache with TTL.** `URLCache.shared` is globally disabled in
   `HTTPClient.swift:132` and every request uses
   `.reloadIgnoringLocalCacheData`; `TMDBClient` uses raw `URLSession.shared`
   with no caching at all. With MDBList's 1 000 req/day free tier, an actor
   cache modelled on `TitleMetadataStore` (single JSON file in Application
   Support, coalesced flush, retention sweep) is a prerequisite, not a nicety.
   A 24 h TTL on list items and 6 h on list search results keeps a normal
   session well inside budget.
3. **The MDBList key plumbing** — six touchpoints, all copyable verbatim from
   TMDB: `SecretKey.mdblistKey` + `syncable` (`SecretStore.swift:24-40`),
   `@Published var mdblistApiKey` (`ConfigStore.swift:140`), legacy defaults
   key, load, sink, `var mdblistEnabled` (`ConfigStore.swift:692`), plus
   `MonitoredService.probeTargets` and a `SecureField` +
   `ApiKeyTestButton(service:)` in `SettingsView.swift:208-232`.
4. **Batch resolution + rate limiting.** A 250-item list means 250 arr lookups
   if done naively. Resolve lazily per visible row, and cross-reference against
   `SearchClient.fetchLibraryArrIdMap()` (foreignId → arr id) up front so
   "already in library" is a local set membership test, not N requests.

Dormant code worth reusing: `DiscoverViewModel.configure(tmdb:library:llm:)`
and all of `DiscoverSources.swift` are currently dead (no call sites) — the
`TMDBSource` slot was never implemented. A list could be fed into the Quiz deck
via `seed(items:)` for free, and "swipe through IMDb Top 250" is a better use of
that deck than the current chat-only seeding.

## Proposed feature shape

Three tiers, shippable independently:

**Tier 1 — charts, no new config.** A "Browse" section in search's empty state:
IMDb Top 250 (`api.radarr.video`), TMDB Top Rated / Popular / Trending for
movies and series. Pure additive, works for every user today. Answers the
"top 250 / best 1000" part of the question outright.

**Tier 2 — list search (needs an MDBList key).** Typing in search also queries
`/lists/search`, and results render as a "Lists" section above title results
(or behind a `Titles | Lists | People` segmented control — note
`docs/superpowers/plans/2026-08-11-people-search-and-person-view.md` is landing
a third result kind too, so this decision should be made once for both).
Tapping a list opens a list-detail screen: header (name, owner, item count,
poster mosaic), sort/mediatype filter, rows with in-library badges, and
"Add all missing".

**Tier 3 — subscribe.** `POST /api/v3/importlist` on Radarr so the list stays
synced, with the list-detail header showing subscribed state. Radarr-only;
Sonarr users get bulk-add only.

## Open questions

- Where do lists live: a section inside search, a segmented control, or their
  own tab? Depends on the people-search decision landing at the same time.
- Is MDBList a Control (paywalled) feature or free-with-your-own-key? The TMDB
  precedent is free-with-your-own-key; `.addTitle` already gates the adds.
- Do we persist "favourite lists" locally? Needs the `Codable` projection from
  point 1 either way.
- Mixed-media lists: MDBList returns `movies[]` + `shows[]` in one response, so
  a single list can need both Radarr and Sonarr. Row actions must be per-item,
  and "Add all" must fan out to two services (and skip kinds the user hasn't
  configured).
- `X-Has-More` / `next_cursor` pagination needs response headers from
  `HTTPClient`, which currently doesn't surface them.
