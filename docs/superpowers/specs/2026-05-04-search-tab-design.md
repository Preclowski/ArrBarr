# Search Tab — Design Spec
_2026-05-04_

## Overview

Add a third **Search** tab to ArrBarr's popover (alongside Queue and Upcoming). Users pick Radarr or Sonarr via sub-tabs, type a query, browse results, tap a result to open a slide-in add panel, configure quality/folder/monitoring, and add directly from the menu bar.

Lidarr is deferred — see `docs/notes/lidarr-search-future.md`.

---

## Layout

### Main tab bar
`Tab` enum gains `.search` case. Tab only renders if at least one of Radarr/Sonarr is configured. Same pill animation as existing tabs.

### Search view structure
```
[ Queue ]  [ Upcoming ]  [ Search ]

🔍  Search movies…                 ← placeholder adapts per sub-tab

[ Radarr ]  [ Sonarr ]             ← only configured arrs shown
                                     same underline style as existing sub-tabs

result rows…
```

Search fires on debounced input (300 ms). No search button. Placeholder: *"Search movies…"* / *"Search shows…"*.

Items already in the library are filtered out before display (compare against `/api/v3/movie` or `/api/v3/series` id list fetched once on tab open).

### Result row
```
[poster 26×38]  Title          year · ★rating     [+]
                Subtitle (Sonarr: season count)
```
Tapping anywhere on the row opens the add panel.

### States
- **Empty query**: blank content area (no placeholder art, keep it clean)
- **Loading**: `ProgressView` centred, replaces list
- **No results**: magnifying glass SF symbol + *"No results"* secondary text
- **Error**: same inline error style as queue sections

---

## Add Panel

Slides in like History (`historySource` pattern): search content replaced, back button top-left.

### Header
```
‹ Results          Add to Radarr   (or Sonarr)
```

### Hero
Poster (44×64, corner radius 5) + title, year/runtime, star rating, 2-line overview (truncated).

### Radarr fields
| Field | Source | Default |
|---|---|---|
| Quality Profile | `GET /api/v3/qualityprofile` | first profile |
| Root Folder | `GET /api/v3/rootfolder` | first folder |
| Monitor | inline picker | Movie Only |

Monitor options: `movieOnly`, `movieAndCollection`, `none`.

### Sonarr fields
| Field | Source | Default |
|---|---|---|
| Quality Profile | `GET /api/v3/qualityprofile` | first profile |
| Root Folder | `GET /api/v3/rootfolder` | first folder |
| Series Type | inline picker | Standard |
| Monitor | chip row | All |
| Season Folders | toggle | on |

Monitor chips: All · Future · Missing · 1st Season · None.  
Series Type options: Standard · Daily · Anime.

### Add action
- `POST /api/v3/movie` (Radarr) or `POST /api/v3/series` (Sonarr)
- Always sets `searchForMovie` / `searchForMissingEpisodes` = `true` (no "Search on Add" toggle — always on)
- **Success**: panel slides back to results; added item disappears from list (filtered as in-library)
- **Error**: red text below button, panel stays open

### Profile/folder loading
Fetched lazily when add panel opens. Show `ProgressView` in place of pickers while loading. Cache per session (don't re-fetch on every panel open).

---

## New Files

| File | Responsibility |
|---|---|
| `Services/SearchClient.swift` | `lookup()`, `addMovie()`, `addSeries()`, `fetchQualityProfiles()`, `fetchRootFolders()` — separate Radarr/Sonarr actors, thin wrappers over existing `HTTPClient` |
| `Models/SearchTypes.swift` | `SearchResult`, `QualityProfile`, `RootFolder`, `MonitorMode` |
| `ViewModels/SearchViewModel.swift` | Debounce, results state, library filter, add action, profile/folder cache |
| `Views/SearchView.swift` | Search field + sub-tabs + results list |
| `Views/SearchResultRow.swift` | Single result row |
| `Views/SearchAddPanel.swift` | Slide-in form shell + arr-specific field sections |

### Modified files
- `PopoverContentView.swift` — add `.search` to `Tab`, wire `SearchView`, pass `configStore`
- `ArrTypes.swift` — add `SearchLookupResult` decode structs (Radarr + Sonarr lookup responses)

---

## API Calls

**Radarr**
- Lookup: `GET /api/v3/movie/lookup?term=<query>`
- Library list: `GET /api/v3/movie` (all, to filter already-added)
- Quality profiles: `GET /api/v3/qualityprofile`
- Root folders: `GET /api/v3/rootfolder`
- Add: `POST /api/v3/movie`

**Sonarr**
- Lookup: `GET /api/v3/series/lookup?term=<query>`
- Library list: `GET /api/v3/series`
- Quality profiles: `GET /api/v3/qualityprofile`
- Root folders: `GET /api/v3/rootfolder`
- Add: `POST /api/v3/series`

---

## Out of Scope
- Lidarr (see `docs/notes/lidarr-search-future.md`)
- Editing existing library items
- Per-season add for Sonarr
- Language profiles
