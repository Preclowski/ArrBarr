# Discover picker — sentence-style refinement

**Date:** 2026-05-25
**Status:** Approved
**Builds on:** `2026-05-25-discover-picker-composer-first.md`

## Background

The composer-first picker shipped (chips + suggestions row + more filters). User feedback: it should read like a sentence and signal that natural-language input goes to the LLM. Two design moves close that gap.

## Design moves

### 1. Composer = sentence-style with category labels

The chip composer renders as a natural-language sentence with kursywne ("italic") category labels appearing between chip groups *only when those groups have content*:

```
[🎞 Film]  Gatunek: [Komedia ×] [Dramat ×]  Z: [Tarantino ×]  Z lat: [90s ×]   ✨ …lub opisz słownie   ↑
```

- Kind chip always first.
- Labels: `Gatunek:` before genre chips, `Z:` before people chips, `Z lat:` before decade chip, `Vibe:` before rating chip, `Długość:` before runtime chip.
- Empty groups → no label (skip).
- After the last chip group: `✨` sparkles icon (always visible) + inline TextField.
- TextField placeholder: "…lub opisz słownie" (was "Or describe…" / starter rotation).
- Send button at the trailing end.
- Backspace on empty text still deletes the last chip.

The label order in the composer is fixed: kind → genre → people → decade → rating → runtime. This matches reading flow ("Film w gatunku Komedia z Tarantino z lat 90, wysoko oceniany").

### 2. Suggestions = per-category mini-rows + AI starters row

The flat Suggestions row becomes a stack of small per-category sub-rows. Each sub-row has a small leading label and up to 3 pills:

```
Osoby     [Tarantino] [Nolan] [DiCaprio]
Gatunki   [Komedia] [Dramat] [Horror] [Sci-Fi]
Dekady    [90s] [00s]
Vibe      [Highly rated]
✨ AI     [Cozy Sunday] [Long flight] [Date night]
```

- Each row is hidden if it has zero suggestions (all entries already active in chips).
- AI row is always shown when `llmAvailable` and lists the rotating starter prompts as pink/sparkles pills.
- Tap a non-AI pill = adds chip to composer (existing behaviour).
- Tap an AI pill = fills the composer's free-text field with that prompt + focuses it (so user can edit before sending).

Row order: Osoby (people first, most-recognizable filter), then Gatunki, Dekady, Vibe, AI. AI is last because it's the "alternative path" — visible but not the lead.

## What this replaces / changes

- `suggestionsRow` (single FlowLayout) → split into per-category mini-rows with leading labels.
- `chipComposer`: insert category labels interleaved with chip groups; sparkles icon prefixes the TextField; placeholder string changes.
- Placeholder rotation kept but the new placeholder is constant ("…lub opisz słownie") — starter prompts now live in the AI row of Suggestions.
- `currentPlaceholder` and `placeholderTick` no longer needed (drop both).
- `activeChips` stays unchanged (still flat ordered list).
- `applySuggestion(_:)` gets a new case: when `category == .ai` (we'll add) the suggestion fills `freeText` + focuses, doesn't toggle filter.

## VM additions

- `SuggestedFilter.Category` gains a new case `.ai`. AI suggestions carry the prompt string as the label.
- `suggestedFilters` adds an "AI" subset returned alongside (or extended to return per-category buckets).

Cleanest approach: add a new computed property `suggestionsByCategory: [SuggestedFilter.Category: [SuggestedFilter]]` (ordered dictionary or just iterated by a fixed category order). View iterates the order.

## Non-goals

- Typing-aware filtering of Suggestions (model 3 in earlier discussion) — deferred.
- Polish grammatical declension of chip labels — chips stay in nominative form.
- Mood-text → filter extraction (LLM-side) — out of scope.

## Acceptance criteria

- Composer with chips shows category labels (`Gatunek:`, `Z:`, `Z lat:`, …) before each group; labels disappear when group is empty.
- Composer shows `✨` icon between chip area and TextField; icon always visible regardless of free-text content.
- Suggestions row is split into per-category sub-rows, each with a leading label; empty rows hidden.
- `✨ AI` row appears when LLM available, shows up to 3 starter prompt pills.
- Tap AI pill → free-text field filled with prompt + focused; no chip is added.
- All existing pill-tap, chip-removal, send-commit behaviors preserved.
- All 40 Discover tests still pass.
- Build green from worktree, app relaunches cleanly.
