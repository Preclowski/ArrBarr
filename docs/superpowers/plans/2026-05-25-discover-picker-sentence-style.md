# Discover Picker Sentence-Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Refine the composer-first picker so the composer reads like a sentence with category labels and clearly signals natural-language input goes to AI.

**Architecture:** Modify `DiscoverPickerView.swift` body bits. Touch `DiscoverViewModel.swift` to extend `SuggestedFilter.Category` with `.ai` and add `suggestionsByCategory` grouping. Append translations.

**Tech Stack:** SwiftUI, Swift Package Manager, XCTest.

**Worktree:** `/Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab`. ALL `xcodebuild` and `swift test` calls must `cd` into the worktree first.

**Reference spec:** `docs/superpowers/specs/2026-05-25-discover-picker-sentence-style.md`.

---

## Task 1: VM — add `.ai` category + `suggestionsByCategory` grouping

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `DiscoverViewModelTests.swift`:

```swift
func test_suggestionsByCategory_includesAiStarters_whenLLMAvailable() {
    let vm = freshVM()
    let grouped = vm.suggestionsByCategory(llmAvailable: true)
    XCTAssertFalse((grouped[.ai] ?? []).isEmpty,
                   "AI bucket should expose starter prompts when LLM available")
    XCTAssertTrue((grouped[.people] ?? []).contains(where: { $0.id == "person.Quentin Tarantino" }))
}

func test_suggestionsByCategory_excludesAi_whenLLMUnavailable() {
    let vm = freshVM()
    let grouped = vm.suggestionsByCategory(llmAvailable: false)
    XCTAssertNil(grouped[.ai], "AI bucket should be absent without LLM")
}
```

- [ ] **Step 2: Run — confirm failure**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter test_suggestionsByCategory
```

Expected: compile error.

- [ ] **Step 3: Extend `SuggestedFilter.Category` enum**

In `DiscoverViewModel.swift`, find the `SuggestedFilter.Category` enum (around line 8) and add `.ai`:

```swift
public enum Category: String, Sendable {
    case people, genre, decade, rating, runtime, ai
}
```

- [ ] **Step 4: Add `suggestionsByCategory(llmAvailable:)` method**

Just below the existing `suggestedFilters` computed property in `DiscoverViewModel`, add:

```swift
/// Suggestions grouped by category for the per-category mini-row layout.
/// AI bucket holds starter prompts as pseudo-filters — their `label` is
/// the prompt text the View should drop into `moodText`. Omitted when
/// `llmAvailable` is false. Caller iterates a fixed display order.
public func suggestionsByCategory(llmAvailable: Bool)
    -> [SuggestedFilter.Category: [SuggestedFilter]] {
    var out: [SuggestedFilter.Category: [SuggestedFilter]] = [:]
    // Distribute filter suggestions by their category. Cap each bucket
    // at 3 so a single category doesn't dominate the strip.
    for s in suggestedFilters where s.category != .ai {
        var bucket = out[s.category] ?? []
        if bucket.count < 3 { bucket.append(s) }
        out[s.category] = bucket
    }
    if llmAvailable {
        out[.ai] = Self.aiStarterPrompts
    }
    return out
}

/// Curated starter prompts surfaced as the AI suggestion row. Kept
/// short so the row stays visually balanced; the LLM doesn't need many
/// examples to convey "you can write naturally here".
private static let aiStarterPrompts: [SuggestedFilter] = [
    .init(id: "ai.cozy", label: "Cozy Sunday afternoon",
          category: .ai, icon: "sparkles"),
    .init(id: "ai.flight", label: "Long flight",
          category: .ai, icon: "sparkles"),
    .init(id: "ai.date", label: "Date night",
          category: .ai, icon: "sparkles"),
]
```

- [ ] **Step 5: Run tests — should pass**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover 2>&1 | grep "Executed" | tail -2
```

Expected: 42 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift
git commit -m "feat(discover): SuggestedFilter.ai + suggestionsByCategory grouping"
```

---

## Task 2: Composer — category labels + sparkles prefix

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

- [ ] **Step 1: Replace the `chipComposer` body**

Find `private var chipComposer: some View { ... }` and replace its body with:

```swift
private var chipComposer: some View {
    FlowLayout(spacing: 5) {
        kindChip
        composerCategoryGroup(.genre, label: "Gatunek:")
        composerCategoryGroup(.people, label: "Z:")
        composerCategoryGroup(.decade, label: "Z lat:")
        composerCategoryGroup(.rating, label: "Vibe:")
        composerCategoryGroup(.runtime, label: "Długość:")
        Image(systemName: "sparkles")
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(Color.pink.opacity(0.8))
        TextField("", text: $freeText,
                  prompt: Text("…lub opisz słownie", bundle: .module),
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

/// Renders "Label: chip chip chip" for a category, but only when there
/// is at least one active chip of that category. Kept as a single Group
/// so FlowLayout treats it as inline content rather than a separate row.
@ViewBuilder
private func composerCategoryGroup(
    _ category: SuggestedFilter.Category,
    label: LocalizedStringKey
) -> some View {
    let chips = activeChips.filter { $0.category == category }
    if !chips.isEmpty {
        Text(label, bundle: .module)
            .scaledFont(size: 11, weight: .medium)
            .italic()
            .foregroundStyle(.secondary)
        ForEach(chips) { chip in activeChipView(chip) }
    }
}
```

- [ ] **Step 2: Delete obsolete placeholder rotation**

In `DiscoverPickerView.swift`, find and **delete**:

- `@State private var placeholderTick: Int = 0`
- `private static let placeholderRotation: [String] = [ … ]`
- `private var currentPlaceholder: String { … }`

Also delete the `.task { while !Task.isCancelled { … placeholderTick &+= 1 … } }` block from `body`. The body should now be:

```swift
public var body: some View {
    VStack(spacing: 0) {
        mainPickerScroll
        chipComposer
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): composer category labels + sparkles AI prefix"
```

---

## Task 3: Suggestions — per-category mini-rows + AI row

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`

- [ ] **Step 1: Replace `suggestionsRow`**

Find `private var suggestionsRow: some View { ... }` (and its helpers `suggestionPill`, `applySuggestion`). Replace the whole `suggestionsRow` with the split layout:

```swift
private static let suggestionsOrder: [SuggestedFilter.Category] =
    [.people, .genre, .decade, .rating, .runtime, .ai]

private static func suggestionsRowLabel(
    _ category: SuggestedFilter.Category
) -> LocalizedStringKey {
    switch category {
    case .people:  return "Osoby"
    case .genre:   return "Gatunki"
    case .decade:  return "Dekady"
    case .rating:  return "Vibe"
    case .runtime: return "Długość"
    case .ai:      return "AI"
    }
}

@ViewBuilder
private var suggestionsRow: some View {
    let grouped = viewModel.suggestionsByCategory(llmAvailable: llmAvailable)
    VStack(alignment: .leading, spacing: 6) {
        ForEach(Self.suggestionsOrder, id: \.self) { cat in
            let items = grouped[cat] ?? []
            if !items.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    suggestionsRowHeader(cat)
                    FlowLayout(spacing: 5) {
                        ForEach(items) { s in
                            suggestionPill(s)
                        }
                    }
                }
            }
        }
    }
}

@ViewBuilder
private func suggestionsRowHeader(_ category: SuggestedFilter.Category) -> some View {
    HStack(spacing: 3) {
        if category == .ai {
            Image(systemName: "sparkles")
                .scaledFont(size: 8, weight: .semibold)
                .foregroundStyle(.pink)
        }
        Text(Self.suggestionsRowLabel(category), bundle: .module)
            .scaledFont(size: 9, weight: .semibold)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }
    .frame(width: 50, alignment: .leading)
}
```

- [ ] **Step 2: Extend `applySuggestion` for `.ai`**

Find the `applySuggestion(_:)` function. Add the `.ai` case at the top of the switch:

```swift
private func applySuggestion(_ s: SuggestedFilter) {
    switch s.category {
    case .ai:
        // AI starter — drop the prompt into the free-text field and focus.
        // No filter mutation. User can edit before sending.
        freeText = s.label
        freeTextFocused = true
        return
    case .people:
        // …existing code unchanged…
```

Leave the rest of the switch as-is.

- [ ] **Step 3: Update `SuggestionPillButton` color for AI**

Find `private struct SuggestionPillButton: View`. It currently takes a `color` parameter. No change to the struct is needed — the AI pill will already get `.pink` from the existing `color(for:)` if we extend it. Update `Self.color(for:)` to handle `.ai`:

```swift
private static func color(for category: SuggestedFilter.Category) -> Color {
    switch category {
    case .people:  return .teal
    case .genre:   return .blue
    case .decade:  return .orange
    case .rating:  return .green
    case .runtime: return .purple
    case .ai:      return .pink
    }
}
```

- [ ] **Step 4: Build**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run tests**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover 2>&1 | grep "Executed" | tail -2
```

Expected: 42 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
git commit -m "feat(discover): per-category suggestions rows + AI starter row"
```

---

## Task 4: Localization

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`

- [ ] **Step 1: Inject new entries**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
python3 <<'EOF'
import json
from pathlib import Path
p = Path("Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings")
data = json.loads(p.read_text())
entries = [
    ("Gatunek:", "Genre:", "Género:", "Genre :", "Gatunek:"),
    ("Z:",       "Mit:",   "Con:",    "Avec :",  "Z:"),
    ("Z lat:",   "Aus:",   "De:",     "De :",    "Z lat:"),
    ("Vibe:",    "Vibe:",  "Vibe:",   "Vibe :",  "Vibe:"),
    ("Długość:", "Länge:", "Duración:", "Durée :", "Długość:"),
    ("…lub opisz słownie", "…oder beschreiben",
     "…o describe en palabras", "…ou décris", "…lub opisz słownie"),
    ("Osoby",    "Leute",  "Personas",  "Personnes", "Osoby"),
    ("Gatunki",  "Genres", "Géneros",   "Genres",    "Gatunki"),
    ("Dekady",   "Dekaden","Décadas",   "Décennies", "Dekady"),
    ("Długość",  "Länge",  "Duración",  "Durée",     "Długość"),
    ("AI",       "KI",     "IA",        "IA",        "AI"),
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
print("Added:", len(added))
EOF
```

- [ ] **Step 2: Build**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
git add Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings
git commit -m "i18n(discover): translations for sentence-style picker labels"
```

---

## Task 5: Final build + relaunch + eyes-on

- [ ] **Step 1: Build + relaunch**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | tail -3
pkill -x ArrBarr 2>/dev/null; sleep 0.5
open build/Build/Products/Debug/ArrBarr.app
stat -f "%Sm" -t "%H:%M:%S" build/Build/Products/Debug/ArrBarr.app/Contents/MacOS/ArrBarr
```

Expected: fresh timestamp.

- [ ] **Step 2: Eyes-on checklist**

- Empty picker → composer shows just `🎞 Movies` chip + ✨ + placeholder "…lub opisz słownie" + dim ↑.
- Below: Suggestions split into per-category rows ("Osoby", "Gatunki", "Dekady", … and "AI" with sparkles).
- Tap a person pill → chip appears with "Z:" label before it.
- Tap a genre pill → "Gatunek:" label appears, chip beside it.
- Tap "AI" pill → free-text fills with that prompt, focus jumps to composer; no chip added.
- Backspace on empty text removes last chip.
- Send button activates when any chip or text present.

- [ ] **Step 3: Final test sweep**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.claude/worktrees/discover-tab
swift test --package-path Packages/ArrCore --filter Discover 2>&1 | grep "Executed" | tail -2
```

Expected: 42 tests, 0 failures.

---

## Spec coverage

| Spec section | Task |
|---|---|
| Composer with category labels | Task 2 |
| Sparkles always-visible prefix | Task 2 |
| Placeholder changes / no rotation | Task 2 |
| Suggestions per-category mini-rows | Task 3 |
| AI row with starters | Task 3 |
| Tap AI pill → fills free-text + focuses | Task 3 |
| `SuggestedFilter.Category.ai` | Task 1 |
| `suggestionsByCategory(llmAvailable:)` | Task 1 |
| Localization (Gatunek/Z/Osoby/etc.) | Task 4 |

No placeholders. Method/state names consistent across tasks. Each task ends with a self-contained commit.
