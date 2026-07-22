# Quiz — Immersive Full-Bleed Card — Implementation Plan

Spec: `docs/superpowers/specs/2026-07-20-quiz-immersive-card-design.md`

Order: ViewModel cleanup → card rewrite → tab rewrite → call-site → strings →
build/verify. Each step compiles on its own where possible.

## 1. `DiscoverViewModel.swift` — delete dead credits plumbing

- Remove props: `creditsCache`, `creditsFetchingIds`, `tmdbApiKey`.
- Remove methods: `configureCredits(apiKey:)`, `fetchCreditsIfNeeded(for:)`.
- Remove the two `reset()` lines (`creditsCache.removeAll()`,
  `creditsFetchingIds.removeAll()`).
- Leave everything else (fetch pipeline, matched, sessions) intact.

## 2. `DiscoverCardView.swift` — single full-bleed front face

- Signature: `DiscoverCardView(item:, dragOffset:, bottomInset:, onMore:)`.
  Drop `isHovered` binding and `credits`.
- Body: `GeometryReader` → `ZStack(.bottomLeading)`:
  - `RemotePoster(fill: true, cornerRadius: 0, showsLoadingIndicator: true)`
    filling `w × h`.
  - `originChip` top-trailing (unchanged).
  - `bottomGlassPanel(h: h * 0.55)` bottom (unchanged).
  - Metadata VStack (`.bottomLeading`), `.padding(14)` **plus
    `.padding(.bottom, bottomInset)`** so text clears the floating buttons:
    - title (+year), runtime/cert segments, rating pills (unchanged helpers).
    - **overview** `Text(item.result.overview)` `.lineLimit(3)` (new inline).
    - **Więcej** button → `onMore()` (accent, `discover.moreDetails.button`);
      render only the label, no chevron noise.
  - Keep `swipeTint` + `swipeStamp` overlays.
  - **Remove**: `.clipShape`/rim/`.shadow` on the top card, the whole
    `backFace(...)`, `overviewExpanded` state, `.onHover`, `.onChange(item)`,
    `genreLabels`, `directorName`, `personAvatar`, back-face `credits` use.
- Keep `discoverRatingChips`, `titleAndYear`, `runtimeCertSegments`,
  `originChip`, `bottomGlassPanel`, `swipeTint`, `swipeStamp`.

## 3. `DiscoverTabView.swift` — immersive surface + circular buttons

- **Init**: remove `onAddToRadarr`, `onAddToSonarr`, `onOpenDetail`. Keep
  `viewModel`, `llmAvailable`, `radarrAvailable`, `onClose`, `onRequestMore`.
- **State**: keep `showMatched`, `dragOffset`, `isDragging`. Remove
  `isCardHovered`.
- `quizMode`: `showMatched ? matchedMode : swipeSurface`, keep `.onReceive`.
  - `matchedMode` = existing `VStack { quizTopBar; DiscoverMatchedListView }`.
    Simplify `quizTopBar` to the matched-only case (title always "Your picks",
    back always clears `showMatched`).
- `swipeSurface` = `ZStack` filling the popover:
  - background: `current != nil ? cardStack : (isLoading ? loading : emptyStackState)`.
  - `.overlay(alignment: .top) { floatingTopChrome }` — glass back button +
    centred mood chip + picks pill. Reuse `picksCountPill`, `filterSummaryChip`;
    back button = new `GlassCircleButton` (chevron) so it reads over the poster.
  - `.overlay(alignment: .bottom) { if current != nil { actionButtons } }`.
- `cardStack`: `GeometryReader` → full `w × h` (no 0.88, no 2:3 clamp).
  `ForEach(visibleStack)` (current + `prefix(1)`) → slimmed `DiscoverCardStackItem`.
- `DiscoverCardStackItem` (slim): props `item, isTop, cardWidth, cardHeight,
  dragOffset, bottomInset, animationKey, gesture, onMore`. Transforms:
  - top: `offset(dragOffset.width, dragOffset.height*0.3)`,
    `rotationEffect(dragOffset.width/22, anchor: .center)`, scale 1, hit-testable.
  - peek: scale `0.94 + 0.06 * dragProgress` (`min(1, |dragOffset.width|/90)`),
    no offset/rotation, not hit-testable, behind.
  - Remove `isHovered`, `hoverState`, `onHoverForCredits`, `tmdbId`, `credits`,
    `stackRotation`.
- `actionButtons`: `HStack(spacing: 28)` of two `GlassCircleButton`s, bottom
  padding ~22:
  - ✕ `xmark`, tint `.red`, action `handleMarkDisliked`, a11y/help
    `discover.fewerLikeThis.button`, drag-lift on left drag.
  - ♥ `heart.fill`, tint `.accentColor`, action `completeSwipe(right: true,…)`,
    a11y/help `discover.saveToPicks.button`, drag-lift on right drag.
- New private `GlassCircleButton` struct: circular `ultraThinMaterial` +
  white-sheen gradient + `white 0.42` rim + shadow (the `selectionModeBar`
  recipe as a `Circle`), tinted `Image`, hover scale (macOS), press feedback,
  `extraScale` param for the drag-lift.
- New `openDetails(for:)` helper = `PickCard.handleTap` logic: owned →
  `DetailRequest.post(syntheticItem(...))`, else → `SearchAddRequest.post(result)`.
  Wire as `onMore`.
- **Remove**: `ctaIsland`, pill `cardActionRow`, `stackRotation(for:idx:)`,
  `visibleStack`'s `prefix(2)` → `prefix(1)`, the `.padding(.horizontal,28)` etc.
- Define `bottomInset` constant (e.g. `108`) shared by the card's metadata bottom
  padding and the action-button band; pass into cards.

## 4. `PopoverContentView.swift` — call site

- In the `DiscoverTabView(...)` call (~line 348) remove `onAddToRadarr:`,
  `onAddToSonarr:`, `onOpenDetail:`. Keep `viewModel`, `llmAvailable`,
  `radarrAvailable`, `onClose`. (`onRequestMore` keeps its default.)

## 5. `Localizable.xcstrings`

- Add `discover.moreDetails.button` (en `More` / pl `Więcej` / de `Mehr` /
  es `Más` / fr `Plus`), `extractionState: manual`.
- Remove `discover.directedBy.button` and `discover.noOverviewAvailable.button`.

## 6. Build & verify

- `xcodebuild … -scheme ArrBarr -configuration Debug` → then
  `(cd Packages/ArrCore && swift test)` for the VM.
- `pkill -x ArrBarr; open …/ArrBarr.app`; screenshot the Quiz (needs demo/live
  data). Check: full-bleed poster, corners clean, ✕/♥ legible over art, Więcej
  opens the detail card and Back returns, swipe + buttons both work, drag-lift.
