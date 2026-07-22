# Quiz — Immersive Full-Bleed Card

**Status:** approved
**Date:** 2026-07-20
**Branch:** `feat/queue-multiselect` (opportunistic; Quiz-only files)

## Problem / goal

The Quiz swipe view currently renders a **small inset poster card** floating in
the middle of the popover (28 pt side padding, clamped to 2:3, only 88 % of the
height), with a bottom `thinMaterial` "island" holding two **full-width pill**
buttons. It reads like a form, not a swipe deck.

Goal: make it feel like a modern swipe/discovery UI —

1. The movie cover **fills the entire popover**, edge to edge.
2. The two verdict controls become **round, icon-only** buttons floating over
   the artwork.
3. A dating-app *bio* pattern: a short **description sits above the icons**, with
   a **"Więcej" (More)** affordance that opens the full movie/series detail card.

The popover is exactly **400 × 600 = 2:3**, so a full-bleed 2:3 poster fills it
with no cropping — the geometry is on our side.

## Decisions

- **Full-bleed card.** Drop the side padding, the 88 %-height reservation, and
  the 2:3 clamp. The card fills 400 × 600 and is masked to the popover's rounded
  corners by NSPopover (same masking every other tab relies on). No card corner
  radius / rim / drop-shadow on the top card.
- **Round icon-only buttons.** Two circular glass buttons floating bottom-centre:
  **✕ (red)** = "fewer like this" (dislike), **♥ (accent)** = add to Picks.
  Colours match the existing swipe tint/stamp language (right = accent, left =
  red). They react subtly to the drag (the matching button lifts as you swipe).
- **Inline description + "Więcej".** The front card shows title · runtime/cert ·
  rating pills · a 3-line overview, then a **Więcej** link. Więcej opens the full
  detail card, routed exactly like `PickCard.handleTap` in
  `DiscoverMatchedListView`: owned items → `DetailRequest` (DetailView), fresh
  discoveries → `SearchAddRequest` (SearchAddPanel). Both are hidden-behind while
  the detail/add surface is up, so **Back returns to the deck** with state intact.
- **Remove hover-flip entirely.** The details back-face (overview / genres /
  director / cast) is deleted. Its content now lives inline (short overview) or in
  the full detail card (everything). No more flip-on-hover, no blur crossfade.
- **Minimal depth transition.** Keep one peek card behind `current` so the swap
  is seamless, but full-bleed and *scale-only* (hidden behind the top card at
  rest, scales 0.94 → 1.0 as the top flies off). Drop the 3-card tilt /
  `stackRotation` — it only ever read because cards were inset.

## Cleanup (all verified dead)

The "no orphans" bar surfaced code that is already dead:

- `DiscoverViewModel.configureCredits(apiKey:)` is **never called** → `tmdbApiKey`
  is always empty → `fetchCreditsIfNeeded` early-returns forever → the back-face
  cast row never loaded. Remove `creditsCache`, `creditsFetchingIds`,
  `configureCredits`, `fetchCreditsIfNeeded`, `tmdbApiKey`, and their `reset()`
  lines. `TMDBCredits` / `movieCredits` stay (DetailView / SearchAddPanel /
  CastRow use them independently).
- `DiscoverTabView`'s `onAddToRadarr`, `onAddToSonarr`, `onOpenDetail` closures
  are stored but **never invoked** in its body. Remove all three; Więcej posts
  the request directly (the established `PickCard` pattern). Update the call site
  in `PopoverContentView`.
- Back-face-only strings `discover.directedBy.button` and
  `discover.noOverviewAvailable.button` become orphaned → remove from the catalog.
  (`Show more` / `Show less` are shared with `ExpandableOverview` — keep.)

## New string

- `discover.moreDetails.button` — the Więcej link (en `More`, pl `Więcej`,
  de `Mehr`, es `Más`, fr `Plus`). Icon-only ✕/♥ buttons need no visible text but
  carry accessibility labels + tooltips from existing keys
  (`discover.fewerLikeThis.button`, `discover.saveToPicks.button`).

## Non-goals

- The **matched Picks list** (`DiscoverMatchedListView`) and its top bar are
  unchanged — only the swipe surface goes immersive.
- The **mood/composer entry**, the empty/loading states' content, and the
  `DiscoverViewModel` fetch pipeline are untouched (beyond the dead-credits
  removal).
- iOS can't enter the Quiz yet (macOS-only overlay); the code stays
  platform-clean but is not wired into `iOSAppRoot`.

## Risks

- **Corner masking**: relies on NSPopover clipping the full-bleed card. Verified
  by build + screenshot; if a stray sharp corner shows, add a matching corner
  radius to the card.
- **Buttons vs. artwork legibility**: circular buttons must read over arbitrary
  posters → reuse the established `selectionModeBar` glass recipe (ultraThin +
  white sheen + bright rim + shadow) with a strongly-tinted icon.

## Addendum — 2026-07-20 — drop Picks, right button = Add

The ♥ "add to Picks shortlist" action and the whole **Picks** feature are
removed. The right verdict button is now **+** and its action *opens the
add-to-collection card* for the current title (same routing as the old
`PickCard`: owned → DetailView, fresh → SearchAddPanel), then advances the deck.
The physical swipe-right does the same. **Więcej** stays as the *non-advancing*
peek at the same card; **+ / swipe-right** is the *committing* variant that
advances. Left (✕) is unchanged (dislike + advance).

Demolished (all verified dead or Picks-only):

- `DiscoverMatchedListView.swift` (whole file), `PickCard`.
- `DiscoverViewModel`: `matched`, `hasUnseenPicks`, `acknowledgeUnseenPicks`,
  `removeMatch`, `clearMatched`, the `matched` insert in `startSwipe`, and the
  `matched`-reseed in `reset()`. `sessionMatched` **stays** (positive "more like
  these" signal; also drives `QuizResumeCard`'s count).
- `DiscoverTabView`: `showMatched`, matched mode + top bar, `picksCountPill`,
  the `showYourPicks` empty-state button.
- `AppNotifications.arrBarrShowDiscoverPicks` (declared + observed, never posted).
- Strings: `discover.yourPicks/showYourPicks/saveToPicks/noPicksYetSwipe/
  removeFromPicks` + bare `"Pick"` (right stamp → `"Add"`).

Added: bare `"Add"` (right swipe stamp) and `discover.addToLibrary.button`
(the + button's a11y label / tooltip).

## Addendum — 2026-07-20 — ✕→⏩ skip, + no longer advances

Two behaviour tweaks:

- **Left button ✕ → ⏩ (`forward.fill`), neutral.** It now *skips to the next
  card* (a plain skip, not a "dislike"). Colour goes red → `.secondary` on the
  button and the swipe-left tint/stamp, matching the neutral "next" intent.
  **Skip is the only action that advances the deck.**
- **+ no longer advances.** Opening the add card records a pick (for the
  resume-card count) but leaves the user on the same title, so a *cancelled* add
  returns to it (`SearchAddPanel` can't distinguish add-success from cancel — it
  calls the same `onBack` for both — so "advance on success only" isn't
  possible; not advancing is the clean fix).

VM: `swipe(right:)` + `markDisliked` + `sessionDisliked` removed (dislike was
already vestigial — only fed the no-op `onRequestMore`). Replaced by `skip()`
(sessionSkipped + advance) and `markPicked()` (sessionMatched, deduped, no
advance). `onRequestMore` drops its `disliked` arg. String
`discover.fewerLikeThis.button` removed; the skip button reuses `"Skip"`.
