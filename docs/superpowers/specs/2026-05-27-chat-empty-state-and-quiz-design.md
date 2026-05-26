# Chat tab refactor — empty state + Quiz mode

**Status:** design (revised)
**Date:** 2026-05-27
**Scope:** ArrBarr chat tab UX and information architecture
**Mockup:** [2026-05-27-chat-empty-state-mockup.svg](2026-05-27-chat-empty-state-mockup.svg)

## Problem

The Chat tab today is conceptually overloaded. A single tab labelled "Chat"
hosts three distinct interaction patterns:

1. Free-form conversation with the LLM (queue questions, library actions).
2. Search / recommendation via tool-result cards (`tmdb_discover_*`,
   `tmdb_search_*`, `suggest_titles`).
3. A swipe-style discovery flow — sequence of poster cards the user
   accepts or skips — built around discover results.

Users don't know modes 2 and 3 exist. The label "Chat" suggests a single
conversational affordance, and the empty state offers no breadcrumbs to
the other behaviours. This spec addresses **discoverability** and the
**conceptual mismatch**, not the underlying LLM routing (which stays).

## Non-goals

- Splitting Chat into multiple top-level tabs (popover is narrow; deferred).
- A "Guess the movie" mode (deferred — design leaves room for it in a
  future second hero card).
- Changing how the LLM router classifies free-text input.
- Renaming or restructuring `ChatViewModel` / `ChatProvider` beyond what
  the new views require.
- Exposing person-based seeds inside Quiz (`tmdb_search_person`) — that
  path already lives in the chat conversation; duplicating it inside
  Quiz adds surface without a clear win.

## Solution overview

Keep one tab. Replace the empty state with a structured launcher and add
a dedicated **Quiz** mode that has its own active-quiz UI plus a single
bottom-sheet for customization. **There is no separate setup screen** —
Quiz starts immediately with sensible defaults; the user refines via the
filters pill on the active screen.

The chat input remains visible in empty / conversation states so power
users can type and let the LLM router decide.

## Information architecture

```
ChatTabContent
├── empty state (when chat history is empty)
│   ├── greeting (header + subhead)
│   ├── hero Quiz card — icon, title, subtitle, CTA "Zaczynamy"
│   ├── "ALBO ZAPYTAJ" hairline divider
│   ├── suggestion chip list (full-width pills, prompt shortcuts)
│   └── chat input bar
├── conversation view (when history non-empty)
│   ├── messages scroll
│   └── chat input bar
└── Quiz mode (in-tab, overlay)
    ├── header strip (title, progress, exit)
    ├── filters pill ("Filmy · Popularne · nieobejrzane ▾")
    ├── progress dots
    ├── poster card (full-bleed metadata strip)
    ├── action buttons (Pomiń / Dodaj)
    └── filters bottom-sheet (modal, on filters-pill tap)
```

Empty, conversation, and Quiz are mutually exclusive within the tab.
Quiz draws over chat history but does not destroy it; exit returns to
whichever state was active before.

## Empty state

Shown when `ChatViewModel.messages.isEmpty`. Also reachable via a
"new chat" affordance in the tab header (clears history, returns here).

### Greeting

- Header: "Co dziś obejrzeć?" — 22pt semibold
- Subhead: "Quiz, podpowiedź albo wpisz pytanie." — 13pt secondary

No avatar, no illustration. Vertical real estate is precious.

### Hero Quiz card (lean)

One full-width card. Layout designed so a future second feature (e.g.
"Zgadnij film") can sit beside it as a 50/50 pair without re-laying out
the rest of the empty state.

Contents:

- Icon block (44×44 rounded, accent gradient, glyph)
- Title "Quiz" (17pt semibold)
- Subtitle "Swipuj propozycje, dodawaj do biblioteki." (12.5pt secondary)
- Primary CTA "Zaczynamy" (full-width pill, dark fill). Trailing
  micro-caption inside the CTA: *"popularne · nieobejrzane"* — communicates
  the default lens, hints that it is changeable.

Card holds **no inline filter chips**. Filters live on the Quiz screen,
not at its entrance. This is a deliberate reversal of the earlier
inline-chips design — the hero is an *invitation*, not a *form*.

### Suggestion chips

Four prompt shortcuts under a hairline labelled "ALBO ZAPYTAJ". Tapping
a chip injects its text into the chat input and sends — same effect as
typing and pressing return. Chips do not change app state and do not
launch Quiz.

Initial list (subject to copy review):

- "Co dziś wychodzi?"
- "Co się teraz ściąga?"
- "Polecisz coś jak Mr. Robot?" *(routes to `suggest_titles`)*
- "Filmy z Tildą Swinton" *(routes to `tmdb_search_person` →
  `tmdb_person_movie_credits`)*

The last two intentionally cover the taste and person seeds, since those
are not exposed inside Quiz. Together they make the chat's full
capability surface discoverable from the empty state.

All copy localised via existing `loc("Key")` helper, namespaced
`chat.empty.*`.

## Quiz mode

A self-contained in-tab flow. **No setup screen.** Quiz begins
immediately with defaults; user can refine at any point.

### Defaults on first entry

- Content type: Filmy (movies)
- Mood: Cokolwiek (no genre filter)
- Years: Cokolwiek (no year filter)
- Sort: Popularne (`popularity.desc`)
- Hide owned: on

These produce the lens shown in the CTA caption ("popularne ·
nieobejrzane"). Defaults are not persisted across launches in v1.

### Active screen

- Header strip: "Quiz · N/M" + exit (✕).
- Filters pill (single, full-width row beneath header). Label reflects
  current lens, e.g. "Filmy · Popularne · nieobejrzane". Trailing
  chevron-down. Tap → opens filters bottom-sheet.
- Progress dots (10 dots, filled per advanced card).
- Poster card — 264×354 dark card with poster region on top and
  metadata strip (title, year + rating + genres, director + runtime).
- Action row: **Pomiń** (light pill, ✕ glyph) and **Dodaj** (dark pill,
  heart glyph). Buttons are explicit; swipe gesture is a stretch goal,
  not v1.

"Dodaj" calls the existing Radarr/Sonarr add path (the same one used
today when the user taps a discover-result card in chat). "Pomiń"
advances.

When the deck is exhausted, show a small summary ("Dodano X, pominięto
Y") with two actions: "Jeszcze raz" (refetches with current filters)
and "Wyjdź".

Exiting any time returns to whatever was behind Quiz.

### Filters bottom-sheet

Modal sheet over the popover. Single surface for all customization.
Sections, top to bottom:

1. **Co?** — Filmy / Seriale / Oba (single-select chips). Maps to
   `tmdb_discover_movies` vs `tmdb_discover_series` vs both (interleaved).
2. **Nastrój** — Cokolwiek / Akcja / Komedia / Horror / Sci-fi / Dramat
   / Romans / Thriller (+ Animacja, Dokument as overflow). Single-select.
   Maps to `genre` param. Final list subject to copy review; the control
   is single-select chips wrapped to two rows.
3. **Z jakich lat?** — Cokolwiek / 80s / 90s / 2000s / 2010s / 2020+.
   Single-select. Maps to `startYear` / `endYear`.
4. **Sortuj** — Popularne / Wysoko oceniane / Najnowsze. Maps to
   `sortBy` (`popularity.desc`, `vote_average.desc`,
   `primary_release_date.desc`).
5. **Pomiń to co mam** — toggle, default on. Client-side filter against
   Radarr/Sonarr library.
6. **LUB OPISZ** — single free-text field, e.g. *„coś jak Drive ale
   lżejszego"*. When non-empty, this **overrides** the algorithmic
   filters above for the seed: Quiz calls `suggest_titles` with the
   text plus the Co? type, ignoring genre/year/sort (those concepts
   don't apply to LLM-curated lists). Hide-owned still applies.

Footer: **Zastosuj** (full-width dark pill). Also a "Reset" affordance
in the sheet header.

Closing the sheet without applying discards changes. Applying re-fetches
the deck and resets progress counter to 1.

## Component boundaries

New SwiftUI views (filenames in `Packages/ArrCore/Sources/ArrCore/Views/`):

- `ChatEmptyStateView.swift` — greeting + hero + suggestion chips.
  Presentational. Callbacks: `onQuizStart()`, `onChipTap(String)`.
- `QuizFeatureCard.swift` — hero card primitive (reusable for the
  future second feature).
- `SuggestionPromptRow.swift` — full-width chip primitive.
- `QuizActiveView.swift` — drives the card deck. Owns nothing
  persistent; takes a `QuizSession` and emits user actions.
- `QuizFiltersSheet.swift` — bottom-sheet form. Owns transient
  edit state; emits a `QuizFilters` value on Apply.
- `QuizFiltersPill.swift` — the in-header pill that summarizes the
  current lens.

New types in `Packages/ArrCore/Sources/ArrCore/Models/` (or co-located
with the view model):

- `QuizFilters` — struct with: contentType (movies/series/both),
  genre? (string), yearBucket? (enum), sortBy (enum), hideOwned (bool),
  freeText? (string).
- `QuizSession` — fetched candidate list, current index, accept/skip
  counters, the `QuizFilters` it was built from.

New state on `ChatViewModel`:

- `enum ChatTabState { case empty, conversation, quizActive }` driving
  which top-level view renders.
- `quizSession: QuizSession?` — non-nil iff `quizActive`.
- Methods: `startQuiz(filters:)`, `applyQuizFilters(_:)`,
  `acceptQuizCard()`, `skipQuizCard()`, `exitQuiz()`.

Filters bottom-sheet is presented from `QuizActiveView` via SwiftUI's
`.sheet(isPresented:)` — independent of the view model's tab-state
machine.

## Data flow

1. Empty state — pure UI, no network. Chip tap →
   `ChatViewModel.send(text:)` (existing API) → conversation state.
2. CTA "Zaczynamy" → `startQuiz(filters: .defaults)` → view model
   calls `tmdb_discover_movies` with defaults → populates
   `QuizSession` → transitions to `.quizActive`.
3. Filters sheet → "Zastosuj" → `applyQuizFilters(_:)` → same fetch
   path with new params (or `suggest_titles` if `freeText` non-empty).
4. "Dodaj" → existing add path. "Pomiń" → advance index. Deck
   exhausted → summary card. "Jeszcze raz" → re-applies current
   filters and refetches. "Wyjdź" → restores previous state.

No new tool endpoints. Quiz is a client-side wrapper around tools that
already exist (`tmdb_discover_movies`, `tmdb_discover_series`,
`suggest_titles`, plus the existing add paths).

## Visual language (Apple-like)

Enforced for new views:

- Three text greys: `#1d1d1f` (primary), `#5e5e63` (label), `#86868b` /
  `#a0a0a5` (tertiary / placeholder).
- Hairline dividers `#ececef` at 0.5pt — no full borders.
- Accent (purple gradient) appears only on the hero icon; everything
  else neutral.
- Single dark CTA per surface (`#1d1d1f`) acts as the gravity point.
- Pill family radii: 12pt for suggestion rows, 14-16pt for chips and
  filter pills, 22pt for the chat input and primary CTAs.
- Generous whitespace; no inner card borders; subtle shadow only on
  the hero card and the bottom-sheet.

These map to existing `Tokens.swift` where possible; extend that file
rather than introducing parallel design tokens.

## Localisation

All new user-facing strings via `loc("Key")` and
`Localizable.xcstrings`. Key prefixes:

- `chat.empty.*` — greeting, suggestion chips, hero copy
- `chat.quiz.*` — quiz header, filter labels, action buttons, summary

## Open questions

- Exact mood / decade chip list — needs product input. Spec fixes the
  control type, not the final values.
- Sheet presentation on macOS popover — `.sheet` vs `.popover` vs a
  custom slide-in layer. Implementation plan should benchmark
  what reads correctly inside a narrow popover.
- Keyboard shortcuts in active quiz (← skip, → add) — nice-to-have.
- Should "Jeszcze raz" reshuffle or refetch a new page? Default to
  refetching the next discover page.

## Out of scope (explicitly deferred)

- "Zgadnij film" mode — design accommodates as a second hero card later.
- Persisting Quiz filters across launches.
- Sharing or exporting quiz results.
- Renaming the Chat tab itself — the new empty state does the
  discoverability work without a rename.
- Person-based Quiz seeds — already in chat via `tmdb_search_person`.
