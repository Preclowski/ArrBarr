# Drop Discover Tab — Chat-Driven Tinder

**Status:** approved
**Date:** 2026-05-26
**Branch:** `discover/llm-only-cleanup` (continuation)

## Problem

After the LLM-only cleanup the Discover picker is a single text field — the
same thing the user already does in chat. Maintaining a separate tab + picker
duplicates the entry surface for no extra capability. Chat already has a
`discover_in_tinder` tool wired through `arrBarrOpenDiscoverInTinder` that the
popover catches and routes to Discover.

## Decision

Drop the Discover tab from the popover tab bar. Tinder + matched survive as a
**modal overlay** that the chat-tool notification opens directly. The picker
view is deleted. The VM keeps only one effective mode.

## Scope

### Removed

- `Tab.discover` case from `PopoverContentView.Tab` enum + the `.discover`
  branch of `visibleTabs`.
- The whole `case .discover:` branch of the main tab content `switch`.
- `DiscoverPickerView.swift` (entire file).
- `DiscoverViewModel.DiscoverStage` enum + the `stage` `@Published` property.
- `DiscoverViewModel.userSubmittedMood()` — mood is set externally before
  notification fires, so the dedicated call is dead.
- `DiscoverTabView`'s `case .picker / case .tinder` `switch` in `body` —
  body becomes the tinder content unconditionally.
- `filterSummaryChip` tap-to-return-to-picker behaviour — there is no picker.
- `activeFilterSummary`'s × clear button — closing the overlay is the only
  exit, and clearing the prompt while staying inside makes no sense.

### Kept

- `DiscoverTabView` as a view type, simplified.
- `DiscoverMatchedListView` unchanged.
- `DiscoverCardView` unchanged.
- VM core: queue / swipe / topup / library + LLM sources / matched /
  picksMilestoneTick / autoJumpEnabled / mediaSelection / hasPickedKind.
- `configureDiscover` in PopoverContentView — must still wire sources.
- `arrBarrOpenDiscoverInTinder` notification + `discover_in_tinder` chat tool.

### Replaced

- The notification handler in `PopoverContentView` no longer flips
  `selectedTab` or `stage`. It sets `moodText`, opens the overlay, and
  triggers `reshuffle()`.
- The popover renders `DiscoverTabView` as a `ZStack` overlay (same pattern
  as `SearchAddPanel`), shown when a new `@State discoverOverlay: Bool` is
  true. `FloatingBackButton` inside the overlay closes it via a callback
  prop (`onClose`).
- `DiscoverTabView`'s top bar shows the truncated prompt as a non-tappable
  breadcrumb chip (read-only), keeping the visual treatment for orientation.

## Non-goals

- No new visible chat UI affordance pushing Discover (the existing tool
  call is sufficient).
- No "history of opened tinders" or pinning.
- No change to how matched picks are persisted (still in-memory only).
- No change to the tinder card UI itself.

## Files touched

- `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` — tab
  removal, overlay rendering, notification handler rewrite,
  `configureDiscover` call site relocation.
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift` — body
  simplification, top-bar chip non-tappable, accept `onClose` prop.
- `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift` —
  drop `DiscoverStage` enum + `stage` property + `userSubmittedMood`.
- `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift` —
  drop any test referencing `stage` / `userSubmittedMood` (if present).
- `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift` —
  deleted.

## Trade-offs accepted

- Users who liked the dedicated tab will have to learn the chat path. The
  chat tool description should make the trigger obvious.
- `configureDiscover` now fires on every popover appear (not just on tab
  switch). Source wiring is cheap (closures only — library fetch is lazy),
  but worth keeping an eye on.
