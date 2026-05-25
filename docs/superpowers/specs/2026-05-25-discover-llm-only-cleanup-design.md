# Discover — LLM-Only Cleanup

**Status:** approved
**Date:** 2026-05-25
**Branch:** `discover/tab`

## Problem

Two concrete defects in the current Discover tab:

1. **Tab bar disappears mid-flow.** `hideTabBarDeepInDiscover` in
   `PopoverContentView.swift` hides the main popover tab bar whenever the
   user is in `.tinder` stage or in `.picker` stage with an active session
   (`current != nil`). In practice this means the tab bar vanishes from the
   first submit onward and only returns after a full back-arrow walk to a
   "clean" picker. Users feel trapped in Discover.

2. **Visual composer is a mess.** The picker layered chip composer,
   per-category suggestion rows, "+ Add" catalog menu, autocomplete
   popover, "More filters" disclosure, AI starter row, and rotating
   placeholders into one screen. Visually overwhelming and the structured
   filters carry their weight only to feed TMDB Discover queries — work
   the LLM already does better from prose.

## Decision

Strip the visual composer entirely. Discover becomes **LLM-only**: a single
free-form text input is the sole way to request picks. Always keep the main
tab bar visible.

## Scope

### 1. Tab bar (PopoverContentView.swift)

- Remove `hideTabBarDeepInDiscover` and the `if !hideTabBarDeepInDiscover`
  guard around `tabBar`. Tab bar renders unconditionally for the Discover
  tab, same as every other tab.
- `FloatingBackButton` in `DiscoverTabView` keeps its existing role
  (matched → swipe → picker). It is no longer the only escape — tabs are.
- Accept ~44 pt less vertical space inside Discover. Tinder card already
  has headroom; no layout rework required.

### 2. Picker (DiscoverPickerView.swift) — full rewrite

New body, top to bottom:

- Heading: `Text("What do you feel like watching?")` — large, semibold.
- A single multiline `TextField` (axis: `.vertical`, `lineLimit: 2...5`)
  bound to `viewModel.moodText`. Placeholder rotates through a fixed list
  of example prompts (reuse the existing rotating-placeholder timer).
- One submit button labeled `Discover` (or equivalent localized key).
  Disabled while `moodText` is empty/whitespace. `.onSubmit` on the
  TextField triggers the same action (Enter to send).
- Nothing else. No chip strip, no suggestion rows, no More filters
  disclosure, no "+ Add" menu, no autocomplete popover, no AI starter row,
  no per-category groupings.

`DiscoverTabView.tinderTopBar` already renders `filterSummaryChip` — adapt
it to show a truncated `moodText` and tap to return to the picker with the
prompt pre-filled (already the behavior, just no other filter parts to
join).

### 3. ViewModel (DiscoverViewModel.swift) — strip suggestion machinery

Remove published state and APIs that exist only for the visual composer:

- `suggestedFilters` pool + `suggestionsByCategory(llmAvailable:)`
- Person autocomplete: `selectedPersonNames`, completion lookup helpers,
  `commitPersonName`, related caches
- `SuggestedFilter` DTO + supporting category enum (if not used elsewhere
  after the picker rewrite — verify and delete if dead)
- Any `userChangedFilter()` paths driven by structured filter taps; keep
  the single path: "user submitted moodText".

Keep:

- `stage` (`.picker` / `.tinder`)
- `moodText`, `matched`, `current`, `picksMilestoneTick`, `removeMatch`,
  `reshuffle`
- `DiscoverFilter` struct as a type (still referenced by TMDB client
  signatures elsewhere), but no longer mutated by the picker UI. Pass a
  default-empty filter to any source that requires it.

Add (small):

- A `lastSubmittedPrompt: String?` so re-entering the picker from the
  back-arrow restores the prompt that produced the current results
  (already partly achieved via `moodText` persistence; verify and adjust).

### 4. Sources (DiscoverSources.swift)

- Delete `tmdbMovies` and `tmdbShows` source factories. Without
  user-driven structured filters they degrade to "popular" lists, which
  is not what an LLM-only flow promises.
- Keep the library source (Radarr/Sonarr) for one purpose: cross-reference
  LLM-suggested titles against owned items so the card can show an
  "already in library — open detail" affordance instead of "Add".
- The LLM source becomes the sole producer of new cards.

### 5. Prompt (DiscoverLLMPrompt.swift)

- Simplify input: free-form user prose + the set of owned tmdb/tvdb ids
  to exclude. Drop the structured filter serialization.
- Output shape unchanged (the existing card mapping still applies).

### 6. Tests

- Drop suggestion-pool tests in `DiscoverViewModelTests` (the suggestion
  APIs are gone).
- Update `DiscoverLLMPromptTests` to assert the simplified payload
  (prose + exclusion list).
- `DiscoverItemTests` likely unaffected — verify.

## Non-goals

- No new "history of prompts" UI.
- No saved prompts / favorites.
- No structured filter UI in any form (including hidden behind disclosure).
- No redesign of tinder swipe / matched-list views.
- No change to chat-driven Discover entry (`arrBarrOpenDiscoverInTinder`)
  beyond making sure it still works with the LLM-only pipeline.

## Trade-offs accepted

- **Every search hits the LLM.** No free TMDB browsing. Mitigation: a
  small in-VM cache keyed on the normalized prompt so going back to the
  picker and re-submitting the same prompt does not re-call the model.
- **Less vertical space in tinder mode** (~44 pt). Acceptable; card has
  headroom.
- **Loss of "explore popular 90s sci-fi" as a no-LLM path.** User must
  prompt for it. Trusting the model to handle that prose well.

## Files touched

- `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift` (minor —
  `filterSummaryChip` simplification)
- `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- `Packages/ArrCore/Sources/ArrCore/Services/DiscoverSources.swift`
- `Packages/ArrCore/Sources/ArrCore/Services/DiscoverLLMPrompt.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverLLMPromptTests.swift`
- `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`
  (drop dead keys, add `Discover` heading + button + placeholders if not
  already present)
