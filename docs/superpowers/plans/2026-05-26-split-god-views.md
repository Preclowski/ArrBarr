# Split God-Views Implementation Plan

**Goal:** Break `PopoverContentView` (1449 lines) and `DetailView` (1181 lines) into focused per-surface files. No behavioural changes — pure structural diff. All comments preserved verbatim.

**Architecture:**
- `PopoverContentView` stays the orchestrator: state ownership, overlay management, tab bar / kebab chrome, environment injection. Per-tab bodies move out into `QueueTabContent`, `UpcomingTabContent`, `ChatTabContent` structs that receive state via `@Binding` / value params.
- `DetailView` stays the orchestrator: data loading, header, CTA strip, overlays. Per-source bodies move out into `RadarrDetailPanel`, `SonarrDetailPanel`, `LidarrDetailPanel`.
- No new `ObservableObject` — passing bindings keeps the diff minimal and the data flow visible. The state stays on the orchestrator structs exactly where it is now; only the rendering moves.

**Tech Stack:** Swift / SwiftUI / Swift Package Manager. macOS 26 target.

**Verification rule:** No tests in this codebase — verification is `xcodebuild` clean build + manual click-through of Queue / Upcoming / Chat tabs and at least one Radarr movie + one Sonarr series + one Lidarr album detail screen.

---

## Target 1: PopoverContentView

### File structure after split

- `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift` — orchestrator (state, mainContent ZStack with overlays, tab bar, moreMenu, TabPillBackground, GlassButtonStyle, GlassProminentButtonStyle, Tab enum, empty state).
- `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/QueueTabContent.swift` — queue tab body. Owns: queueContent, queueBody, all status-grouping variants, queueFilterBar, scopeChipsRow, typeFilterPill, InlineFilterPill, sectionView, tonightBanner (it logically belongs to the queue surface), `SectionEntry` enum, `QueueResultType` enum, `matchesFilter`, `entries(for:)`, `isConfigured`, `health(for:)`, `filteredQueueItems`, `libraryResults`, `newResults`, `rawSearchResults`, `count(for:)`, `searchResultRow`, `compactQueueRowsList`, `filterChip`, `tonightTimeFormatter`, `openUpcomingDetail`, `scheduleBannerCollapse`.
- `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/UpcomingTabContent.swift` — upcoming tab body + `UpcomingGroup`.
- `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/ChatTabContent.swift` — chat tab body.

### Task 1: Create the PopoverTabs directory + extract ChatTabContent (smallest, safest first)

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/ChatTabContent.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Create ChatTabContent.swift**

```swift
import SwiftUI

/// Chat tab body. Renders either `ChatView` when the configured AI
/// provider is reachable or `ChatUnavailableView` when it isn't —
/// `PopoverContentView` already gates whether the Chat tab is visible
/// at all via `chatAvailable`, but we double-check the provider state
/// here because availability can flip mid-session (e.g. OpenAI key
/// becomes invalid).
struct ChatTabContent: View {
    @ObservedObject var chatHolder: ChatViewModelHolder

    var body: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }
}
```

- [ ] **Step 2: Replace chatTabContent in PopoverContentView**

In `PopoverContentView.swift`, delete the `@ViewBuilder private var chatTabContent` (lines 94-101) and replace the call site in `mainContent`:

Old:
```swift
case .chat:
    chatTabContent
```

New:
```swift
case .chat:
    ChatTabContent(chatHolder: chatHolder)
```

- [ ] **Step 3: Build + relaunch**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build && pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Expected: build succeeds, app launches, Chat tab still renders the same content.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/ChatTabContent.swift Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "refactor(popover): extract ChatTabContent into its own file"
```

### Task 2: Extract UpcomingTabContent

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/UpcomingTabContent.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Create UpcomingTabContent.swift**

Move the contents of `upcomingContent` (lines 1282-1317), `groupedUpcoming` (lines 1319-1351), and the private `UpcomingGroup` struct (lines 1408-1413) verbatim into a new `UpcomingTabContent` view. The view depends on `viewModel.upcoming` and `configStore.currentLocale`. Preserve every comment exactly.

```swift
import SwiftUI

struct UpcomingTabContent: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            Group {
                if viewModel.upcoming.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .scaledFont(size: 24, weight: .light)
                            .foregroundStyle(.tertiary)
                        Text("Nothing upcoming", bundle: .module)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedUpcoming, id: \.date) { group in
                            Text(group.label)
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, group.isFirst ? 8 : 14)
                                .padding(.bottom, 4)

                            ForEach(group.items) { item in
                                UpcomingRowView(item: item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private var groupedUpcoming: [UpcomingGroup] {
        let calendar = Calendar.current
        var groups: [UpcomingGroup] = []
        var current: (date: DateComponents, items: [UpcomingItem])?

        for item in viewModel.upcoming {
            let dc = calendar.dateComponents([.year, .month, .day], from: item.airDate)
            if let c = current, c.date == dc {
                current?.items.append(item)
            } else {
                if let c = current, let first = c.items.first {
                    let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
                    groups.append(UpcomingGroup(
                        date: "\(y)-\(m)-\(d)",
                        label: first.airDateFormatted(locale: configStore.currentLocale),
                        items: c.items,
                        isFirst: groups.isEmpty
                    ))
                }
                current = (dc, [item])
            }
        }
        if let c = current, let first = c.items.first {
            let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
            groups.append(UpcomingGroup(
                date: "\(y)-\(m)-\(d)",
                label: first.airDateFormatted(locale: configStore.currentLocale),
                items: c.items,
                isFirst: groups.isEmpty
            ))
        }
        return groups
    }
}

private struct UpcomingGroup {
    let date: String
    let label: String
    let items: [UpcomingItem]
    let isFirst: Bool
}
```

- [ ] **Step 2: Delete from PopoverContentView**

Remove the `upcomingContent` var (1282-1317), `groupedUpcoming` (1319-1351), and the file-scoped `UpcomingGroup` struct (1408-1413). Update the call site:

Old:
```swift
case .upcoming: upcomingContent
```

New:
```swift
case .upcoming: UpcomingTabContent(viewModel: viewModel)
```

- [ ] **Step 3: Build + relaunch + verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build && pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Click the Upcoming tab — confirm rows render with date headers identical to before.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/UpcomingTabContent.swift Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "refactor(popover): extract UpcomingTabContent into its own file"
```

### Task 3: Extract QueueTabContent (the big one)

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/QueueTabContent.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

This is the largest move. QueueTabContent owns its own state for `queueFilter`, `queueScope`, `queueResultType`, `queueFilterFocused`, `tabFrames` — wait, `tabFrames` belongs to the tab bar, stays in orchestrator. But `queueFilter` is read by the orchestrator's `mainContent` to decide whether to hide the tab bar (`!(selectedTab == .queue && isFiltering)`).

Decision: `queueFilter` stays in `PopoverContentView` (orchestrator needs to read it for tab-bar visibility + cmd-N focus); it's passed into `QueueTabContent` as `@Binding`. Same for `queueScope`, `queueResultType` (they need to reset when re-tapping the queue tab — orchestrator owns the reset). `queueFilterFocused` (FocusState) stays in orchestrator (cmd-N focuses it from outside). `detailItem`, `historySource`, `searchResult`, `searchAddFromChat` — orchestrator state, passed as bindings into the tab content so row taps can set them.

- [ ] **Step 1: Create QueueTabContent.swift**

The new struct receives the following:
- `viewModel: QueueViewModel` (observed)
- `searchViewModel: SearchViewModel` (observed)
- `configStore: ConfigStore` (environment)
- `@Binding var queueFilter: String`
- `@Binding var queueScope: QueueItem.Source?`
- `@Binding var queueResultType: QueueResultType`
- `queueFilterFocused: FocusState<Bool>.Binding`
- `@Binding var detailItem: QueueItem?`
- `@Binding var historySource: QueueItem.Source?`
- `@Binding var searchResult: SearchResult?`
- `@Binding var bannerCollapseTask: Task<Void, Never>?` (used by `scheduleBannerCollapse`)

The `QueueResultType` enum becomes top-level inside `QueueTabContent` (move it from `PopoverContentView`). Update references in PopoverContentView to `QueueTabContent.QueueResultType`.

Move the following methods/properties verbatim from PopoverContentView into QueueTabContent, preserving every comment:
- `queueContent` (lines 653-733) — root body
- `isFiltering` (735-737)
- `configuredSources` (739-741)
- `scopedSources` (743-748)
- `filteredQueueItems(for:)` (750-755)
- `libraryResults(for:)` (757-761)
- `newResults(for:)` (763-767)
- `rawSearchResults(for:)` (769-778)
- `count(for:)` (780-801)
- `queueBody` (803-841)
- `statusGroupedSections` (843-864)
- `flatListAcrossSources` (866-887)
- `flatList(for:)` (889-911)
- `compactQueueRowsList(entries:)` (913-928)
- `searchResultRow(_:)` (930-947)
- `scopeChipsRow` (949-971)
- `typeFilterPill` (973-1015)
- `filterChip(...)` (1017-1050)
- `InlineFilterPill` private struct (1052-1097)
- `queueFilterBar` (1099-1139)
- `matchesFilter(_:)` (1141-1150)
- `SectionEntry` enum (1152-1156)
- `visibleSections` (1158-1189)
- `queueSections` (1191-1201)
- `sectionView(for:)` (1203-1253)
- `isConfigured(_:)` (1255-1262)
- `entries(for:)` (1264-1273)
- `health(for:)` (1275-1278)
- `tonightBanner` (299-395) — moves with queue since it renders inside `sectionView(.tonight)`
- `openUpcomingDetail(_:)` (397-412)
- `scheduleBannerCollapse()` (414-427) — uses `bannerCollapseTask` binding
- `tonightTimeFormatter` (429-434)

Body of `QueueTabContent` is the `queueContent` view.

The `sonarrConfigured` / `radarrConfigured` / etc. computed vars are also needed inside QueueTabContent (for `isConfigured` and via `configuredSources`). Add them as local computed vars reading `configStore`. Also `searchAvailable` — local.

- [ ] **Step 2: Update PopoverContentView**

Delete every block listed in Step 1 from PopoverContentView. The orchestrator now needs to keep:
- `isFiltering` (it's used by `mainContent` to decide whether to hide the tab bar) — keep it as a local computed var that reads `queueFilter`:

```swift
private var isFiltering: Bool {
    !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
```

- `QueueResultType` reference — rewrite the re-tap-resets-filter logic in `tabPills`:

Old:
```swift
if tab == .queue && selectedTab == .queue {
    if isFiltering || queueScope != nil || queueResultType != .all {
        withAnimation(.easeOut(duration: 0.18)) {
            queueFilter = ""
            queueScope = nil
            queueResultType = .all
        }
    }
}
```

New (uses `QueueTabContent.QueueResultType`):
```swift
if tab == .queue && selectedTab == .queue {
    if isFiltering || queueScope != nil || queueResultType != .all {
        withAnimation(.easeOut(duration: 0.18)) {
            queueFilter = ""
            queueScope = nil
            queueResultType = .all
        }
    }
}
```

Update the `queueResultType` state declaration:
```swift
@State private var queueResultType: QueueTabContent.QueueResultType = .all
```

- Replace the `case .queue:` call site:

Old:
```swift
case .queue: queueContent
```

New:
```swift
case .queue:
    QueueTabContent(
        viewModel: viewModel,
        searchViewModel: searchViewModel,
        queueFilter: $queueFilter,
        queueScope: $queueScope,
        queueResultType: $queueResultType,
        queueFilterFocused: $queueFilterFocused,
        detailItem: $detailItem,
        historySource: $historySource,
        searchResult: $searchResult,
        bannerCollapseTask: $bannerCollapseTask
    )
```

- [ ] **Step 3: Build + relaunch + verify**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build && pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

Manually verify:
- Queue tab renders sonarr / radarr / lidarr / whisparr sections, tonight banner, needs-you section.
- Typing in the filter bar narrows the queue + fires search hits.
- Source scope chips work; type filter pill works.
- Tapping a row opens DetailView; tapping tonight banner item opens DetailView.
- Re-tapping the Queue tab while filtered clears filter+scope+type.
- Cmd+N focuses the filter bar.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/QueueTabContent.swift Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "refactor(popover): extract QueueTabContent into its own file"
```

### Task 4: Extract the empty-state view

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/PopoverEmptyState.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift`

- [ ] **Step 1: Create PopoverEmptyState.swift**

Move `emptyState` (1355-1395) and `emptyStep(...)` (1397-1404) into a new `PopoverEmptyState` view. It needs `onOpenSettings: () -> Void` and the `moreMenu` view (passed as `@ViewBuilder` content so PopoverContentView stays the owner of the menu).

```swift
import SwiftUI

struct PopoverEmptyState<MoreMenu: View>: View {
    let onOpenSettings: () -> Void
    @ViewBuilder var moreMenu: () -> MoreMenu

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 14) {
                Image(systemName: "gearshape.2")
                    .scaledFont(size: 28, weight: .light)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 4) {
                    Text("ArrBarr is not configured", bundle: .module)
                        .font(.headline)
                    Text("Connect Radarr, Sonarr or Lidarr to get started.", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    emptyStep(number: 1, text: "Open your arr's web UI → Settings → General")
                    emptyStep(number: 2, text: "Copy the API Key")
                    emptyStep(number: 3, text: "Paste it here, along with the URL")
                }
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Button { onOpenSettings() } label: { Text("Open Settings…", bundle: .module) }
                    .modifier(GlassProminentButtonStyle())
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            moreMenu()
                .padding(8)
        }
    }

    private func emptyStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.tertiary)
            Text(text)
        }
    }
}
```

- [ ] **Step 2: Update PopoverContentView call site**

Old:
```swift
} else {
    emptyState
}
```

New:
```swift
} else {
    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
}
```

Delete `emptyState` and `emptyStep` from PopoverContentView.

- [ ] **Step 3: Build + relaunch + verify**

Run the build/relaunch command. Verify by temporarily removing your arr config (or testing on a fresh launch where none are configured) — the empty state should look identical.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/PopoverEmptyState.swift Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift
git commit -m "refactor(popover): extract PopoverEmptyState into its own file"
```

---

## Target 2: DetailView

### File structure after split

- `Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift` — orchestrator (state, load, body ZStack, header, content switch, CTA strip + CTA sub-views, episode overlay invocation, poster lightbox, detailTitleKey, canControl, canPauseResume, siblings, focused, hasActiveDownloads, headerCard helper, titleBadges, dismissPoster).
- `Packages/ArrCore/Sources/ArrCore/Views/Detail/RadarrDetailPanel.swift` — movie body + ratings helper.
- `Packages/ArrCore/Sources/ArrCore/Views/Detail/SonarrDetailPanel.swift` — series body + season pill bar + helpers + ratings.
- `Packages/ArrCore/Sources/ArrCore/Views/Detail/LidarrDetailPanel.swift` — album body + lidarrHeaderCard + disc pill bar + helpers.

The `headerCard(...)` helper is used by Radarr + Sonarr panels (Lidarr has its own custom header). Strategy: keep `headerCard` as a method on `DetailView` and have the orchestrator pass a `@ViewBuilder header: () -> some View` into each panel. That keeps the bridge tight — panels don't need to know about `arrPosterURL`, `enlargedPoster` binding, `titleBadges`, etc.

### Task 5: Extract LidarrDetailPanel (no shared header helper, cleanest first)

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/Detail/LidarrDetailPanel.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift`

- [ ] **Step 1: Create LidarrDetailPanel.swift**

Move the following from DetailView verbatim into a new `LidarrDetailPanel`:
- `lidarrContent` (843-901)
- `lidarrHeaderCard` (903-973)
- `discPillBar(_:)` (978-986)
- `discPill(_:isActive:)` (988-1028)
- `effectiveDiscNumber(in:)` (1034-1044)
- `lidarrYear` (1046-1050)
- `lidarrGenres` (1052)

Required inputs:
- `item: QueueItem`
- `viewModel: QueueViewModel` (observed)
- `configStore: ConfigStore` (environment)
- `lidarrAlbum: LidarrAlbumDetail?`
- `lidarrTracks: [LidarrTrackDetail]`
- `siblings: [QueueItem]`
- `hasActiveDownloads: Bool`
- `loadError: String?`
- `@Binding var enlargedPoster: URL?`
- `@Binding var selectedDiscNumber: Int?`

Closures needed:
- `arrWebURLForItem: (QueueItem) -> URL?` — passed in so panel doesn't depend on the global helper resolver.

`lidarrHeaderCard`'s poster-tap closure mutates `enlargedPoster` — uses the binding directly.

Preserve every existing comment.

- [ ] **Step 2: Replace call site in DetailView**

Old (in `content` switch and direct usage):
```swift
case .lidarr:            lidarrContent
```

New:
```swift
case .lidarr:
    LidarrDetailPanel(
        item: item,
        viewModel: viewModel,
        lidarrAlbum: lidarrAlbum,
        lidarrTracks: lidarrTracks,
        siblings: siblings,
        hasActiveDownloads: hasActiveDownloads,
        loadError: loadError,
        enlargedPoster: $enlargedPoster,
        selectedDiscNumber: $selectedDiscNumber,
        arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) }
    )
```

Delete `lidarrContent`, `lidarrHeaderCard`, `discPillBar`, `discPill`, `effectiveDiscNumber`, `lidarrYear`, `lidarrGenres` from DetailView.

- [ ] **Step 3: Build + relaunch + verify**

Run the build/relaunch command. Open a Lidarr album detail screen — verify the header card, overview, track list, multi-disc pill bar (if you have a multi-disc album), poster tap → lightbox.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/Detail/LidarrDetailPanel.swift Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift
git commit -m "refactor(detail): extract LidarrDetailPanel into its own file"
```

### Task 6: Extract RadarrDetailPanel

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/Detail/RadarrDetailPanel.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift`

- [ ] **Step 1: Create RadarrDetailPanel.swift**

Move from DetailView:
- `movieContent` (493-556)
- `movieRatingChips` (558-566)

Required inputs:
- `item: QueueItem`
- `viewModel: QueueViewModel` (observed)
- `configStore: ConfigStore` (environment)
- `radarrDetail: RadarrMovieDetail?`
- `radarrMovieFile: ArrFile?`
- `siblings: [QueueItem]`
- `hasActiveDownloads: Bool`
- `loadError: String?`
- `headerCard: AnyView` — pre-built by the orchestrator. Panel just renders it.
- `arrWebURLForItem: (QueueItem) -> URL?`

In DetailView, the orchestrator builds the header card via the existing `headerCard(...)` helper and passes it in as an `AnyView`:

```swift
case .radarr, .whisparr:
    let header = AnyView(
        headerCard(
            title: radarrDetail?.title ?? item.title,
            year: radarrDetail?.year,
            runtime: radarrDetail?.runtime,
            genres: radarrDetail?.genres ?? [],
            certification: radarrDetail?.certification,
            ratings: movieRatingChipsFor(radarrDetail),
            existingTrailer: nil,
            posterUrl: arrPosterURL(images: radarrDetail?.images, for: item, in: configStore),
            fallbackSymbol: "film",
            posterAspect: 2.0/3.0
        )
    )
    RadarrDetailPanel(
        item: item,
        viewModel: viewModel,
        radarrDetail: radarrDetail,
        radarrMovieFile: radarrMovieFile,
        siblings: siblings,
        hasActiveDownloads: hasActiveDownloads,
        loadError: loadError,
        header: header,
        arrWebURLForItem: { q in arrWebURL(for: q, in: configStore) }
    )
```

Since `movieRatingChips` consumed `radarrDetail` via `self`, move it to a small free helper or fold it into the orchestrator (`movieRatingChipsFor(_ detail: RadarrMovieDetail?) -> [RatingChip]`). Pick the helper-on-DetailView option to stay close to the rest of the orchestrator's chrome.

`RadarrDetailPanel.body` then renders:
```swift
VStack(alignment: .leading, spacing: 12) {
    header
    if let overview = radarrDetail?.overview, !overview.isEmpty {
        ExpandableOverview(text: overview)
    }
    if hasActiveDownloads {
        DownloadSection(
            items: siblings,
            focused: item,
            showInlineUpgrade: true,
            showCustomFormats: true,
            showListingBadges: false,
            arrWebURLForItem: arrWebURLForItem
        )
    }
    if !hasActiveDownloads {
        if let file = radarrMovieFile {
            ExistingFileBanner(movieFile: file)
        } else if let movieFile = radarrDetail?.movieFile {
            ExistingFileBanner(movieFile: movieFile)
        }
    }
    if let err = loadError {
        Text(err)
            .scaledFont(size: 11)
            .foregroundStyle(.tertiary)
    }
}
```

Preserve every existing comment from `movieContent`.

- [ ] **Step 2: Update DetailView**

Delete `movieContent` and `movieRatingChips`. Add `movieRatingChipsFor(_ detail: RadarrMovieDetail?) -> [RatingChip]` as a private method (copy of the old logic but parameterised). Add the call site shown above into the `content` switch.

- [ ] **Step 3: Build + relaunch + verify**

Open a Radarr movie detail screen. Verify header, overview, download section (if active), existing-file banner (if no active download), upgrade badge. Repeat for a Whisparr movie if configured.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/Detail/RadarrDetailPanel.swift Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift
git commit -m "refactor(detail): extract RadarrDetailPanel into its own file"
```

### Task 7: Extract SonarrDetailPanel

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/Detail/SonarrDetailPanel.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift`

This is the largest of the three panels. It must own the season pill bar, selected-season resolution, and the closures that drive `SeasonRow` (search season, search episode, set monitored).

- [ ] **Step 1: Create SonarrDetailPanel.swift**

Move from DetailView:
- `sonarrContent` (570-642)
- `openEpisodeFromQueueItem(_:)` (650-656) — only callers are inside the season row plumbing, can live on the panel
- `queueByEpisodeId` (663-674)
- `dominantQueueStatus(forSeason:)` (681-689)
- `seasonPillBar(_:)` (694-702)
- `seasonPill(_:isActive:)` (704-750)
- `effectiveSeasonNumber(in:)` (756-775)
- `seasonsHeader(seasons:)` (785-795)
- `searchSeasonClosure(seasonNumber:)` (797-803)
- `searchEpisodeClosure` (805-812)
- `setSeasonMonitoredClosure(seasonNumber:)` (819-834)
- `sonarrRatingChips` (836-839)

Required inputs:
- `item: QueueItem`
- `viewModel: QueueViewModel` (observed)
- `configStore: ConfigStore` (environment)
- `siblings: [QueueItem]`
- `hasActiveDownloads: Bool`
- `loadError: String?`
- `header: AnyView`
- `@Binding var sonarrDetail: SonarrSeriesDetail?` — `setSeasonMonitoredClosure` writes to it after the seasonpass refresh
- `sonarrEpisodes: [SonarrEpisodeDetail]`
- `sonarrEpisodeFiles: [Int: SonarrEpisodeFile]`
- `@Binding var selectedSeasonNumber: Int?`
- `@Binding var selectedEpisode: SonarrEpisodeDetail?`

The orchestrator builds the header the same way as the Radarr panel and hands it in. `sonarrRatingChips` moves into the panel; the orchestrator's headerCard call uses a new private helper `sonarrRatingChipsFor(_:)`.

- [ ] **Step 2: Update DetailView**

Add the orchestrator-side replacement in the `content` switch:

```swift
case .sonarr:
    let header = AnyView(
        headerCard(
            title: sonarrDetail?.title ?? item.title,
            year: sonarrDetail?.year,
            runtime: sonarrDetail?.runtime,
            genres: sonarrDetail?.genres ?? [],
            certification: sonarrDetail?.network,
            ratings: sonarrRatingChipsFor(sonarrDetail),
            existingTrailer: nil,
            posterUrl: arrPosterURL(images: sonarrDetail?.images, for: item, in: configStore),
            fallbackSymbol: "tv",
            posterAspect: 2.0/3.0
        )
    )
    SonarrDetailPanel(
        item: item,
        viewModel: viewModel,
        siblings: siblings,
        hasActiveDownloads: hasActiveDownloads,
        loadError: loadError,
        header: header,
        sonarrDetail: $sonarrDetail,
        sonarrEpisodes: sonarrEpisodes,
        sonarrEpisodeFiles: sonarrEpisodeFiles,
        selectedSeasonNumber: $selectedSeasonNumber,
        selectedEpisode: $selectedEpisode
    )
```

Delete the moved methods/properties. Add `sonarrRatingChipsFor(_ detail: SonarrSeriesDetail?) -> [RatingChip]` as a private helper.

- [ ] **Step 3: Build + relaunch + verify**

Open a Sonarr series detail screen. Verify:
- Season pill bar renders, correct season is preselected (the season of the clicked queue row, or latest with missing episodes).
- Tapping a season changes the SeasonRow.
- Tapping an episode opens `EpisodeDetailOverlay` (this is the orchestrator's overlay — fed by the `$selectedEpisode` binding).
- Pause/resume/delete on an episode row works.
- "Search season" and "Search episode" actions still fire.
- Drilling in from a queue row with a specific S/E auto-opens the episode overlay (orchestrator's `load()` sets `selectedEpisode`).

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/Detail/SonarrDetailPanel.swift Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift
git commit -m "refactor(detail): extract SonarrDetailPanel into its own file"
```

---

## Final verification

- [ ] **Step 1: Full smoke test**

Click Queue / Upcoming / Chat tabs in order. Type a filter, switch scope chips, type filter pill. Open at least one Radarr, one Sonarr, one Lidarr detail screen. Open a Sonarr episode detail. Tap a poster — lightbox opens.

- [ ] **Step 2: Confirm line-count reductions**

```bash
wc -l Packages/ArrCore/Sources/ArrCore/Views/PopoverContentView.swift Packages/ArrCore/Sources/ArrCore/Views/DetailView.swift Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/*.swift Packages/ArrCore/Sources/ArrCore/Views/Detail/*.swift
```

PopoverContentView should drop from 1449 → ~450 lines. DetailView should drop from 1181 → ~600 lines. Each extracted file should be focused on its single responsibility.

## Notes for the implementing engineer

- Comments are load-bearing context — they document past UX decisions, layout traps, and Apple-API gotchas. **Never delete or paraphrase them.** Move them verbatim with the code they annotate.
- This is a pure structural refactor. If you find yourself "improving" a method while moving it (renaming, simplifying, dedup'ing), stop — that belongs in a separate change. The diff for each task should be entirely move + delete + one new call site.
- Build after every task. If a build fails, fix forward — don't pile a second task on top of a broken build.
- The app uses Swift Package Manager via the ArrCore package. Files in `Packages/ArrCore/Sources/ArrCore/Views/PopoverTabs/` and `.../Detail/` are auto-picked-up — no manifest edit needed.
