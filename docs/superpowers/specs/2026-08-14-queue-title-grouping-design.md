# Queue title grouping — design

Date: 2026-08-14
Status: approved

## Problem

A mass grab of a series can put 100 near-identical rows for one title into the
queue view. The popover is a glance surface; a wall of sibling episodes buries
everything else. (Radarr can hit a milder version: two grabs of one movie
during an upgrade race.)

History: an earlier "virtual bundle" feature collapsed same-fingerprint
episodes into one merged row and was deliberately removed — the merged row
pretended N downloads were one (weighted-average progress, silent action
fan-out). See the comment in `Models/QueueGroup.swift`. This design groups as a
**visual container with real child rows**, never a merged row.

## Decisions (agreed with user)

- Group queue entries **by title** (seriesId / movieId / artistId), only when a
  title has **≥2 entries**. All arrs: Sonarr, Radarr, Lidarr, Whisparr.
- Groups are **collapsed by default**.
- Header tap toggles expansion; DetailView opens via poster tap / trailing
  arrow (hover-revealed, like today's rows).
- Collapsed header shows poster, title, count ("12 downloads"), and an
  **aggregate size-weighted progress bar** with percent — honest because the
  count says it's an aggregate.
- Header bulk actions: Pause all / Resume all / Delete all, each labelled with
  the count; delete always confirms with the count. Fan-out is an explicit
  loop over children.
- Sorting: the group takes the position of its **best child** under the active
  sort.
- Filters/search match **children**; the group shrinks to matching children
  with a "3 of 12" count and disappears at zero matches.
- Multi-select: header has **no** selection circle; selecting requires
  expanding. "Delete whole title" is covered by the header's Delete all.
- Season packs (shared-downloadId groups) render inside a title group as one
  child row, exactly as today; the header count treats a pack as **1
  download**.
- Expansion state: in-memory, keyed by title identity — survives realtime
  refreshes, resets with the popover session.
- Settings: one picker **"Group queue by title": Off / Collapsed / Expanded**,
  default Collapsed, stored in `ConfigStore` and KV-synced. Expanded = groups
  render as a visual frame that starts open.
- **No dedicated second-level queue view.** The existing DetailView (with
  `DownloadSection` listing all sibling downloads, per-item controls) already
  serves that role. Widgets and MCP keep receiving the flat queue.

## Architecture

### Model layer (`Packages/ArrCore/Sources/ArrCore/Models/`)

A second grouping pass layered over the existing one:

1. `QueueGrouping.group(_:)` runs unchanged, producing `[QueueRowEntry]`
   (singles + season-pack `.group`s).
2. A new pass buckets those entries by title identity. Identity is
   per-service: Sonarr/Whisparr `seriesId`, Radarr `movieId`, Lidarr
   `artistId` — combined with the source service so ids never collide across
   arrs.
3. Buckets with ≥2 entries become a title group; the row hierarchy gains a
   case for it (children are the existing entries — exactly one nesting
   level). Singleton buckets pass through untouched.
4. The pass is a pure function taking the grouping mode (off / collapsed /
   expanded) so it is trivially testable; `off` returns input unchanged.

Group-derived values (pure helpers on the group type):

- `downloadCount` — number of child entries (a pack counts as 1).
- Aggregate progress — size-weighted across all underlying `QueueItem`s.
- Sort key — delegates to the best child under the active sort.
- Filtered view — given a child predicate, returns the surviving children plus
  the total, for the "3 of 12" label; empty ⇒ the group is dropped.

### View model / state

- Expansion state lives with the queue UI state (popover-session lifetime):
  a `Set` of title-identity keys meaning "toggled away from the default".
  With default Collapsed the set holds expanded titles; with default Expanded
  it holds collapsed ones — so a mode switch or fresh session naturally
  resets.
- `ConfigStore` gains the grouping-mode preference (enum, raw-value
  persisted, registered in `SyncedKeys`).

### Views (`Packages/ArrCore/Sources/ArrCore/Views/`)

- New `QueueTitleGroupRowView`: header row + (when expanded) indented child
  rows. Children are rendered by the existing `QueueRowView` /
  `QueueGroupRowView` unchanged.
- Header: poster (`PosterBlurContainer` + `RemotePoster`), title, count
  caption, aggregate progress bar (custom `GeometryReader` bar per house
  pattern — never `ProgressView`), chevron rotating on expansion.
- Interactions: row tap toggles; poster tap / trailing hover arrow →
  `onShowDetail` with a representative item (series context, episode coords
  stripped — same as pack rows). macOS hover cluster and iOS swipe/context
  menu expose Pause all / Resume all / Delete all with counts;
  delete goes through `ConfirmCenter` naming the count. iOS confirmations use
  native dialogs.
- `QueueSectionView` / `QueueListView` render the new case and keep section
  `itemCount` counting individual queue items. Multi-select overlays appear
  only on child rows, never the header.
- Accessibility mirrors the section-header treatment: combined element,
  button trait, expand/collapse hint; all new strings go through
  `Localizable.xcstrings` (en/de/es/fr/pl).

### Settings

One row in the queue/appearance area of `SettingsView`: picker "Group queue by
title" with Off / Collapsed / Expanded, default Collapsed.

## Error handling

No new failure surface: bulk actions reuse the existing per-item pause /
resume / delete paths (packs act through their representative, as
`deleteAll(_:)` does today). Partial failures surface exactly as they do for
individual actions; arr error bodies remain the message source.

## Testing

SwiftPM tests in `ArrCoreTests` (Swift Testing) over the pure logic:

- Bucketing: threshold ≥2, per-service identity separation, pass-through when
  off, packs nested as one child, stable child order.
- Aggregate progress weighting and `downloadCount` with packs.
- Best-child sort key under different sorts.
- Filter shrinking: partial match counts, zero-match drop.

UI verified visually via demo mode (macOS build + relaunch), which needs
demo fixtures containing a many-download title.

## Out of scope

- Dedicated second-level queue view (DetailView already covers it).
- Widget / MCP / AppIntents changes — they keep the flat queue.
- Persisted (cross-session) expansion state.
- Configurable grouping threshold.
