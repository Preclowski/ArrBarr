# Discover Picker Composer-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the cluttered five-row Discover picker with a composer-first layout where filters become chips inside the composer, a single Suggestions row shows usage-sorted popular pills, and "More filters" auto-expands when the user types.

**Architecture:** Heavy rewrite of `DiscoverPickerView.swift` body and supporting subviews. Light addition to `DiscoverViewModel.swift` — a `SuggestedFilter` value type and a `suggestedFilters` computed property. All existing VM state (`filter`, `selectedPersonNames`, `customMoods`, `customPeople`, `customTagsByCategory`, usage counts, persistence) is unchanged. Behaviour parity is required: every existing pill / `+ Add` / commit / kind-switch flow keeps working.

**Tech Stack:** SwiftUI, macOS 26 SDK, XCTest, Swift Package Manager (ArrCore package).

**Worktree:** `/Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab`. **All `xcodebuild` and `swift test` calls must `cd` into the worktree first** — the shell's `pwd` resets to the main repo between turns, and building from the main repo produces stale binaries that silently mask your changes.

**Reference spec:** `docs/superpowers/specs/2026-05-25-discover-picker-composer-first.md`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift` | Modify (add ~80 lines) | New `SuggestedFilter` DTO, `suggestedFilters` computed property |
| `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift` | Rewrite body (~50% of file) | Composer-first layout; reuse existing `PillButtonView`, `addPersonChip`, `addCustomTagChip`, category-row rendering |
| `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` | Append entries | New placeholder strings, "More filters", "Add filter" hint |
| `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift` | Append 3 tests | Cover `suggestedFilters` |

The picker file has been growing — it's ~900 lines today. We're not splitting it as part of this work (out of scope), but the new composer + suggestions code goes into clearly demarcated MARK sections so a future split is mechanical.

---

## Task 1: VM — `SuggestedFilter` DTO + `suggestedFilters` computed property

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

The View needs a flat, deduplicated, usage-sorted list of suggestion pills. Putting the logic in the VM keeps the View thin and gives us cheap unit tests.

- [ ] **Step 1: Write the failing test for usage-sorted ordering**

Append to `DiscoverViewModelTests.swift`:

```swift
func test_suggestedFilters_sortsByUsageDescending() {
    let vm = freshVM()
    vm.bumpPersonUsage("Quentin Tarantino")
    vm.bumpPersonUsage("Quentin Tarantino")
    vm.bumpPersonUsage("Christopher Nolan")
    let ids = vm.suggestedFilters.map(\.id)
    let tarantinoIdx = ids.firstIndex(of: "person.Quentin Tarantino")
    let nolanIdx = ids.firstIndex(of: "person.Christopher Nolan")
    XCTAssertNotNil(tarantinoIdx)
    XCTAssertNotNil(nolanIdx)
    XCTAssertLessThan(tarantinoIdx!, nolanIdx!,
                      "More-used Tarantino should come before less-used Nolan")
}
```

- [ ] **Step 2: Run test to confirm it fails**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter test_suggestedFilters_sortsByUsageDescending
```

Expected: compile error "Value of type 'DiscoverViewModel' has no member 'suggestedFilters'".

- [ ] **Step 3: Add the DTO type to DiscoverViewModel.swift**

Just above the `@MainActor public final class DiscoverViewModel` declaration, add:

```swift
/// View-layer DTO describing a suggested filter pill. The VM emits these
/// already-ordered and deduplicated against the active filter, so the View
/// just renders them in sequence.
public struct SuggestedFilter: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable {
        case people, genre, decade, rating, runtime
    }
    public let id: String       // e.g. "person.Quentin Tarantino", "genre.action"
    public let label: String    // display label as-is
    public let category: Category
    public let icon: String?    // SF Symbol name; matches the in-picker icons
}
```

- [ ] **Step 4: Add the `suggestedFilters` computed property**

Find the `// MARK: - Person filter helpers` section. Just above it, insert:

```swift
// MARK: - Suggested filters

/// Up to 10 pills the View renders in the Suggestions row. Top 8 are the
/// user's most-used catalog items (across all categories); the remaining
/// up-to-2 slots are filled with curated discovery defaults that the user
/// has *never* used, so a brand-new picker still shows a useful row. Active
/// filters (already chips in the composer) are excluded — the row never
/// duplicates what's already selected.
public var suggestedFilters: [SuggestedFilter] {
    let pool = Self.curatedPool(mediaSelection: mediaSelection)
    let active = activeFilterIds()
    let usage = combinedUsage()
    let candidates = pool.filter { !active.contains($0.id) }
    let used = candidates
        .filter { (usage[$0.id] ?? 0) > 0 }
        .sorted { (usage[$0.id] ?? 0) > (usage[$1.id] ?? 0) }
    let unused = candidates.filter { (usage[$0.id] ?? 0) == 0 }
    let topUsed = Array(used.prefix(8))
    let discoveryCount = max(0, 10 - topUsed.count)
    let discovery = Array(unused.prefix(discoveryCount))
    return topUsed + discovery
}

/// Curated default catalog. Order doubles as the cold-start sort —
/// when no usage data exists, the View shows the first 10 entries.
/// Length pills are dropped for `.show` (Sonarr has no runtime filter).
private static func curatedPool(mediaSelection: DiscoverMediaSelection) -> [SuggestedFilter] {
    var pool: [SuggestedFilter] = [
        .init(id: "person.Quentin Tarantino", label: "Quentin Tarantino",
              category: .people, icon: "person.fill"),
        .init(id: "person.Christopher Nolan", label: "Christopher Nolan",
              category: .people, icon: "person.fill"),
        .init(id: "person.Adam Sandler", label: "Adam Sandler",
              category: .people, icon: "person.fill"),
        .init(id: "person.Leonardo DiCaprio", label: "Leonardo DiCaprio",
              category: .people, icon: "person.fill"),
        .init(id: "genre.\(DiscoverGenre.comedy.rawValue)", label: "Comedy",
              category: .genre, icon: "face.smiling"),
        .init(id: "genre.\(DiscoverGenre.drama.rawValue)", label: "Drama",
              category: .genre, icon: "theatermasks"),
        .init(id: "genre.\(DiscoverGenre.horror.rawValue)", label: "Horror",
              category: .genre, icon: "drop"),
        .init(id: "genre.\(DiscoverGenre.scienceFiction.rawValue)", label: "Sci-Fi",
              category: .genre, icon: "atom"),
        .init(id: "decade.\(DiscoverDecade.nineties.rawValue)", label: "1990s",
              category: .decade, icon: "calendar"),
        .init(id: "decade.\(DiscoverDecade.twoThousands.rawValue)", label: "2000s",
              category: .decade, icon: "calendar"),
        .init(id: "rating.\(DiscoverRatingTier.highlyRated.rawValue)", label: "Highly rated",
              category: .rating, icon: "star.fill"),
    ]
    if mediaSelection != .show {
        pool.append(.init(id: "runtime.\(DiscoverRuntime.short.rawValue)",
                          label: "Short", category: .runtime, icon: "hare"))
    }
    return pool
}

/// IDs currently active in `filter` / `selectedPersonNames`, used to
/// deduplicate the Suggestions row against the composer chips.
private func activeFilterIds() -> Set<String> {
    var out: Set<String> = []
    for name in selectedPersonNames { out.insert("person.\(name)") }
    for g in filter.genres { out.insert("genre.\(g.rawValue)") }
    if filter.decade != .any { out.insert("decade.\(filter.decade.rawValue)") }
    if filter.rating != .any { out.insert("rating.\(filter.rating.rawValue)") }
    if filter.runtime != .any { out.insert("runtime.\(filter.runtime.rawValue)") }
    return out
}

/// Merge person + mood usage maps into a single id-keyed lookup so the
/// suggestions sort can compare across categories.
private func combinedUsage() -> [String: Int] {
    var u: [String: Int] = [:]
    for (name, count) in personUsageCount {
        u["person.\(name)"] = count
    }
    for (label, count) in moodUsageCount {
        u["mood.\(label)"] = count
    }
    return u
}
```

- [ ] **Step 5: Run the first test — it should now pass**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter test_suggestedFilters_sortsByUsageDescending
```

Expected: PASS.

- [ ] **Step 6: Write the dedupe-against-active test**

Append to `DiscoverViewModelTests.swift`:

```swift
func test_suggestedFilters_excludesActiveFilters() {
    let vm = freshVM()
    vm.filter.genres = [.comedy]
    let ids = vm.suggestedFilters.map(\.id)
    XCTAssertFalse(ids.contains("genre.\(DiscoverGenre.comedy.rawValue)"),
                   "Comedy is active, should not appear in suggestions")
    XCTAssertTrue(ids.contains("genre.\(DiscoverGenre.drama.rawValue)"),
                  "Inactive Drama should still appear")
}
```

- [ ] **Step 7: Write the cold-start test**

Append to `DiscoverViewModelTests.swift`:

```swift
func test_suggestedFilters_coldStartReturnsCuratedTen() {
    let vm = freshVM()
    let filters = vm.suggestedFilters
    XCTAssertEqual(filters.count, 10,
                   "Fresh VM should show 10 curated discovery suggestions")
    // First entry should be the top-of-curation Tarantino.
    XCTAssertEqual(filters.first?.id, "person.Quentin Tarantino")
}
```

- [ ] **Step 8: Run all Discover tests**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover
```

Expected: 40 tests, 0 failures (37 existing + 3 new).

- [ ] **Step 9: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift
git commit -m "feat(discover): suggestedFilters VM API for composer-first picker"
```

---

## Task 2: Composer chip subview (`ChipComposerView`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

The composer becomes a wrapping container of: kind chip + active-filter chips + inline TextField + send button. We build it as a private struct inside `DiscoverPickerView` so it has access to the `viewModel` via a passed-in observed object and can drive `freeText` / `freeTextFocused` from the parent.

- [ ] **Step 1: Add helper enum for category color**

Inside `DiscoverPickerView`, just above the existing `private static let predefinedPeople` line, add:

```swift
/// Color used by both the Suggestions row and the in-composer chips
/// to keep the per-category palette consistent.
private static func color(for category: SuggestedFilter.Category) -> Color {
    switch category {
    case .people:  return .teal
    case .genre:   return .blue
    case .decade:  return .orange
    case .rating:  return .green
    case .runtime: return .purple
    }
}
```

- [ ] **Step 2: Add a chip-descriptor helper that turns active filter state into chip rows**

Inside `DiscoverPickerView`, just above `body`, add:

```swift
/// Snapshot of every filter currently active. Composer renders one chip
/// per entry, in insertion-friendly category order (people → genre →
/// decade → rating → runtime). Each entry carries the closure that
/// removes the filter when the chip's × is tapped.
private struct ActiveChipDescriptor: Identifiable {
    let id: String
    let label: String
    let category: SuggestedFilter.Category
    let onRemove: () -> Void
}

private var activeChips: [ActiveChipDescriptor] {
    var out: [ActiveChipDescriptor] = []
    for name in viewModel.selectedPersonNames.sorted() {
        out.append(.init(id: "person.\(name)", label: name, category: .people) {
            Task { await viewModel.togglePerson(name: name) }
        })
    }
    for g in viewModel.filter.genres.sorted(by: { $0.rawValue < $1.rawValue }) {
        out.append(.init(id: "genre.\(g.rawValue)", label: g.displayName, category: .genre) {
            viewModel.filter.genres.remove(g)
            viewModel.userChangedFilter()
        })
    }
    if viewModel.filter.decade != .any {
        let d = viewModel.filter.decade
        out.append(.init(id: "decade.\(d.rawValue)", label: d.rawValue, category: .decade) {
            viewModel.filter.decade = .any
            viewModel.userChangedFilter()
        })
    }
    if viewModel.filter.rating != .any {
        let r = viewModel.filter.rating
        out.append(.init(id: "rating.\(r.rawValue)",
                         label: r.rawValue.capitalized, category: .rating) {
            viewModel.filter.rating = .any
            viewModel.userChangedFilter()
        })
    }
    if viewModel.filter.runtime != .any {
        let rt = viewModel.filter.runtime
        out.append(.init(id: "runtime.\(rt.rawValue)",
                         label: rt.rawValue.capitalized, category: .runtime) {
            viewModel.filter.runtime = .any
            viewModel.userChangedFilter()
        })
    }
    return out
}
```

- [ ] **Step 3: Write the new `chipComposer` view**

Inside `DiscoverPickerView`, just above the existing `private var composer:` definition, add:

```swift
// MARK: - Chip composer

/// Tag-input style composer:
///   [🎞 Movies][Tarantino ×][Comedy ×]  Or describe…  [↑]
/// Chips wrap to additional rows via FlowLayout; the TextField flows
/// inline after the last chip and absorbs the remaining space.
private var chipComposer: some View {
    FlowLayout(spacing: 5) {
        kindChip
        ForEach(activeChips) { chip in
            activeChipView(chip)
        }
        TextField("", text: $freeText,
                  prompt: Text(LocalizedStringKey(currentPlaceholder),
                               bundle: .module),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .focused($freeTextFocused)
            .lineLimit(1...4)
            .scaledFont(size: 13)
            .frame(minWidth: 80)
            .onSubmit {
                if canCommit { commit() }
            }
            .onKeyPress(.delete) {
                // Backspace on empty text removes the last chip — the
                // standard tag-input affordance. If text is non-empty,
                // let the OS handle the deletion normally.
                if freeText.isEmpty, let last = activeChips.last {
                    last.onRemove()
                    return .handled
                }
                return .ignored
            }
        sendButton
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .glassyFloatingBar()
}

@ViewBuilder
private var kindChip: some View {
    Button {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            viewModel.mediaSelection =
                (viewModel.mediaSelection == .movie) ? .show : .movie
            viewModel.hasPickedKind = true
            viewModel.mediaSelectionChanged()
        }
    } label: {
        HStack(spacing: 4) {
            Image(systemName: viewModel.mediaSelection == .show ? "tv" : "film")
                .scaledFont(size: 10, weight: .semibold)
            Text(viewModel.mediaSelection == .show ? "Shows" : "Movies",
                 bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help(Text("Switch movie/show kind", bundle: .module))
}

@ViewBuilder
private func activeChipView(_ chip: ActiveChipDescriptor) -> some View {
    let color = Self.color(for: chip.category)
    HStack(spacing: 3) {
        Text(chip.label)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
        Button(action: chip.onRemove) {
            Image(systemName: "xmark")
                .scaledFont(size: 8, weight: .bold)
                .foregroundStyle(color.opacity(0.7))
        }
        .buttonStyle(.plain)
    }
    .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 3)
    .overlay(
        Capsule().stroke(color.opacity(0.85), lineWidth: 1)
    )
}

@ViewBuilder
private var sendButton: some View {
    Button {
        if canCommit { commit() }
    } label: {
        Image(systemName: "arrow.up.circle.fill")
            .scaledFont(size: 22)
            .foregroundStyle(canCommit ? Color.primary : Color.secondary.opacity(0.4))
    }
    .buttonStyle(.plain)
    .disabled(!canCommit)
    .keyboardShortcut(.return, modifiers: [.command])
}
```

- [ ] **Step 4: Add the rotating placeholder logic**

Inside `DiscoverPickerView`, just above the `body` declaration, add:

```swift
@State private var placeholderTick: Int = 0

/// Rotates every 3 seconds while composer is empty and unfocused. Goes
/// quiet while focused so it doesn't fight the cursor.
private static let placeholderRotation: [String] = [
    "Try: Cozy Sunday afternoon…",
    "Try: Friends over with pizza…",
    "Try: Date night…",
    "Try: Long flight…",
    "Try: Crowd-pleaser…",
]

private var currentPlaceholder: String {
    if !activeChips.isEmpty {
        return "Or describe…"
    }
    return Self.placeholderRotation[
        placeholderTick % Self.placeholderRotation.count
    ]
}
```

Then, at the end of `body` (after the outer VStack closing brace, before the function-level closing brace), wire a TimelineView-driven tick. Replace the existing `body` content with the following structure — keep the inner pieces intact, just wrap them and add the timer at the end:

```swift
public var body: some View {
    VStack(spacing: 0) {
        mainPickerScroll
        chipComposer
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }
    .task {
        // Drives `placeholderTick` so the placeholder rotates every 3s.
        // Pauses when freeTextFocused — focus-gating is checked inside.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !freeTextFocused && freeText.isEmpty && activeChips.isEmpty {
                placeholderTick &+= 1
            }
        }
    }
}
```

- [ ] **Step 5: Build to verify the composer compiles**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): chip-composer with active-filter chips + rotating placeholder"
```

---

## Task 3: Suggestions row

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

Single horizontal `FlowLayout` row, no header, no chrome — just colored pills derived from `viewModel.suggestedFilters`. Tap mutates the same filter state the existing pills already touch.

- [ ] **Step 1: Add the `suggestionsRow` view**

Inside `DiscoverPickerView`, just above the existing `mainPickerScroll` declaration, add:

```swift
// MARK: - Suggestions row

/// Compact row of pills sourced from `viewModel.suggestedFilters`. Tap
/// behaviour mirrors the in-catalog pill taps — flips the same filter
/// state, so picked items move to the composer as a chip and disappear
/// from this row in the same frame (the VM dedupes).
@ViewBuilder
private var suggestionsRow: some View {
    let suggestions = viewModel.suggestedFilters
    if !suggestions.isEmpty {
        FlowLayout(spacing: 5) {
            ForEach(suggestions) { s in
                suggestionPill(s)
            }
        }
    }
}

@ViewBuilder
private func suggestionPill(_ s: SuggestedFilter) -> some View {
    SuggestionPillButton(
        label: s.label,
        icon: s.icon,
        color: Self.color(for: s.category),
        action: { applySuggestion(s) }
    )
}

private func applySuggestion(_ s: SuggestedFilter) {
    switch s.category {
    case .people:
        let name = String(s.id.dropFirst("person.".count))
        viewModel.bumpPersonUsage(name)
        Task { await viewModel.togglePerson(name: name) }
    case .genre:
        if let g = DiscoverGenre.allCases.first(where: {
            "genre.\($0.rawValue)" == s.id
        }) {
            if viewModel.filter.genres.contains(g) {
                viewModel.filter.genres.remove(g)
            } else {
                viewModel.filter.genres.insert(g)
            }
            viewModel.userChangedFilter()
        }
    case .decade:
        if let d = DiscoverDecade.allCases.first(where: {
            "decade.\($0.rawValue)" == s.id
        }) {
            viewModel.filter.decade =
                (viewModel.filter.decade == d) ? .any : d
            viewModel.userChangedFilter()
        }
    case .rating:
        if let r = DiscoverRatingTier.allCases.first(where: {
            "rating.\($0.rawValue)" == s.id
        }) {
            viewModel.filter.rating =
                (viewModel.filter.rating == r) ? .any : r
            viewModel.userChangedFilter()
        }
    case .runtime:
        if let rt = DiscoverRuntime.allCases.first(where: {
            "runtime.\($0.rawValue)" == s.id
        }) {
            viewModel.filter.runtime =
                (viewModel.filter.runtime == rt) ? .any : rt
            viewModel.userChangedFilter()
        }
    }
}

/// Bare colored pill with hover state. Same idiom as the catalog
/// `PillButtonView` but always-colored (no "secondary when unpicked"
/// state, because the row never shows already-picked items).
private struct SuggestionPillButton: View {
    let label: String
    let icon: String?
    let color: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let strokeOpacity: Double = isHovering ? 0.95 : 0.55
        let strokeWidth: CGFloat = isHovering ? 1.2 : 1.0
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(size: 8, weight: .semibold)
                }
                Text(label)
                    .scaledFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(color.opacity(strokeOpacity), lineWidth: strokeWidth)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): suggestions row + per-category tap routing"
```

---

## Task 4: More-filters disclosure

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

The disclosure wraps the existing `pillRows` (which already renders all five categories with `+ Add` chips and custom additions). We only need to add the chevron + auto-expand logic. No layout work inside the rows.

- [ ] **Step 1: Add disclosure state**

In the `@State` block at the top of `DiscoverPickerView` (after `newCustomTagFocused`), add:

```swift
/// True once the user has manually clicked the disclosure chevron in
/// the current session. Once set, auto-collapse on empty text no longer
/// fires — the user's explicit choice wins.
@State private var moreFiltersManuallyExpanded: Bool = false
```

- [ ] **Step 2: Add the computed expansion flag**

Just above `chipComposer`, add:

```swift
private var moreFiltersExpanded: Bool {
    !freeText.trimmingCharacters(in: .whitespaces).isEmpty
        || moreFiltersManuallyExpanded
}
```

- [ ] **Step 3: Add the disclosure header view**

Just above `pillRows`, add:

```swift
// MARK: - More filters disclosure

@ViewBuilder
private var moreFiltersChevron: some View {
    Button {
        withAnimation(.smooth(duration: 0.2)) {
            moreFiltersManuallyExpanded.toggle()
        }
    } label: {
        HStack(spacing: 4) {
            Image(systemName: moreFiltersExpanded ? "chevron.down" : "chevron.right")
                .scaledFont(size: 9, weight: .semibold)
            Text("More filters", bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): more-filters disclosure (auto-expand on type)"
```

---

## Task 5: Wire it all into the picker — delete old surfaces

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

Replace `mainPickerScroll` so it renders: TMDB banner → Suggestions row → More filters chevron → (conditionally) full `pillRows` → starters/composer slot (composer is now outside the scroll, in `body`). Delete the old `kindSelectorBar`, `moodStarters`, `starterPill`, `starterThemes`, `discoverButtonFallback`, and the old `composer` view since they're all replaced.

- [ ] **Step 1: Replace `mainPickerScroll`**

Find the current `mainPickerScroll` declaration. Replace its entire body with:

```swift
private var mainPickerScroll: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            tmdbMissingBanner
            suggestionsRow
            moreFiltersChevron
            if moreFiltersExpanded {
                pillRows
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.22), value: moreFiltersExpanded)
    }
}
```

- [ ] **Step 2: Delete the obsolete surfaces**

Search for each of the following declarations in `DiscoverPickerView.swift` and **delete** the entire block (declaration + body):

- `private var kindSelectorBar: some View { … }`
- `@ViewBuilder private func kindButton(_ kind: …) -> some View { … }`
- `@ViewBuilder private var moodStarters: some View { … }`
- `@ViewBuilder private func starterPill(_ prompt: String) -> some View { … }`
- `private struct StarterPillButton: View { … }`
- `private struct StarterTheme { … }`
- `private static let starterThemes: [StarterTheme] = [ … ]`
- `private var composer: some View { … }`
- `private var composerPlaceholder: LocalizedStringKey { … }`
- `private var discoverButtonFallback: some View { … }`

Also remove the `freeTextFocused = false` line at the bottom of `commit()` if `commit()` is now only reached via the `chipComposer` send button — but **keep `commit()` itself**; it still does the work.

- [ ] **Step 3: Verify `canCommit` still exists and update it**

Find the `private var canCommit: Bool` declaration. Update it so it considers chips as a commit signal too:

```swift
private var canCommit: Bool {
    viewModel.hasPickedKind
        || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !activeChips.isEmpty
}
```

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|warning:" | head -10
```

Expected: zero errors. Warnings about unused `discoverButtonFallback`/etc. should all be gone because we deleted them. If you see `error: cannot find` for a reference still pointing to a deleted surface, follow the line number and delete the orphaned reference.

- [ ] **Step 5: Run all Discover tests**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover
```

Expected: 40 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): composer-first picker layout, drop obsolete surfaces"
```

---

## Task 6: Localization

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

New strings introduced by Tasks 2–5: rotating placeholders, "Or describe…", "More filters", "Switch movie/show kind".

- [ ] **Step 1: Run the injector script for the new entries**

Run from the worktree:

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
python3 <<'EOF'
import json
from pathlib import Path
p = Path("Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings")
data = json.loads(p.read_text())
entries = [
    ("Try: Cozy Sunday afternoon…",
     "Versuch: Gemütlicher Sonntagnachmittag…",
     "Prueba: Tarde de domingo tranquila…",
     "Essaie : Dimanche après-midi cocooning…",
     "Spróbuj: Spokojne niedzielne popołudnie…"),
    ("Try: Friends over with pizza…",
     "Versuch: Freunde mit Pizza…",
     "Prueba: Amigos con pizza…",
     "Essaie : Amis avec pizza…",
     "Spróbuj: Znajomi i pizza…"),
    ("Try: Date night…",
     "Versuch: Date Night…",
     "Prueba: Cita nocturna…",
     "Essaie : Soirée en couple…",
     "Spróbuj: Randka…"),
    ("Try: Long flight…",
     "Versuch: Langer Flug…",
     "Prueba: Vuelo largo…",
     "Essaie : Long vol…",
     "Spróbuj: Długi lot…"),
    ("Try: Crowd-pleaser…",
     "Versuch: Publikumshit…",
     "Prueba: Para todos…",
     "Essaie : Pour tout le monde…",
     "Spróbuj: Dla wszystkich…"),
    ("Or describe…",
     "Oder beschreiben…",
     "O describe…",
     "Ou décris…",
     "Albo opisz…"),
    ("More filters",
     "Weitere Filter",
     "Más filtros",
     "Plus de filtres",
     "Więcej filtrów"),
    ("Switch movie/show kind",
     "Film/Serie umschalten",
     "Cambiar película/serie",
     "Basculer film/série",
     "Przełącz film/serial"),
]
strings = data.get("strings", {})
added = []
for key, de, es, fr, pl in entries:
    if key in strings: continue
    strings[key] = {
        "extractionState": "manual",
        "localizations": {
            "de": {"stringUnit": {"state": "translated", "value": de}},
            "es": {"stringUnit": {"state": "translated", "value": es}},
            "fr": {"stringUnit": {"state": "translated", "value": fr}},
            "pl": {"stringUnit": {"state": "translated", "value": pl}},
        }
    }
    added.append(key)
data["strings"] = strings
p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
print("Added:", added)
EOF
```

Expected output: `Added: ['Try: Cozy Sunday afternoon…', …, 'Switch movie/show kind']` (8 entries).

- [ ] **Step 2: Build to verify xcstrings parses**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "i18n(discover): translations for composer-first picker strings"
```

---

## Task 7: Manual verification + final relaunch

**Files:**
- None modified.

This is the eyes-on check before declaring done.

- [ ] **Step 1: Rebuild from the worktree**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Kill any running app + launch fresh**

Run:
```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5
open /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab/build/Build/Products/Debug/ArrBarr.app
stat -f "%Sm" -t "%H:%M:%S" /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab/build/Build/Products/Debug/ArrBarr.app/Contents/MacOS/ArrBarr
```

Expected: a fresh timestamp within the last minute.

- [ ] **Step 3: Eyes-on checklist (open the popover → Discover tab → picker)**

Tick each:
- Fresh picker shows: composer (kind chip "🎞 Movies" + placeholder rotating every 3s + dimmed ↑) + Suggestions row (≤10 pills, colored) + "▸ More filters" chevron. No category headers visible.
- Tap a Suggestions pill → it becomes a colored chip inside the composer; the original pill disappears from the row; ↑ activates.
- Tap the chip's × → chip removed; pill reappears in the Suggestions row.
- Tap kind chip → toggles "🎞 Movies" ↔ "📺 Shows".
- Type one character in the composer → "More filters" auto-expands with full 5 categories + `+ Add` chips.
- Delete that character → "More filters" auto-collapses (unless you also clicked the chevron manually).
- Click chevron once explicitly → manually expanded. Type then clear → stays expanded.
- Backspace on empty text after picking chips → last chip is removed.
- Hit ↑ (or Enter, or Cmd-Return) with any chip set → picker dismisses, tinder loads with that filter.

- [ ] **Step 4: Run the full Discover test suite one more time**

Run:
```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover
```

Expected: 40 tests, 0 failures.

- [ ] **Step 5: Final commit (only if any cleanup was needed during verification)**

If verification surfaced minor fixes (e.g. a typo, a missing edge case), commit them now. Otherwise this step is a no-op:

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git status   # confirm clean
```

Expected: `nothing to commit, working tree clean`.

---

## Spec Coverage Self-Check

| Spec section | Covered by |
|---|---|
| ChipComposer (kind chip + active chips + TextField + send) | Task 2 |
| SuggestionsRow (≤10 pills, usage-sorted + discovery, dedupe) | Tasks 1, 3 |
| MoreFiltersDisclosure (auto-expand on type, manual lock) | Task 4 |
| VM `suggestedFilters` + `SuggestedFilter` DTO | Task 1 |
| Behavior parity (every pill / + Add / commit flow) | Task 5 (reuses pillRows) + Task 7 eyes-on |
| Backspace on empty deletes last chip | Task 2 step 3 (`.onKeyPress(.delete)`) |
| Placeholder rotates while empty + unfocused | Task 2 step 4 |
| TMDB-missing banner stays | Task 5 (kept inside `mainPickerScroll`) |
| Localization | Task 6 |
| Tests: dedupe, sort, cold-start | Task 1 steps 1, 6, 7 |
| Worktree build hygiene | Every build/test step `cd`s in first |

All spec requirements have at least one task. No placeholders. Method names (`suggestedFilters`, `SuggestedFilter`, `activeChips`, `currentPlaceholder`, `moreFiltersExpanded`, `applySuggestion`, `color(for:)`) are consistent across tasks.
