# Library unified search (design A: one capsule, one meaning)

**Date:** 2026-08-17
**Scope:** macOS popover only — iOS has no Library tab.

## Problem

The app has two identical-looking floating capsules (same `glassyFloatingBar`
chrome, same magnifying glass) with different semantics: the Queue tab's field
is the app's global search (local queue filter + remote arr lookups + add-new),
while the Library tab's field is a purely local grid filter. Same look,
different behavior — each one makes the other read as broken. Typing a title
you don't own into the Library field answers with silence, which is the one
wrong answer this app must never give.

## Decision

One semantics everywhere: the capsule always means "search the whole arr
world". Context changes only the ordering of sections, never the behavior.

- **Queue tab** (unchanged mechanics): queue rows → library + add-new hits.
- **Library tab** (this change): the cover grid keeps filtering locally and
  instantly, exactly as today; below the grid a new section renders the same
  arr-lookup results the queue surface gets — rows the grid already answers
  are deduplicated away.
- Both capsules share one prompt that tells the truth: "Search everywhere"
  (`search.global.prompt`). `queue.filterQueue.button` ("Filter queue") and
  `library.filter.prompt` ("Filter library") are deleted — each had exactly
  one use.

## Library tab specifics

- **Own `SearchViewModel` instance** (`@State`), not the shared global one:
  the queue's field mirrors its text into the shared VM and two owners of one
  query fight across tab switches. Same per-surface pattern iOS's `QueueTab`
  already uses. Set up without a TMDB key — no people/starring section on
  this surface (the full search on the Queue tab keeps them).
- **Dedup rule** (`SearchResultDedup.removingGridDuplicates`): drop a lookup
  row only when it is in-library for the *browsed* arr AND its `arrId` is in
  the set of local alias matches (`TitleMatch.indexedFilter` over
  `allEntries`, ignoring the status chips — the grid answers for those even
  when a chip hides them). Everything else stays: add-new hits from any arr,
  hits owned by a *different* arr (rendered with their "In library" pill),
  and in-library hits the local alias match missed.
- **Section**: `DetailSectionHeader("library.moreResults.header")` ("More
  results") — shown only when local grid rows are also present; with no local
  matches the lookup rows *are* the result list and need no "more". Rows are
  `SearchResultRow`, relevance-sorted via `SearchRelevance`. Tap: in-library →
  `DetailRequest.tap` (detail overlay), add-new → `searchResult` binding →
  the shared `SearchAddPanel` overlay `PopoverContentView` already hosts.
- **Loading**: capsule's leading icon swaps to a spinner while lookups run
  (same fixed-slot ZStack as the queue bar); re-search fades existing rows
  with a top-anchored spinner (same policy as `QueueSearchResultsView`);
  settled empty (no local, no remote) reuses `search.noResults.*` / the
  error variant.
- **Empty-state routing**: the "Library is empty" state only renders when the
  field is empty; with a query active the scroll surface stays up so the
  remote section can answer.

## Out of scope

- People / "Starring X" rows in the Library section.
- Any iOS change; any Queue-surface change beyond the shared prompt.
- Escape-hatch row (option B) — subsumed by inline results.

## Localization

New keys (en/pl/de/es/fr/nl): `search.global.prompt`,
`library.moreResults.header`. Deleted: `queue.filterQueue.button`,
`library.filter.prompt`. Verified with `Tools/loc/lint_missing_keys.py` +
`loc_audit.py`.

## Tests

`SearchResultDedupTests`: grid-dedup cases — same-arr owned + locally matched
(dropped), same-arr owned + alias-missed (kept), other-arr owned (kept even on
id collision), add-new (kept), order preserved. View wiring is not
unit-testable (SwiftUI renders nothing under `swift test`); verified in the
running app.
