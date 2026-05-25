# Discover picker — composer-first redesign

**Date:** 2026-05-25
**Status:** Approved design, ready for plan
**Touches:** `DiscoverPickerView.swift`, `DiscoverViewModel.swift` (light), localization

## Background

The current Discover picker is functional but cluttered. Stacking five always-visible category rows (People / Genre / Decade / Vibe / Length), each with header + pills + dashed "+ Add" chip, plus a STARTERS (AI) section with three themed sub-groups, plus the composer at the bottom — gives the user ~9 typographic landmarks and two parallel input paradigms (pills vs. AI prompts) competing for the same narrow popover. The UX review (consulted via subagent) called out that nothing tells the eye "start here," and that the "+ Add" chip on every row inflates chip count without earning it.

The goal of this redesign is to drop visible chrome by roughly two-thirds without breaking any underlying behaviour. The VM stays as-is. Only the picker view changes.

## High-level direction

**Composer-first.** The composer becomes the hero of the picker. Active filters render as inline chips inside it (tag-input idiom, like macOS Mail search tokens). A single Suggestions row of usage-sorted popular pills sits below for one-tap filtering. The full five-category catalog only materialises when the user starts typing — the composer text becomes the trigger that reveals the rest.

## Layout — three states

### Fresh state (no chips, empty text)
```
┌────────────────────────────────────┐
│ [🎞 Movies]  Try: Cozy Sunday afte… ↑│
│                                    ↑│ (send dim/disabled)
│  Tarantino Comedy 90s Highly rated │
│  Nolan Drama 2000s Short Sandler   │  ← Suggestions: 10 pills, usage-sorted
│  Horror                            │
│                                    │
│  ▸ More filters                    │
└────────────────────────────────────┘
```

### Filtered state (chips set, empty text)
```
┌────────────────────────────────────┐
│ [🎞 Movies][Tarantino ×][Comedy ×] │
│ [90s ×]  Or describe…           [↑]│  ← send active
│                                    │
│  Drama Nolan Highly rated 80s Epic │  ← Suggestions de-dup against chips
│  Sci-Fi Sandler                    │
│                                    │
│  ▸ More filters                    │
└────────────────────────────────────┘
```

### Typing state (any composer text → auto-expand)
```
┌────────────────────────────────────┐
│ [🎞 Movies][Tarantino ×] 90s gang││  ← cursor in text
│                                  [↑]│
│  Drama Comedy 90s Nolan            │  ← Suggestions still visible
│                                    │
│  PEOPLE                            │
│  • Tarantino  Nolan  Sandler …  + Add │  ← full catalog, colored=picked
│  GENRE                             │
│  Action Comedy Drama … + Add       │
│  DECADE                            │
│  80s 90s 2000s 2010s 2020s         │
│  VIBE                              │
│  Highly rated  Cult favorite       │
│  LENGTH                            │
│  Short  Epic                       │
└────────────────────────────────────┘
```

When the composer text is cleared again, "More filters" collapses back. If the user has manually toggled the disclosure open (clicking the "▸ More filters" chevron), that wins and persists for the session — auto-collapse only happens for the auto-expand-on-type path.

## Component breakdown

### `ChipComposer` (new — replaces the current `composer` view)
- Glass capsule, vertically auto-sizing as chips wrap to multiple lines.
- Leading element: **kind chip** `🎞 Movies` / `📺 Shows`. Tap toggles. Visually muted (neutral grey border) so it reads as system-imposed, not a user filter.
- Then: **active-filter chips** in insertion order. Each chip carries the category accent color (teal / blue / orange / green / purple), label, and a trailing `×` button to remove. People chips use teal, genres blue, etc.
- Then: **`TextField`** flowing inline after the last chip. Placeholder cycles through starter prompts every ~3s when text is empty and field is unfocused.
- Trailing: **send button** (`arrow.up.circle.fill`). Enabled iff any chip OR non-empty text present. Tap commits.
- Keyboard: `Backspace` on empty text deletes the last filter chip (standard tag-input affordance).

### `SuggestionsRow` (new)
- Single `FlowLayout` row of pills (no header). Cap at 10 pills total.
- Composition: VM exposes `suggestedFilters: [SuggestedFilter]` — up to 8 by `personUsageCount` / `moodUsageCount` / standard catalog usage, then up to 2 "discovery" entries (catalog items the user has never used) to keep cold sessions from being empty. Final list ≤ 10.
- Active filters are excluded (de-duped against `filter` state).
- Tap → adds as chip to the composer (mutates `filter` or `selectedPersonNames` exactly like today's pill taps).
- Colors match category (teal / blue / orange / green / purple). Same `PillButtonView` hover idiom.

### `MoreFiltersDisclosure` (new)
- Chevron + label: `▸ More filters` / `▾ More filters`.
- Auto-expanded condition: `!composer.text.isEmpty || manuallyExpanded`.
- When manuallyExpanded is `true` (user clicked), text-emptiness no longer collapses it. Reset when picker is dismissed.
- Expanded body: today's per-category rows (`pillRows` from current `DiscoverPickerView`) — People, Genre, Decade, Vibe, Length — with `+ Add` chips on the categories that support custom additions (People, Genre, Decade, Vibe, Length).

### `tmdbMissingBanner` (kept)
Stays at the top, unchanged.

## ViewModel changes

The VM does not need restructuring — the existing data model (filter, selectedPersonNames, customMoods, customPeople, customTagsByCategory, usage counts) all flow through unchanged. We add:

- **`suggestedFilters: [SuggestedFilter]`** — computed property returning an ordered list of pill descriptors (id, label, category, color, icon). Up to 8 entries by usage descending, then up to 2 "cold-start" entries (highest priority catalog items the user has never used). Excludes anything currently active.
- **`SuggestedFilter`** value type — purely a view-layer DTO (struct with `id`, `label`, `category` enum, `icon: String?`). Lives in the VM so usage logic + ordering stays out of the view.

No new persistence keys. No source closure changes. No swipe / matched / tinder flow changes.

## Localization

New strings (en + de + es + fr + pl):

- `Try: Cozy Sunday afternoon…` — first placeholder rotation
- `Try: Friends over with pizza…` — second
- `Try: Date night…` — third
- `Try: Crowd-pleaser…` — fourth
- `Or describe…` — placeholder when chips exist
- `More filters` — disclosure label
- `🎞 Movies` / `📺 Shows` — keep existing keys
- `Add filter` — VoiceOver hint on Suggestions row

Existing strings kept: all current category headers, `+ Add`, `+ Add person`, `Custom`, `Cancel`, all starter prompts (still used as placeholder rotation source).

## Behavior parity table

| Existing behavior | New surface |
|---|---|
| Tap genre/decade/etc. pill → toggles filter | Identical in expanded More filters; also via Suggestions tap |
| Tap person pill → optimistic select + TMDB resolve | Identical; also via Suggestions |
| Tap custom tag → sets `moodText`, doesn't commit | Identical |
| `+ Add` chip → inline TextField with ✓/× | Only in expanded More filters |
| Tap mood-starter prompt → fills composer text | Replaced by rotating placeholder; Tab-complete picks it up |
| Submit (send button / Enter) → `onSubmit` to tinder | Identical |
| Kind change → `mediaSelectionChanged()` + `userActionTick` bump | Identical, triggered from kind chip tap |
| `userChangedFilter()` calls on every pill toggle | Identical |
| Hidden when Sonarr/Radarr unavailable etc. | Identical gating |

The send commit closure is the only path that transitions to tinder, exactly as today.

## What goes away

- Always-visible `MOOD STARTERS` / `STARTERS (AI)` section + 3 sub-theme headers + 9 starter pills. The prompts live in the placeholder rotation; the section header / sub-titles are deleted entirely.
- Always-visible 5 category headers (PEOPLE, GENRE, DECADE, VIBE, LENGTH).
- Always-visible 5 dashed `+ Add` chips. They appear only when More filters is expanded.
- The dedicated `kindSelectorBar` row (Movies / Shows outlined buttons). Replaced by the kind chip inside the composer.
- `pillRows` is invoked only inside expanded More filters now.

## Edge cases

- **Composer extremely full**: many chips + long text wraps the composer vertically. Cap chip area to ~3 lines before truncating with a "+N more" overflow chip that, on tap, scrolls the composer or shows all chips.
- **Backspace on chip**: removes last chip. If text field has content, normal backspace deletes characters first.
- **Composer focus + empty**: rotation pauses while focused (so user isn't distracted while typing).
- **Suggestions exhaustion**: if all popular pills are active, the row hides entirely (the More filters chevron is the discovery path).
- **First-launch user with zero usage data**: `suggestedFilters` falls back to a curated default order: Tarantino, Nolan, Comedy, Drama, Horror, 90s, 2000s, Highly rated, Sandler, Sci-Fi.

## Testing

- `DiscoverViewModelTests`:
  - `test_suggestedFilters_excludesActiveFilters` — when filter.genres contains .comedy, Comedy isn't in the suggestions list.
  - `test_suggestedFilters_sortsByUsageDescending` — bump three pills' usage in different amounts, assert order.
  - `test_suggestedFilters_includesColdDiscoveryEntries` — empty usage, returns a curated 10.
- Manual:
  - Empty picker → composer shows kind chip + placeholder + dimmed send. Suggestions row visible.
  - Tap a Suggestions pill → chip appears in composer, send activates.
  - Type a letter → More filters auto-expands.
  - Clear text → More filters auto-collapses.
  - Click `▸ More filters` while empty → manual expand. Clear text → stays expanded.
  - Backspace on empty text → last chip removed.

## Non-goals

- No change to swipe deck, picks list, sticky picks, kind persistence, person resolution, source closures, or any chat tool integration.
- No re-skinning of the tinder card or matched list.
- No persistence of "manually expanded" state across app launches — picker is the entry surface, defaults to collapsed every time.

## Risks

1. **Tag-input rendering inside SwiftUI**: combining wrapping chips with an inline `TextField` is finicky. Mitigation: build the chip cluster + TextField inside a `WrappingHStack` (we already have `FlowLayout`); use `.fixedSize(horizontal: false, vertical: true)` on chips so they don't compress.
2. **Placeholder rotation**: timer-driven changes can fight focus / typing. Mitigation: pause rotation while focused, resume on blur.
3. **Backspace-delete-chip discoverability**: macOS users may not know the gesture. Acceptable — × button on each chip is the primary removal path.

## Acceptance criteria

- Fresh picker shows: kind chip + placeholder + send + Suggestions row + More filters chevron. Nothing else.
- Active filters are visible only as composer chips (no separate strip).
- Typing in composer expands More filters automatically; clearing text re-collapses (unless manually expanded).
- All existing tests pass; new VM tests for `suggestedFilters` pass.
- `xcodebuild` succeeds from worktree, app relaunches, picker matches the three states in this spec.
