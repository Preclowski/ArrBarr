# Refactor: List-based queue + native swipe (macOS + iOS)

**Goal:** render the queue with SwiftUI `List` so each row is a real cell with
native `.swipeActions` (swipe-left = Delete, optional leading pause/resume),
replacing the custom `SwipeToDeleteRow` drag gesture. Both platforms.

## Why it's not trivial
`List` only turns its **direct** children into rows. Today `QueueSectionView`
is one opaque `View` that internally stacks header + a `VStack` of rows — placed
in a `List` it would be a single cell, so `.swipeActions` would swipe the whole
section. The rows must become direct `List` content.

## Target architecture
A shared `QueueListView` owns the `List`; section rendering is inlined (or via
`@ViewBuilder` helpers that emit rows directly, NOT a wrapping `View`).

```
List {
    // banners as their own rows/sections
    if showTonight { tonightBannerRow }            // .listRowInsets/.listRowSeparator(.hidden)
    if showNeedsYou { needsYouRows }
    ForEach(scopedSources) { source in
        Section {
            if collapsed(source) == false {
                ForEach(entries(for: source)) { entry in
                    QueueRowView(...)               // bare row, no custom swipe
                        .listRowInsets(...).listRowSeparator(.hidden).listRowBackground(.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                        }
                        // optional leading: pause/resume
                }
            }
        } header: { sectionHeader(source) }          // collapse chevron, count, health, history, per-arr error
    }
}
.listStyle(.plain)
.scrollContentBackground(.hidden)   // keep the app's dark background
.environment(\.defaultMinListRowHeight, 0)
```

`QueueSectionView` is reduced to (or replaced by) free `@ViewBuilder`
helpers: `sectionHeader(source)`, `entries(for:)`, `deleteClosure(for:)` —
already factored in QueueSectionView, lift them into the shared file.

## Must preserve
- Section collapse (chevron) + animation.
- Per-arr error banner + health badge + "Show history".
- Banners: "Next week" (tonight) + "Needs you".
- Scope narrowing (macOS scope chips) → `scopedSources`.
- Search surface: typing shows `QueueSearchResultsView` (already shared). On
  iOS keep `.searchable`; on macOS keep the floating filter bar. The List is the
  non-filtering body; when filtering, swap to the search results (can stay a
  ScrollView or also become a List — search rows don't need swipe).
- macOS: floating filter bar stays as the `ZStack(.bottom)` overlay over the List.
- "Queue empty" / "not configured" empty states.

## Files
- New: `QueueListView.swift` (shared List body + section helpers).
- `iOSAppRoot.swift` (QueueTab): use `QueueListView`; drop the ScrollView/VStack.
- `QueueTabContent.swift` (macOS): use `QueueListView` for the non-filtering body
  inside the existing ZStack + filter bar.
- `QueueSectionView.swift`: demote to header/helper provider, or delete if fully
  absorbed (check other callers first).
- Delete `SwipeToDeleteRow.swift` + remove `.queueSwipeToDelete` call sites.

## Risks / verify
- macOS popover (MenuBarExtra .window): List background transparency, sizing,
  no extra inset/separators. Verify visually — CLI can't.
- Collapse animation inside List sections (may differ from VStack).
- Banner rows styling (full-width, no separators).
- Pause/resume hover icons on macOS rows vs swipe — decide whether macOS keeps
  hover actions AND gains trackpad swipe (fine) .

## Steps
1. Build `QueueListView` with sections + swipeActions; wire iOS first, verify.
2. Wire macOS QueueTabContent; verify popover.
3. Remove custom swipe + dead QueueSectionView paths.
4. Build macOS + iOS + device; manual pass on both.
