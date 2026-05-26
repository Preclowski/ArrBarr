# Chat tab refactor — empty state + Quiz mode

**Status:** design
**Date:** 2026-05-27
**Scope:** ArrBarr chat tab UX and information architecture

## Problem

The chat tab today is conceptually overloaded. A single tab labelled "Chat"
hosts three distinct interaction patterns:

1. Free-form conversation with the LLM (queue questions, library actions).
2. Search / recommendation via tool-result cards (`tmdb_discover_*`,
   `tmdb_search_*`).
3. A swipe-style "Quiz" — a sequence of poster cards the user accepts or
   skips — built around discover results.

Users don't know modes 2 and 3 exist. The label "Chat" suggests a single
conversational affordance, and the empty state offers no breadcrumbs to the
other behaviours. This spec addresses **discoverability** and the
**conceptual mismatch**, not the underlying LLM routing (which stays).

## Non-goals

- Splitting Chat into multiple top-level tabs (popover is narrow; deferred).
- A separate "Guess the movie" mode (deferred — design leaves room for it
  but does not ship it).
- Changing how the LLM router classifies free-text input.
- Renaming or refactoring the existing `ChatViewModel` / `ChatProvider`
  stack beyond what the new empty state and Quiz mode require.

## Solution overview

Keep one tab. Replace the empty state with a structured launcher and add a
dedicated **Quiz** mode that has its own setup screen and active-quiz UI,
separate from the chat scroll.

The chat input remains visible at all times so power users can type and let
the LLM router decide.

## Information architecture

```
ChatTabContent
├── empty state (when chat history is empty)
│   ├── header "Co dziś obejrzeć?"
│   ├── feature hero card (Quiz)
│   ├── section "POLEĆ MI" — prompt chips
│   ├── section "W BIBLIOTECE" — prompt chips
│   └── chat input bar
├── conversation view (when history non-empty)
│   ├── messages scroll
│   └── chat input bar
└── Quiz mode (modal overlay within tab)
    ├── setup screen (chip form)
    └── active quiz (swipe cards)
```

The empty state, conversation, and Quiz mode are mutually exclusive within
the tab. Quiz mode draws over chat history but does not destroy it; exiting
Quiz returns to whichever state was active before.

## Empty state

Shown when `ChatViewModel.messages.isEmpty`. Also reachable via a "Nowy
chat" affordance in the chat header (clears history and returns here).

### Hero card

One full-width card for **Quiz**. Designed visually so a future second
feature (e.g. "Zgadnij film") can sit beside it as a 50/50 pair without
re-laying out the rest of the empty state.

- Icon, title ("Quiz"), one-line subtitle, chevron.
- Tap → opens Quiz setup screen (in-tab navigation, not a sheet).

### Prompt sections

Two sections of chip-style prompts. Tapping a chip injects its prompt text
into the chat input *and* sends — same effect as typing and pressing
return. Chips are pure prompt shortcuts; they do not change app state.

Initial chips (subject to copy review):

**POLEĆ MI**
- Horror na wieczór
- Sci-fi z lat 90.
- Jak Mr. Robot
- Lekka komedia

**W BIBLIOTECE**
- Co się ściąga?
- Co dziś wychodzi?

Chips are localised via the existing `loc("Key")` helper.

### Header copy

"Co dziś obejrzeć?" — a single greeting line above the hero. No avatar, no
illustration. The popover is narrow; vertical real estate is precious.

## Quiz mode

A self-contained flow inside the chat tab. Two screens.

### Setup screen

Chip-based form (not a mini-chat — deterministic, no LLM tokens spent on
setup parsing):

- **Nastrój** — single-select chips: Strach / Romantycznie / Akcja /
  Coś dziwnego. (Final list TBD by product, but the control is
  single-select chips.)
- **Lata** — single-select: Cokolwiek / 90s / 2020+.
- **Tylko nieobejrzane** — toggle, default on.
- Primary button "Zaczynamy".
- Back affordance returns to whatever was behind Quiz (empty state or
  conversation).

Setup state is **not** persisted across app launches in v1. Re-entering
Quiz starts from defaults.

### Active quiz

A stack of cards backed by results from `tmdb_discover_*` (called once at
quiz start with the parameters from setup). Each card:

- Poster, title, year, rating, genres, director, runtime.
- Two explicit buttons: **Pomiń** (✕) and **Dodaj** (♥). Swipe gesture is
  a stretch goal; buttons ship first.
- Header strip shows "Quiz · N/M" progress and a "Wyjdź" button.

"Dodaj" calls the existing Radarr add path (same code that today handles
add-from-discover-card in chat). "Pomiń" advances.

When the deck is exhausted, show a small summary card ("Dodano X, pominięto
Y") with two actions: "Jeszcze raz" (back to setup) and "Wyjdź".

Exiting at any point returns to the previous tab state with chat history
intact.

## Component boundaries

New SwiftUI views (filenames):

- `ChatEmptyStateView.swift` — header, hero card, prompt sections, all
  presentational. Takes a callback `onChipTap(String)` and
  `onQuizTap()`. No state of its own.
- `QuizSetupView.swift` — chip form, owns transient setup state, emits a
  `QuizConfig` value when user taps "Zaczynamy".
- `QuizActiveView.swift` — drives the card deck, owns `QuizSession` state.
- `QuizFeatureCard.swift` — the hero card primitive (reusable for the
  future second feature).
- `PromptChipSection.swift` — section header + chip list primitive.

New state in or near `ChatViewModel`:

- `enum ChatTabState { case empty, conversation, quizSetup, quizActive }`
  drives which view the tab renders. Empty/conversation derive from
  `messages.isEmpty`; quiz states are explicit.
- A `QuizSession` value type holding setup params, the fetched candidate
  list, the current index, and accept/skip counters. Lives on the view
  model for the lifetime of one quiz run; cleared on exit.

Chat input bar is reused in empty and conversation states. It is **hidden**
in quiz setup and quiz active states.

## Data flow

1. Empty state — pure UI, no network. Chip tap → `ChatViewModel.send(text:)`
   (existing API) → conversation state takes over.
2. Quiz setup → "Zaczynamy" → view model calls existing
   `tmdb_discover_movies` tool with mapped params, populates `QuizSession`,
   transitions to `.quizActive`.
3. Quiz active → "Dodaj" → existing `radarr_add` path. "Pomiń" → advance
   index. End of deck → summary card.

No new tool endpoints. No new backend code on the LLM side. The Quiz is a
client-side wrapper around tools that already exist.

## Localisation

All user-facing strings go through `loc("Key")` and into
`Localizable.xcstrings`. New string keys are prefixed `chat.empty.*` and
`chat.quiz.*` for grep-ability.

## Open questions

- Exact mood / decade chip lists — needs product input. Spec assumes the
  control type, not the values.
- Should the Quiz summary screen offer "Dodaj wszystkie pominięte do
  watchlisty" or similar? Out of v1.
- Keyboard shortcuts for Pomiń / Dodaj in active quiz — nice-to-have, not
  required for v1.

## Out of scope (explicitly deferred)

- "Zgadnij film" mode — design accommodates it as a second hero card later.
- Persisting Quiz history across launches.
- Sharing or exporting quiz results.
- Renaming the Chat tab itself — empty state does the discoverability
  work; the tab label can stay "Chat" for now.
