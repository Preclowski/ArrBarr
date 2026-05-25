# Drop Discover Tab — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to execute this plan task-by-task.

**Goal:** Remove the Discover tab from the popover. The Discover view (tinder + matched) becomes a chat-triggered modal overlay.

**Architecture:** `DiscoverTabView` is rendered as a ZStack overlay in `PopoverContentView` (mirrors `SearchAddPanel` pattern). The existing `arrBarrOpenDiscoverInTinder` notification opens the overlay and seeds `moodText`. `FloatingBackButton` inside the overlay calls a passed `onClose` callback to dismiss it. The VM's `DiscoverStage` enum collapses — only the tinder mode survives.

**Spec:** `docs/superpowers/specs/2026-05-26-drop-discover-tab-design.md`

**Branch:** `discover/llm-only-cleanup` (continuation).

---

## Build & test commands

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only/Packages/ArrCore
swift test 2>&1 | grep "Test run with" | tail -1
swift build 2>&1 | tail -3
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -3
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

---

### Task 1: Strip `DiscoverStage` + `userSubmittedMood` from the VM

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift`

- [ ] **Step 1: Remove the stage enum + property**

Open `DiscoverViewModel.swift`. Find:

```swift
    public enum DiscoverStage: Sendable { case picker, tinder }
```

and:

```swift
    @Published public var stage: DiscoverStage = .picker
```

Delete both. The VM no longer has a stage notion.

- [ ] **Step 2: Remove `userSubmittedMood()`**

In the VM, delete:

```swift
    /// Call when the user submits the mood field. Bumps `userActionTick`
    /// so the View's `task(id:)` fires a reshuffle.
    public func userSubmittedMood() {
        userActionTick &+= 1
    }
```

(Exact doc comment may differ — delete the function and its comment.)

- [ ] **Step 3: Verify `mediaSelectionChanged` is still called somewhere**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
grep -rn "mediaSelectionChanged" Packages/ArrCore/Sources/
```

If zero call sites, delete `mediaSelectionChanged()` too. If still called, keep it. (Probably called by a media-kind selector somewhere — if not, drop it.)

- [ ] **Step 4: Update tests**

In `DiscoverViewModelTests.swift`, find every reference to `stage`, `.picker`, `.tinder` (as VM stage values), and `userSubmittedMood`. Delete the lines / tests as needed. Most retained tests don't touch stage — they call `reshuffle()` directly.

- [ ] **Step 5: Build the package**

```bash
cd Packages/ArrCore && swift build 2>&1 | grep -E "^/.*: error:" | awk -F: '{print $1}' | sort -u
```

Expected errors only in: `DiscoverTabView.swift`, `DiscoverPickerView.swift`, `PopoverContentView.swift` (consumers of removed APIs — fixed in later tasks).

- [ ] **Step 6: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
git add Packages/ArrCore/Sources/ArrCore/ViewModels/DiscoverViewModel.swift \
        Packages/ArrCore/Tests/ArrCoreTests/DiscoverViewModelTests.swift
git commit -m "$(cat <<'EOF'
refactor(discover): drop DiscoverStage + userSubmittedMood

VM no longer has a picker/tinder split — tinder is the only mode that
exists in the chat-triggered overlay world.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Simplify `DiscoverTabView` — drop picker case, add `onClose`, freeze chip

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift`

- [ ] **Step 1: Add `onClose` callback prop**

Edit the struct properties:

```swift
public struct DiscoverTabView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let llmAvailable: Bool
    let radarrAvailable: Bool
    let onAddToRadarr: (SearchResult) -> Void
    let onAddToSonarr: (SearchResult) -> Void
    let onOpenDetail: (DiscoverItem, QueueItem.Source, Int) -> Void
    let onClose: () -> Void
    ...
}
```

Update the `init` accordingly — add `onClose: @escaping () -> Void` as a parameter and `self.onClose = onClose`.

- [ ] **Step 2: Collapse `body`**

Replace the current `body` (which switches on `viewModel.stage`) with the tinder mode directly:

```swift
    public var body: some View {
        tinderMode
    }
```

`tinderMode` is the existing private computed view — keep it intact except for the changes in steps 3–5.

- [ ] **Step 3: Rewire the `FloatingBackButton` action**

Inside `tinderTopBar`, find:

```swift
            FloatingBackButton(action: {
                if showMatched {
                    withAnimation(.smooth(duration: 0.22)) { showMatched = false }
                } else {
                    withAnimation(.smooth(duration: 0.22)) { viewModel.stage = .picker }
                }
            })
```

Replace with:

```swift
            FloatingBackButton(action: {
                if showMatched {
                    withAnimation(.smooth(duration: 0.22)) { showMatched = false }
                } else {
                    onClose()
                }
            })
```

(`viewModel.stage = .picker` is dead — there's no picker stage.)

- [ ] **Step 4: Make the summary chip non-tappable, drop the × clear button**

Find `filterSummaryChip`. Replace its body with a read-only chip — no button, no x:

```swift
    private var filterSummaryChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(activeFilterSummary)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }
```

- [ ] **Step 5: Delete `clearAllFilters` (no longer reachable)**

After step 4 nothing calls `clearAllFilters`. Delete the function entirely.

`activeFilterSummary` stays — it's still used by the chip.

- [ ] **Step 6: Build**

```bash
cd Packages/ArrCore && swift build 2>&1 | grep -E "^/.*DiscoverTabView\.swift.*: error:" | head -5
```

Expected: zero errors in `DiscoverTabView.swift` itself. (`PopoverContentView.swift` will still complain — Task 4 fixes the call.)

- [ ] **Step 7: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
git add Packages/ArrCore/Sources/ArrCore/Views/DiscoverTabView.swift
git commit -m "$(cat <<'EOF'
refactor(discover): tinder-only view with onClose callback

Drops the picker/tinder body switch — view is the tinder content
unconditionally. FloatingBackButton calls onClose to dismiss the
overlay. Summary chip is now read-only (no picker to re-open).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Delete `DiscoverPickerView.swift`

**Files:**
- Delete: `Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings` (remove now-dead picker-only keys)

- [ ] **Step 1: Delete the file**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
git rm Packages/ArrCore/Sources/ArrCore/Views/DiscoverPickerView.swift
```

- [ ] **Step 2: Remove the two picker-only localization keys**

Open `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`. Delete the entries for:

- `"What do you feel like watching?"`
- `"Describe a mood, a vibe, a director, anything"`

(Use a json-aware edit — load, drop the keys, dump. Or hand-edit and rely on Xcode normalising later.)

```bash
python3 <<'PY'
import json
PATH = "Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings"
data = json.load(open(PATH))
for k in [
    "What do you feel like watching?",
    "Describe a mood, a vibe, a director, anything",
]:
    data["strings"].pop(k, None)
with open(PATH, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("ok")
PY
```

- [ ] **Step 3: Build (the package still won't link until Task 4)**

```bash
cd Packages/ArrCore && swift build 2>&1 | grep -E "^/.*: error:" | awk -F: '{print $1}' | sort -u
```

Expected: only `PopoverContentView.swift` listed.

- [ ] **Step 4: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
git add -A
git commit -m "$(cat <<'EOF'
chore(discover): delete DiscoverPickerView + its localization keys

Picker is unreachable — chat tool is the only entry point now.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Rewire `PopoverContentView` — drop tab, add overlay

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

This is the largest of the four tasks. Read the file carefully and apply each step.

- [ ] **Step 1: Remove the `.discover` case from `Tab` enum**

Find the `enum Tab` declaration (around line 120). Delete the `.discover = "Discover"` case.

- [ ] **Step 2: Remove the `.discover` branch from `visibleTabs`**

Find `visibleTabs` (around line 540). The current body is:

```swift
    private var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .chat: return chatAvailable
            case .discover: return discoverAvailable
            default:    return true
            }
        }
    }
```

Drop the `.discover` arm. (`discoverAvailable` may now be unreferenced — leave it for the moment; Task 5 prunes it.)

- [ ] **Step 3: Remove the `case .discover:` branch in the main tab switch**

Find the `switch selectedTab` inside the popover body (around line 250). Delete the entire `case .discover: DiscoverTabView(...) ...` branch including its `.onAppear { Task { await configureDiscover() } }` if attached.

- [ ] **Step 4: Add overlay state + render**

Add a state variable near the top of the view's properties:

```swift
    /// True while the chat-triggered Discover overlay is visible. Set by
    /// the `arrBarrOpenDiscoverInTinder` notification handler and cleared
    /// by the overlay's own back-button (`onClose`).
    @State private var showDiscoverOverlay = false
```

Find the location where `SearchAddPanel` is rendered as a `ZStack` overlay (search for `searchAddOverlay` or similar). Add an equivalent overlay for Discover, placed as a sibling in the same ZStack:

```swift
            if showDiscoverOverlay {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: chatAvailable,
                    radarrAvailable: radarrConfigured,
                    onAddToRadarr: openDiscoverAddToRadarr,
                    onAddToSonarr: openDiscoverAddToSonarr,
                    onOpenDetail: { item, source, arrId in
                        // existing detail-open handler — match the previous case .discover branch
                        ...
                    },
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) {
                            showDiscoverOverlay = false
                        }
                    }
                )
                .background(.background)   // opaque so it covers underlying tab
                .transition(.opacity)
            }
```

Use the existing `onOpenDetail` body that was inside the now-deleted `case .discover` branch — copy it over.

- [ ] **Step 5: Rewrite the notification handler**

Find the `.onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDiscoverInTinder))` block. Replace its body with:

```swift
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDiscoverInTinder)) { note in
                guard let mood = note.userInfo?["mood"] as? String,
                      !mood.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                discoverViewModel.moodText = mood
                Task {
                    await configureDiscover()
                    await discoverViewModel.reshuffle()
                }
                withAnimation(.smooth(duration: 0.22)) {
                    showDiscoverOverlay = true
                }
            }
```

(`configureDiscover` must fire before `reshuffle` — sources have to be wired or the fetch will be a no-op.)

- [ ] **Step 6: Drop the now-dead `searchAddFromDiscover` state if no longer referenced**

The flag tracked whether `SearchAddPanel` was opened from Discover (to route Back correctly). The Discover overlay's `onAddToRadarr`/`onAddToSonarr` callbacks still trigger SearchAddPanel — verify the flag's set/reset path still makes sense. If `showDiscoverOverlay` can stay open behind SearchAddPanel and SearchAddPanel's Back returns to the Discover overlay naturally, the flag's logic still applies. KEEP the flag and its usage unless verification proves it dead.

- [ ] **Step 7: Drop the leading `configureDiscover` call**

The original code called `configureDiscover` on appear of the discover tab. With no tab, the call moves into the notification handler (Step 5). Search for other `configureDiscover()` invocations and delete any that referenced the removed tab onAppear.

- [ ] **Step 8: Build the package + app**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only/Packages/ArrCore
swift build 2>&1 | tail -5
cd ../..
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: Build complete + BUILD SUCCEEDED.

- [ ] **Step 9: Run tests**

```bash
cd Packages/ArrCore && swift test 2>&1 | grep "Test run with" | tail -1
```

Expected: 185 tests passed.

- [ ] **Step 10: Commit**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "$(cat <<'EOF'
feat(discover): chat-triggered overlay replaces dedicated tab

Drops Tab.discover. Discover renders as a modal overlay opened by the
arrBarrOpenDiscoverInTinder notification (chat tool). FloatingBackButton
closes the overlay via onClose. configureDiscover fires before
reshuffle so sources are wired in time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Cleanup pass — prune now-dead helpers

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Find dead references**

```bash
cd /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only
grep -nE "discoverAvailable|searchAddFromDiscover|openDiscoverAddToRadarr|openDiscoverAddToSonarr" Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
```

For each match, decide:
- `discoverAvailable`: only valuable if anything still gates on discover availability. If only the visibleTabs use was relevant, the property + its computation can go.
- `searchAddFromDiscover` + its routing checks: keep if SearchAddPanel still routes back to the overlay; otherwise drop.
- `openDiscoverAddToRadarr` / `openDiscoverAddToSonarr`: callbacks now wired to the overlay — KEEP.

Drop only what's confirmed unreferenced.

- [ ] **Step 2: Build + tests**

```bash
cd Packages/ArrCore && swift build && swift test 2>&1 | grep "Test run with" | tail -1
cd ../..
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```

- [ ] **Step 3: Commit (only if anything was deleted)**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "$(cat <<'EOF'
chore(discover): prune now-dead helpers after tab removal

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If nothing was dead, skip the commit entirely.

---

### Task 6: End-to-end smoke

- [ ] **Step 1: Relaunch**

```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open /Users/konrad/Workspace/ai/arrhelper/arrhelper/.worktrees/discover-llm-only/build/Build/Products/Debug/ArrBarr.app
```

- [ ] **Step 2: Manual checklist (user-driven)**

- The popover tab bar shows everything EXCEPT Discover.
- Open Chat. Type something like "find me a cozy 90s comedy" and let the model fire `discover_in_tinder`.
- Discover overlay slides in over chat. Truncated prompt chip visible. Cards appear.
- FloatingBackButton closes overlay → back to chat in the same scroll position.
- "Add to Radarr" / "Add to Sonarr" CTAs open SearchAddPanel as before; Back from SearchAddPanel returns to the Discover overlay (not chat).
- Picks list reachable via 10-pick auto-jump or whatever path remains — verify it still works.

Report any breakage as a bug to fix before declaring done.

---

## Self-review

- [ ] `git grep "Tab.discover\|DiscoverPickerView\|DiscoverStage\|userSubmittedMood\|\.picker\b"` returns zero hits in Packages/ArrCore/Sources.
- [ ] `swift test` green.
- [ ] `xcodebuild build` green.
- [ ] Chat tool path verified live.
