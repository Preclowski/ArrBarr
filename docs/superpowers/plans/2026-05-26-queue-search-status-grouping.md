# Queue Search Status-Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pivot the queue tab's search results from source-grouped to status-grouped (IN QUEUE / IN LIBRARY / NEW), with the source axis demoted to a row-level glyph, and a single appearance per title.

**Architecture:** Two pure helpers (status label formatter, queue-vs-library de-dup) + one new compact view (`QueueSearchRow`) + targeted edits to `SearchResultRow` (badge → source glyph) and `PopoverContentView` (collapse `queueBody` from 3 modes to 2, make `typeGroupedSections` scope-agnostic). Helpers ship with unit tests; the view changes are verified manually in the running app.

**Tech Stack:** Swift 5.x, SwiftUI, Swift Testing (`import Testing`), Swift Package Manager (`Packages/ArrCore`), Xcode project at `ArrBarr.xcodeproj`.

**Spec:** [docs/superpowers/specs/2026-05-26-queue-search-status-grouping-design.md](../specs/2026-05-26-queue-search-status-grouping-design.md)

---

## File Structure

**New files:**
- `Packages/ArrCore/Sources/ArrCore/Models/QueueSearchStatusLabel.swift` — pure function turning a `QueueItem` into a compact trailing label (`"62% · 12 min"`, `"queued"`, `"paused"`, …). Lives in Models because it's a stateless formatter with no SwiftUI dependency.
- `Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift` — pure function removing library hits that already appear as active queue rows. Same package layer as the status-label helper.
- `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchRow.swift` — compact queue row used inside the IN QUEUE search section. Wraps `PosterMetadataRow` to match library/new row chrome.
- `Packages/ArrCore/Tests/ArrCoreTests/QueueSearchStatusLabelTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift`

**Modified files:**
- `Packages/ArrCore/Sources/ArrCore/Views/SearchResultRow.swift` — title badge slot swaps from `InLibraryBadge`/`NewBadge` to a source-glyph chip.
- `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` — `queueBody` collapses to two render paths, `typeGroupedSections` becomes scope-agnostic, de-dup applied, IN QUEUE renders `QueueSearchRow`.

**Out of scope:**
- `QueueRowView` is untouched — it remains the full-fat default queue view component. The compact row is a new sibling, not a mode flag, because the two have different responsibilities (management vs scanning) and different action surfaces.
- Other surfaces that use `InLibraryBadge` (e.g. `UpcomingRowView`) are not touched — only `SearchResultRow`'s slot changes.

---

## Task 1: Status label helper

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/QueueSearchStatusLabel.swift`
- Create: `Packages/ArrCore/Tests/ArrCoreTests/QueueSearchStatusLabelTests.swift`

The function returns a short trailing label for the IN QUEUE compact row.

Rules:
- `status == .downloading` and `progress > 0`: `"<int>% · <timeLeft>"` if `timeLeft` is non-nil and non-empty, otherwise just `"<int>%"`. `progress` is a 0…1 fraction; round to integer percent.
- `status == .downloading` and `progress == 0`: `"downloading"`.
- `status == .queued`: `"queued"`.
- `status == .paused`: `"paused"`.
- `status == .importing`: `"importing"`.
- `status == .completed`: `"completed"`.
- `status == .warning`: `"warning"`.
- `status == .failed`: `"failed"`.
- `status == .unknown`: `"queued"` (safest fallback — a row with no known state reads as waiting).

Returns a plain `String`, not a `LocalizedStringKey`. Localization happens at the call site by wrapping in `Text(_:bundle:)`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/ArrCore/Tests/ArrCoreTests/QueueSearchStatusLabelTests.swift`:

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("QueueSearchStatusLabel")
struct QueueSearchStatusLabelTests {
    private func item(status: QueueItem.Status, progress: Double, timeLeft: String?) -> QueueItem {
        QueueItem(
            id: "x", source: .radarr, arrQueueId: 1, downloadId: nil,
            downloadProtocol: .unknown, downloadClient: nil, indexer: nil,
            title: "t", subtitle: nil,
            seasonNumber: nil, episodeNumber: nil, episodeTitle: nil,
            releaseName: nil,
            status: status, progress: progress, sizeTotal: 0,
            sizeLeft: 0, timeLeft: timeLeft
        )
    }

    @Test("Downloading with progress and timeLeft renders percent + ETA")
    func downloadingWithEta() {
        let it = item(status: .downloading, progress: 0.624, timeLeft: "12 min")
        #expect(QueueSearchStatusLabel.label(for: it) == "62% · 12 min")
    }

    @Test("Downloading with progress but no timeLeft renders percent only")
    func downloadingNoEta() {
        let it = item(status: .downloading, progress: 0.05, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "5%")
    }

    @Test("Downloading with empty timeLeft string renders percent only")
    func downloadingEmptyEta() {
        let it = item(status: .downloading, progress: 0.5, timeLeft: "")
        #expect(QueueSearchStatusLabel.label(for: it) == "50%")
    }

    @Test("Downloading with zero progress renders 'downloading'")
    func downloadingZeroProgress() {
        let it = item(status: .downloading, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "downloading")
    }

    @Test("Queued renders 'queued'")
    func queued() {
        let it = item(status: .queued, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "queued")
    }

    @Test("Paused renders 'paused'")
    func paused() {
        let it = item(status: .paused, progress: 0.42, timeLeft: "1 hr")
        #expect(QueueSearchStatusLabel.label(for: it) == "paused")
    }

    @Test("Importing renders 'importing'")
    func importing() {
        let it = item(status: .importing, progress: 1.0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "importing")
    }

    @Test("Completed renders 'completed'")
    func completed() {
        let it = item(status: .completed, progress: 1.0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "completed")
    }

    @Test("Warning renders 'warning'")
    func warning() {
        let it = item(status: .warning, progress: 0.3, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "warning")
    }

    @Test("Failed renders 'failed'")
    func failed() {
        let it = item(status: .failed, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "failed")
    }

    @Test("Unknown falls back to 'queued'")
    func unknownFallback() {
        let it = item(status: .unknown, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "queued")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd Packages/ArrCore && swift test --filter QueueSearchStatusLabel
```
Expected: compile failure ("cannot find 'QueueSearchStatusLabel' in scope").

- [ ] **Step 3: Implement the helper**

Create `Packages/ArrCore/Sources/ArrCore/Models/QueueSearchStatusLabel.swift`:

```swift
import Foundation

/// Compact trailing label for the IN QUEUE row in the queue-search
/// status-grouped layout. Short on purpose — sits next to a 26×38
/// poster + title and shares the row with library/new rows that show
/// chevrons / plus glyphs. Returns a plain `String`; callers wrap it
/// in `Text(_:bundle:)` for localization.
public enum QueueSearchStatusLabel {
    public static func label(for item: QueueItem) -> String {
        switch item.status {
        case .downloading:
            if item.progress > 0 {
                let pct = Int((item.progress * 100).rounded())
                if let eta = item.timeLeft, !eta.isEmpty {
                    return "\(pct)% · \(eta)"
                }
                return "\(pct)%"
            }
            return "downloading"
        case .queued:     return "queued"
        case .paused:     return "paused"
        case .importing:  return "importing"
        case .completed:  return "completed"
        case .warning:    return "warning"
        case .failed:     return "failed"
        case .unknown:    return "queued"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd Packages/ArrCore && swift test --filter QueueSearchStatusLabel
```
Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/QueueSearchStatusLabel.swift Packages/ArrCore/Tests/ArrCoreTests/QueueSearchStatusLabelTests.swift
git commit -m "$(cat <<'EOF'
feat(queue-search): compact status label helper

Pure formatter turning a QueueItem into a short trailing label
("62% · 12 min", "queued", "paused", …) for the compact IN QUEUE
row used during search.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Search-result de-duplication helper

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift`
- Create: `Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift`

Pure function `SearchResultDedup.removingQueueDuplicates(libraryResults:queueRows:)` that takes the library-hit list for a source and the queue rows that will appear in IN QUEUE for the same source, and returns the library list with any entry whose `inLibraryArrId` matches a queue item's `entityId` removed.

Matching rule: `result.inLibraryArrId == queueItem.entityId` AND both non-nil. Source matching is implicit — callers pass already-source-scoped lists.

Queue rows are `[QueueRowEntry]` (mixture of `.single` and `.group`); the helper flattens groups so any member entity match counts.

- [ ] **Step 1: Write the failing tests**

Create `Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift`:

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("SearchResultDedup")
struct SearchResultDedupTests {
    private func result(id: String, inLibraryArrId: Int?) -> SearchResult {
        SearchResult(
            id: id, title: id, year: nil, subtitle: nil,
            overview: nil, posterURL: nil, source: .radarr,
            inLibraryArrId: inLibraryArrId
        )
    }

    private func queueItem(entityId: Int?) -> QueueItem {
        QueueItem(
            id: "q\(entityId ?? -1)", source: .radarr, arrQueueId: 1, downloadId: nil,
            downloadProtocol: .unknown, downloadClient: nil, indexer: nil,
            title: "t", subtitle: nil,
            seasonNumber: nil, episodeNumber: nil, episodeTitle: nil,
            releaseName: nil,
            status: .downloading, progress: 0.5, sizeTotal: 0,
            sizeLeft: 0, timeLeft: nil,
            entityId: entityId
        )
    }

    @Test("Result whose inLibraryArrId matches a singleton queue entityId is removed")
    func removesMatchingSingleton() {
        let lib = [result(id: "a", inLibraryArrId: 42), result(id: "b", inLibraryArrId: 99)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 42))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.id) == ["b"])
    }

    @Test("Result matching any member of a group is removed")
    func removesMatchingGroupMember() {
        let lib = [result(id: "a", inLibraryArrId: 7)]
        let group = QueueGroup(id: "g", items: [queueItem(entityId: 5), queueItem(entityId: 7)])
        let queue: [QueueRowEntry] = [.group(group)]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.isEmpty)
    }

    @Test("Results with nil inLibraryArrId are never removed")
    func keepsNilLibraryId() {
        let lib = [result(id: "a", inLibraryArrId: nil)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 42))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.id) == ["a"])
    }

    @Test("Queue items with nil entityId never match")
    func nilEntityIdsDontMatch() {
        let lib = [result(id: "a", inLibraryArrId: 42)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: nil))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.id) == ["a"])
    }

    @Test("Empty queue passes library through unchanged")
    func emptyQueue() {
        let lib = [result(id: "a", inLibraryArrId: 42), result(id: "b", inLibraryArrId: 99)]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: [])
        #expect(out.map(\.id) == ["a", "b"])
    }

    @Test("Preserves order of surviving results")
    func preservesOrder() {
        let lib = [
            result(id: "a", inLibraryArrId: 1),
            result(id: "b", inLibraryArrId: 2),
            result(id: "c", inLibraryArrId: 3),
        ]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 2))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.id) == ["a", "c"])
    }
}
```

Note: `SearchResult.init` and `QueueGroup` are internal-ish. Check `SearchTypes.swift` and `QueueGroup.swift` for the current signatures — adjust the helper test builders to match what compiles. The exact field set of `SearchResult.init` is shown at `Packages/ArrCore/Sources/ArrCore/Models/SearchTypes.swift:44-46`; replicate just enough fields to construct one.

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd Packages/ArrCore && swift test --filter SearchResultDedup
```
Expected: compile failure ("cannot find 'SearchResultDedup' in scope").

- [ ] **Step 3: Implement the helper**

Create `Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift`:

```swift
import Foundation

/// De-duplication between the IN QUEUE and IN LIBRARY sections of
/// the status-grouped queue-search layout. A title that's actively
/// downloading is technically also in the library — surfacing it
/// twice (once per section) is the kind of double-encoding the
/// design explicitly avoids. Queue wins; library hit drops.
///
/// Callers pass single-source lists; matching is by `entityId` ↔
/// `inLibraryArrId`, source is implicit.
public enum SearchResultDedup {
    public static func removingQueueDuplicates(
        libraryResults: [SearchResult],
        queueRows: [QueueRowEntry]
    ) -> [SearchResult] {
        let queueEntityIds: Set<Int> = queueRows.reduce(into: Set<Int>()) { acc, entry in
            switch entry {
            case .single(let item):
                if let id = item.entityId { acc.insert(id) }
            case .group(let g):
                for item in g.items {
                    if let id = item.entityId { acc.insert(id) }
                }
            }
        }
        return libraryResults.filter { result in
            guard let id = result.inLibraryArrId else { return true }
            return !queueEntityIds.contains(id)
        }
    }
}
```

If `QueueGroup.items` is not accessible from this file (it's declared `let items: [QueueItem]` without an explicit access modifier — defaults to internal, same package, fine), no extra exposure is needed. If the compiler complains, promote `items` to `public` in `Packages/ArrCore/Sources/ArrCore/Models/QueueGroup.swift`.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd Packages/ArrCore && swift test --filter SearchResultDedup
```
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/SearchResultDedup.swift Packages/ArrCore/Tests/ArrCoreTests/SearchResultDedupTests.swift
git commit -m "$(cat <<'EOF'
feat(queue-search): queue↔library de-dup helper

Removes library hits that already appear as active queue rows so
the upcoming status-grouped layout doesn't surface the same title
in both IN QUEUE and IN LIBRARY.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `QueueSearchRow` compact view

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchRow.swift`

A compact row matching the visual rhythm of `SearchResultRow`. Wraps `PosterMetadataRow` directly (the same primitive `SearchResultRow` uses). Trailing slot renders the status label from Task 1.

Behaviour:
- Plakat 26×38 (or blurred per `configStore.shouldBlurPoster(for:)`).
- Title from `item.title`, year unused (queue items don't carry one — title already includes any year string).
- Metadata segments: `item.subtitle` if present, plus `item.releaseName` truncated. Same shape as `SearchResultRow.metadataSegments` but only what the queue item has.
- Title badge slot: source glyph chip — small `Image(systemName: item.source.symbol)` with `.foregroundStyle(.secondary)` inside a capsule, same chrome as `InLibraryBadge` (capsule + opacity background) but icon-only. Implementation reused as the same chip introduced in Task 4.
- Trailing affordance: `Text(QueueSearchStatusLabel.label(for: item))` styled with `scaledFont(size: 11, weight: .medium)`, `.foregroundStyle(.secondary)`.
- Tap action: invokes the passed-in `onShowDetail` closure.

- [ ] **Step 1: Add the source-glyph chip primitive**

Edit `Packages/ArrCore/Sources/ArrCore/Views/Chips.swift`. After the `NewBadge` struct (line ~43), add:

```swift
/// Source identity chip — small capsule wrapping the arr's SF Symbol
/// (`film` / `tv` / `music.note` / `flame`). Used as the title-slot
/// badge inside the queue-search status-grouped layout, replacing
/// `InLibraryBadge` / `NewBadge` whose meaning is now encoded by the
/// section header instead.
public struct SourceGlyphChip: View {
    let source: QueueItem.Source
    public init(source: QueueItem.Source) {
        self.source = source
    }
    public var body: some View {
        Image(systemName: source.symbol)
            .scaledFont(size: 9, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}
```

- [ ] **Step 2: Create `QueueSearchRow.swift`**

Create `Packages/ArrCore/Sources/ArrCore/Views/QueueSearchRow.swift`:

```swift
import SwiftUI

/// Compact queue-row used in the IN QUEUE section of the queue tab's
/// status-grouped search layout. Shares row chrome with
/// `SearchResultRow` so library / new / queue rows scan as one list
/// rhythm during search. Drills into `DetailView` on tap — pause /
/// resume / delete live there. The full-fat `QueueRowView` (progress
/// bar + inline actions) is still used in the empty-filter default
/// view.
public struct QueueSearchRow: View {
    let item: QueueItem
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    public init(item: QueueItem, onTap: @escaping () -> Void) {
        self.item = item
        self.onTap = onTap
    }

    public var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            title: item.title,
            metadataSegments: metadataSegments,
            titleBadge: AnyView(SourceGlyphChip(source: item.source)),
            onTap: onTap
        ) {
            Text(QueueSearchStatusLabel.label(for: item))
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    private var metadataSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            item.releaseName.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}
```

Cross-check before compiling: `PosterMetadataRow`'s parameter list. Open `Packages/ArrCore/Sources/ArrCore/Views/PosterMetadataRow.swift` and verify the labels match (`posterURL`, `posterAPIKey`, `posterSize`, `posterBlurred`, `title`, `metadataSegments`, `titleBadge`, `onTap`, trailing closure). Adjust to whatever signature compiles; `SearchResultRow.swift` line 27 shows a working call site as ground truth.

Also verify `QueueItem` exposes `posterURL: URL?` — confirmed via `Packages/ArrCore/Sources/ArrCore/Models/QueueItem.swift`. The poster doesn't require auth for queue items in this row (we pass `nil` for `posterAPIKey`).

- [ ] **Step 3: Build the package to check the view compiles**

Run:
```bash
cd Packages/ArrCore && swift build
```
Expected: build succeeds. If `PosterMetadataRow` argument labels differ from what's in the snippet, adjust to match.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/Chips.swift Packages/ArrCore/Sources/ArrCore/Views/QueueSearchRow.swift
git commit -m "$(cat <<'EOF'
feat(queue-search): SourceGlyphChip + QueueSearchRow

Adds the source-identity title-badge chip and a compact queue row
that wraps PosterMetadataRow, matching the library/new row rhythm.
Used by the upcoming status-grouped queue-search layout; the
full-fat QueueRowView still drives the default queue view.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `SearchResultRow` title-badge → source glyph

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/SearchResultRow.swift:34-40`

Replace the `InLibraryBadge` / `NewBadge` swap in the title-badge slot with the new `SourceGlyphChip`. The `isInLibrary` computed property and trailing-affordance branch (chevron for in-library, plus for new) stay — those are unrelated to the title badge.

- [ ] **Step 1: Edit the titleBadge argument**

Open `Packages/ArrCore/Sources/ArrCore/Views/SearchResultRow.swift`. Find lines 34-40:

```swift
            // Every search result now carries a typed badge — library
            // hits show the existing `InLibraryBadge`, fresh
            // candidates a green `New` chip. Gives the user a quick
            // "do I already own this?" read without scanning the
            // trailing chevron column.
            titleBadge: AnyView(isInLibrary ? AnyView(InLibraryBadge()) : AnyView(NewBadge())),
```

Replace with:

```swift
            // Source identity lives in the title slot now — the
            // queue-search status-grouped layout puts library/new
            // status in the section header above each block, so the
            // per-row badge becomes a tautology. The arr glyph here
            // is what carries cross-source distinction inside a
            // section.
            titleBadge: AnyView(SourceGlyphChip(source: result.source)),
```

- [ ] **Step 2: Remove the now-unused `inLibraryBadge` helper**

Lines 80-83 of the same file define an unused passthrough:

```swift
    /// See `InLibraryBadge` for the shared visual — this row just
    /// hands it through so the trailing affordance has a stable name.
    private var inLibraryBadge: some View {
        InLibraryBadge()
    }
```

Delete those four lines.

- [ ] **Step 3: Build and verify the project compiles**

Run:
```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/SearchResultRow.swift
git commit -m "$(cat <<'EOF'
feat(queue-search): swap SearchResultRow title badge to source glyph

Library/new status now lives in the section header above each
block, so the per-row InLibraryBadge / NewBadge is redundant.
Title slot carries the arr glyph instead — the new cross-source
distinction within a status section.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Collapse `queueBody` to two render modes

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift:784-873`

Three structural changes:

1. **`queueBody` collapses from 3 branches to 2.** Empty filter → existing `queueSections` (untouched). Non-empty filter → `typeGroupedSections(for:)` extended to handle `queueScope == nil`. Drops the `queueSearchResults` block entirely.

2. **`typeGroupedSections` becomes scope-agnostic.** When `queueScope == nil`, it iterates every configured source and concatenates IN QUEUE rows from all of them, then IN LIBRARY (de-duplicated), then NEW. When a scope is set, it pulls from that one source (today's behaviour). The single function handles both — no separate code path.

3. **IN QUEUE rows render via `QueueSearchRow`, not `QueueRowView`.** The new `queueRowsList` in this function emits compact rows.

- [ ] **Step 1: Replace `queueBody`**

Find the `queueBody` definition (around line 793-813):

```swift
    @ViewBuilder
    private var queueBody: some View {
        if queueScope == nil {
            // Mode 1 — source-grouped (default).
            if queueResultType == .all || queueResultType == .inQueue {
                queueSections
            }
            if isFiltering, searchAvailable,
               queueResultType == .all
                || queueResultType == .inLibrary
                || queueResultType == .new {
                queueSearchResults
                    .padding(.top, 8)
            }
        } else if let scope = queueScope, queueResultType == .all {
            // Mode 2 — type-grouped for the single picked source.
            typeGroupedSections(for: scope)
        } else if let scope = queueScope {
            // Mode 3 — flat list for picked source + picked type.
            flatList(for: scope)
        }
```

Replace the entire `if queueScope == nil { … } else if … else if … }` chain with:

```swift
    @ViewBuilder
    private var queueBody: some View {
        if !isFiltering {
            // Default surface — per-arr queue sections, tonight /
            // needsYou banners. No search axis to encode yet.
            queueSections
        } else if queueResultType == .all {
            // Status-grouped — IN QUEUE / IN LIBRARY / NEW headers
            // are the only grouping level. Source axis demoted to
            // the row's source-glyph chip. Works the same whether
            // queueScope is nil (all configured arrs) or a single
            // arr (scope chips above already labelled it).
            statusGroupedSections
        } else if let scope = queueScope {
            // User narrowed to one kind via the type pill — flat
            // list, no header (redundant with the pill).
            flatList(for: scope)
        } else {
            // queueScope == nil, type pill narrowed to one kind —
            // flat list across all configured arrs.
            flatListAcrossSources
        }
```

Keep the loading spinner block at the bottom of `queueBody` (lines 819-829) untouched.

- [ ] **Step 2: Add `statusGroupedSections` and `flatListAcrossSources`**

In the same file, right after `queueBody`'s closing brace, replace the existing `typeGroupedSections(for:)` and `flatList(for:)` with this expanded set:

```swift
    /// IN QUEUE / IN LIBRARY / NEW renderer. Source-scope-agnostic
    /// — pulls from `scopedSources` (single arr if `queueScope` set,
    /// every configured arr otherwise). De-duplicates library hits
    /// against rows that already appear in IN QUEUE.
    @ViewBuilder
    private var statusGroupedSections: some View {
        let queueRows: [QueueRowEntry] = scopedSources.flatMap { entries(for: $0) }
        let rawLibrary: [SearchResult] = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingQueueDuplicates(
            libraryResults: rawLibrary,
            queueRows: queueRows
        )
        let newOnes: [SearchResult] = scopedSources.flatMap { newResults(for: $0) }

        VStack(alignment: .leading, spacing: 0) {
            if !queueRows.isEmpty {
                typeSectionHeader(.inQueue, count: queueRows.reduce(0) { sum, e in
                    switch e {
                    case .single: return sum + 1
                    case .group(let g): return sum + g.memberCount
                    }
                })
                compactQueueRowsList(entries: queueRows)
            }
            if !library.isEmpty {
                typeSectionHeader(.inLibrary, count: library.count)
                ForEach(library) { r in searchResultRow(r) }
            }
            if !newOnes.isEmpty {
                typeSectionHeader(.new, count: newOnes.count)
                ForEach(newOnes) { r in searchResultRow(r) }
            }
        }
    }

    /// Flat list when the type pill narrows to a single kind and the
    /// scope is all configured arrs.
    @ViewBuilder
    private var flatListAcrossSources: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch queueResultType {
            case .inQueue:
                compactQueueRowsList(entries: scopedSources.flatMap { entries(for: $0) })
            case .inLibrary:
                let queueRows = scopedSources.flatMap { entries(for: $0) }
                let raw = scopedSources.flatMap { libraryResults(for: $0) }
                let lib = SearchResultDedup.removingQueueDuplicates(
                    libraryResults: raw, queueRows: queueRows
                )
                ForEach(lib) { r in searchResultRow(r) }
            case .new:
                ForEach(scopedSources.flatMap { newResults(for: $0) }) { r in searchResultRow(r) }
            case .all:
                EmptyView()
            }
        }
    }

    /// Single-source flat list — used when the user picked a scope
    /// AND a narrowed type. IN QUEUE rows use the new compact row
    /// for chrome consistency with library/new.
    @ViewBuilder
    private func flatList(for source: QueueItem.Source) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch queueResultType {
            case .inQueue:
                compactQueueRowsList(entries: entries(for: source))
            case .inLibrary:
                let queueRows = entries(for: source)
                let lib = SearchResultDedup.removingQueueDuplicates(
                    libraryResults: libraryResults(for: source),
                    queueRows: queueRows
                )
                ForEach(lib) { r in searchResultRow(r) }
            case .new:
                ForEach(newResults(for: source)) { r in searchResultRow(r) }
            case .all:
                EmptyView()
            }
        }
    }

    /// Compact-row variant of `queueRowsList` — emits `QueueSearchRow`
    /// instead of `QueueRowView`. Used wherever queue rows show up
    /// inside a search-driven layout.
    @ViewBuilder
    private func compactQueueRowsList(entries: [QueueRowEntry]) -> some View {
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                switch entry {
                case .single(let item):
                    QueueSearchRow(item: item) { detailItem = item }
                case .group(let group):
                    QueueSearchRow(item: group.representative) { detailItem = group.representative }
                }
            }
        }
    }
```

The old `typeGroupedSections(for:)` is removed entirely (its single-source behaviour now lives inside `statusGroupedSections` via `scopedSources` returning `[scope]`). Confirm by searching the file for `typeGroupedSections` after the edit — there should be zero remaining references.

- [ ] **Step 3: Remove now-unused `queueSearchResults`**

Search the file for `private var queueSearchResults`. If it exists as a separate `@ViewBuilder` property (it was referenced by the deleted Mode 1 branch), delete its definition. If grep returns no other references after the edit, it's dead code:

```bash
grep -n "queueSearchResults" Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
```
Expected after edit: zero matches.

If matches remain (the definition wasn't removed), find the `private var queueSearchResults: some View { … }` block and delete it.

- [ ] **Step 4: Build and verify it compiles**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```
Expected: build succeeds. Fix any compile errors (likely candidates: stale references to `typeGroupedSections` or `queueSearchResults`, missing `import` for the new helper types — both are in the same package so no import needed).

- [ ] **Step 5: Run the full test suite to catch regressions**

```bash
cd Packages/ArrCore && swift test
```
Expected: all tests pass. The pre-existing `SectionsTests` / `QueueGroupingTests` exercise unrelated logic; nothing here should break them.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "$(cat <<'EOF'
feat(queue-search): status-grouped search results

Collapses queueBody from three render modes to two: empty filter
keeps the per-arr queue sections; any filter pivots to IN QUEUE /
IN LIBRARY / NEW with source demoted to a row-level glyph. Same
layout for all-arrs scope and single-arr scope — scopedSources
drives both. Library hits that already appear in IN QUEUE are
de-duplicated. IN QUEUE rows use the new compact QueueSearchRow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Manual verification

**Files:** none (no code changes).

Verify the change in the running app per CLAUDE.md ("After every code change: rebuild, then kill and relaunch the app").

- [ ] **Step 1: Rebuild and relaunch**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build && pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```
Expected: app launches without crashing. Click the menu-bar icon, the popover opens on the Queue tab.

- [ ] **Step 2: Verify empty-filter default view is unchanged**

Open the popover with an empty search bar. Confirm:
- Per-arr queue sections render with their headers ("Movies", "Series", …) and full `QueueRowView` rows (progress bars, pause/delete inline).
- Tonight / needsYou / "Next week" banner visible if populated.
- No status section headers (`IN QUEUE`, `IN LIBRARY`, `NEW`) anywhere.

- [ ] **Step 3: Verify status-grouped layout when filtering**

Type a query that matches both an active download and a library item. Confirm:
- Three section headers (IN QUEUE / IN LIBRARY / NEW) in that order, with non-zero matches in at least one section.
- Empty sections (e.g. zero NEW hits) are hidden — no `(0)` headers.
- No per-arr sub-headers inside any section.
- Tonight / needsYou / Next-week banner hidden.

- [ ] **Step 4: Verify row chrome**

In the same filtered state:
- IN QUEUE rows are compact (no full-width progress bar). Trailing label reads e.g. `"62% · 12 min"`, `"queued"`, or `"paused"`.
- IN LIBRARY rows have a chevron `›` trailing.
- NEW rows have a `+` trailing.
- Each row carries a source-glyph chip in the title slot (film / tv / music.note / flame) — no green "New" pill, no accent "In library" pill.
- Tap on an IN QUEUE row opens DetailView.

- [ ] **Step 5: Verify de-duplication**

If you have an active download (e.g. "Matrix Reloaded" downloading in Radarr), confirm that typing "matrix" surfaces it once in IN QUEUE only — not also in IN LIBRARY. If no active downloads, skip this step and note in commit message.

- [ ] **Step 6: Verify scope chips and type pill still work**

- Click the Radarr scope chip → IN QUEUE / IN LIBRARY / NEW now show only Radarr rows. Source glyphs all film.
- Click the type pill → pick "New" → only the NEW list renders, flat, no header.
- Clear the search → snap back to default view; type pill resets to All (existing behaviour from `onChange(of: queueFilter)`).

- [ ] **Step 7: Final commit (verification log)**

If any step revealed an issue, fix it inline before this step. Once all steps pass:

```bash
git commit --allow-empty -m "$(cat <<'EOF'
chore(queue-search): manual verification of status-grouped layout

Verified in running app: empty filter unchanged, filter triggers
status-grouped layout, de-dup works, scope + type pill still
narrow correctly, row chrome matches design.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

Coverage:
- "Status as headers, source as row-level glyph" → Tasks 3, 4 (SourceGlyphChip on every row), Task 5 (status section headers).
- "Empty filter = default view" → Task 5, `queueBody` first branch.
- "Three sections, fixed order, empty sections hidden" → Task 5, `statusGroupedSections` (each block guarded on `!isEmpty`).
- "Compact queue row with trailing label" → Tasks 1 (label formatter), 3 (`QueueSearchRow`).
- "De-dup queue ↔ library" → Tasks 2 (helper), 5 (applied in both status-grouped and `inLibrary` flat-list branches).
- "Removal of InLibraryBadge / NewBadge from row" → Task 4.
- "Scope chips and type pill stay" → Task 5 preserves them (untouched in this plan; the existing UI rows above `queueBody` aren't edited).
- "Tonight / needsYou hidden during filter" → already current behaviour; not regressed because empty-filter branch is unchanged and filter branches don't render `queueSections`.
- "Cmd+N focuses search bar; cmd+, opens settings" → untouched (lines 138-150 not edited).

Placeholder scan: no TBDs, no "implement later", no "handle edge cases" — all branches have explicit code. Every test case ships actual assertions.

Type consistency: `QueueSearchStatusLabel.label(for:)`, `SearchResultDedup.removingQueueDuplicates(libraryResults:queueRows:)`, `SourceGlyphChip(source:)`, `QueueSearchRow(item:onTap:)` — names match between definition tasks and consumer tasks.
