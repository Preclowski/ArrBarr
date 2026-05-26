# Queue search — status-grouped results

## Problem

When the user types into the queue tab's floating filter bar, the
result layout is hard to scan. With the default scope ("All"):

- Queue rows are grouped per arr ("Movies", "Series", …).
- Search results (library / new) appear in a *second* block, also
  grouped per arr.
- The same title can surface twice — once as a queue row inside its
  arr section, once as a library hit inside the same arr's search
  block.
- Per-row badges ("In library" / "New") encode the status the user
  is most likely scanning for, but it sits at the row level under an
  arr header — two axes of grouping fighting for primacy.

The status axis (`In queue` / `In library` / `New`) already exists
in the model as `QueueResultType`, and `typeGroupedSections` already
renders it — but only when the user narrows scope to a single arr.
For the default "All" scope, the source axis dominates.

## Goal

When the user is searching, **status** is the only header-level
grouping. Source drops to a row-level glyph. Each title appears once.

## Trigger

The pivot is bound to `queueFilter`:

- **Empty filter** → today's layout. Per-arr queue sections,
  tonight/needsYou, "Next week" banner. No change.
- **Non-empty filter** → status-grouped layout. Tonight / needsYou /
  Next-week banner stay hidden (already current behaviour).

## Layout when filtering

Three sections, fixed order, each with the existing
`typeSectionHeader` chrome (small uppercase label + count):

1. **IN QUEUE** — `QueueRowEntry`s from `viewModel.entries` whose
   title matches the filter.
2. **IN LIBRARY** — `SearchResult`s with `inLibraryArrId != nil`.
3. **NEW** — `SearchResult`s with `inLibraryArrId == nil`.

Empty sections are omitted entirely (no `IN QUEUE (0)` headers).

No per-arr sub-headers. The source identity lives on the row as a
glyph (see Row anatomy).

### Two render modes

The current three branches in `queueBody` collapse to two:

| State | Layout |
|---|---|
| `queueFilter.isEmpty` | Today's per-arr queue sections. |
| Filtering, `queueResultType == .all` | Status-grouped sections (1/2/3 above). Same code path regardless of `queueScope`. |
| Filtering, `queueResultType != .all` | Flat list of just the picked kind. No header (redundant with the type pill). Same as today's "Mode 3". |

`typeGroupedSections(for:)` becomes scope-agnostic. When
`queueScope == nil`, it pulls from all configured sources and
concatenates per status section. When `queueScope == .sonarr`, it
pulls only that source. Same output shape either way.

## Row anatomy

All three sections use the same visual rhythm =
`SearchResultRow` / `PosterMetadataRow`:

- Poster 26×38 (or blurred per `configStore.shouldBlurPoster`).
- Title + year.
- Second-line metadata (subtitle / ratings / runtime / certification).
- **Title badge slot**: source glyph (`film` / `tv` / `music.note` /
  `popcorn` — the same `QueueItem.Source.symbol` already used in
  the per-arr section headers and poster fallbacks). Small,
  secondary tint. Replaces today's `InLibraryBadge` / `NewBadge`.
- **Trailing affordance**, varies per section:
  - **In Queue**: compact status label. Format: `"62% · 12 min"` for
    active downloads, `"queued"` for queued, `"paused"` for paused,
    `"stalled"` for stalled. Tap → `DetailView`.
  - **In Library**: chevron `›`. Tap → `DetailView`.
  - **New**: `+`. Tap → `SearchAddPanel`.

## De-duplication

If a `SearchResult` with `inLibraryArrId == X` matches a queue
entry whose underlying arr entity id is also `X` (same source),
the queue row wins. The library section drops it.

Implementation: when building the library list, filter out results
whose `(source, inLibraryArrId)` pair matches any
`(source, entityId)` of the rows that will appear in IN QUEUE for
the current filter.

## Compact queue row

The existing `QueueRowView` (full progress bar, inline
pause/delete, etc.) is the right thing for the default queue view,
not for a search-result row. During filtering, IN QUEUE entries
render as compact rows matching the library/new row height and
chrome.

Implementation options (decided in the plan):

- Add a `style: .full | .compact` parameter to `QueueRowView`, or
- Build a thin `QueueSearchRow` that wraps `PosterMetadataRow`
  with a queue-derived trailing label.

The compact row's trailing label encodes progress + ETA when
available (`"62% · 12 min"`), falling back to a single-word state
(`"queued"`, `"paused"`, `"stalled"`).

Pause / resume / delete are not surfaced inline on the compact row.
Tap drills into `DetailView`, where the actions live. Trade-off:
search is a scanning mode, not a management mode.

## Scope chips and type pill

Both stay.

- **Scope chips** (All / Sonarr / Radarr / …): narrow the data feed
  for all three status sections.
- **Type pill** (All / In queue / In library / New): narrows which
  sections render. `.all` → all three. Anything else → flat list of
  just that kind. Counts on the pill options stay accurate against
  the current scope.

## What's removed

- Per-arr queue section headers during filtering.
- The separate "search results" block beneath queue rows.
- `InLibraryBadge` and `NewBadge` from `SearchResultRow`'s
  `titleBadge` slot.
- Full-width `QueueRowView` (with progress bar) inside search
  results.
- Duplicate appearance of a title in both queue-section and
  library-section.

## What's added

- Status section headers (`IN QUEUE` / `IN LIBRARY` / `NEW`) as the
  only grouping level during search.
- Source glyph in the row's title-badge slot.
- Compact queue row variant (new component or new mode flag).
- De-dup logic queue ↔ library.

## What's unchanged

- Floating search bar chrome, focus, clear button.
- Scope chips and type pill (semantics shift slightly, see above).
- Loading state (`Loading…` centered with spinner).
- Empty state (`No matches.`).
- Tonight / needsYou / Next-week banner hidden while filtering.
- Hover tooltips.
- `cmd+N` focuses the search bar.

## Files touched

- [PopoverContentView.swift](../../../Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift):
  - Collapse `queueBody` to the two-mode logic above.
  - Make `typeGroupedSections(for:)` work for `queueScope == nil`
    (pull from all configured sources).
  - Add de-dup pass on library results vs IN QUEUE rows.
  - Remove the `queueSearchResults` block from the `queueScope ==
    nil` branch.
- [SearchResultRow.swift](../../../Packages/ArrCore/Sources/ArrCore/Views/SearchResultRow.swift):
  - Replace `titleBadge` from `InLibraryBadge` / `NewBadge` to the
    source glyph chip.
- New compact queue row (component or `QueueRowView` mode) for IN
  QUEUE entries inside status-grouped layout.

## Out of scope

- Behaviour of search outside the queue tab (Discover, chat
  tap-to-add) — unchanged.
- Visual redesign of the floating search bar.
- Sorting within sections — keep current order (arr's default).
- Cross-arr fuzzy matching beyond what `SearchViewModel` already
  does.
- Right-click context menu on compact queue rows (could be added
  later if pause/delete-from-search demand surfaces).
