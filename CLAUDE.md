# ArrBarr

macOS menu-bar app (Swift/SwiftUI) that monitors Sonarr and Radarr queues.

## Build & Run

```bash
# Build
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build

# Kill + relaunch (always do this after any code change)
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

After every code change: rebuild, then kill and relaunch the app.

## Project Layout

```
ArrBarr/
  AppDelegate.swift          # NSApplicationDelegate, status-bar item setup
  Views/
    PopoverContentView.swift # Root popover
    QueueRowView.swift       # Single download row
    QueueGroupRowView.swift  # Season-pack / grouped row + tooltip
    UpcomingRowView.swift    # Upcoming episodes
    HistoryView.swift
    SettingsView.swift
  ViewModels/
    QueueViewModel.swift
  Models/
    QueueItem.swift
  Services/
    SonarrClient.swift
    RadarrClient.swift
    QueueAggregator.swift    # Merges Sonarr + Radarr queues, handles grouping
    DemoMocks.swift
```

## Key Patterns

- **Localization**: use `loc("Key")` helper, never string literals directly in UI
- **Tooltip popovers**: `.popover(isPresented:, arrowEdge: .trailing)` — tooltip steals mouse focus, keep `isHovering || showTooltip` for hover actions
- **Season grouping**: `QueueGroup` wraps multiple `QueueItem`s; `.real` packs share a downloadId, `.virtual` bundles have independent progress
- **Custom progress bars**: use `GeometryReader` + `RoundedRectangle` instead of `ProgressView` — SwiftUI's linear `ProgressView` ignores `.frame(height:)`
