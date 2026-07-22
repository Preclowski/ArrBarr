# ArrBarr

Native menu-bar / mobile companion for the *arr stack. Glance at Sonarr, Radarr,
Lidarr (+ Whisparr) queues, upcoming media and history; pause/resume/delete
downloads; search & add titles; an AI chat + discovery ("Quiz") tab; and an
embedded MCP server that exposes the same arr tools to external LLM clients.

Three app targets share one core: **ArrBarr** (macOS menu bar), **ArrBarriOS**
(iOS) and **ArrBarrWidgets** (WidgetKit). Vibe-coded with Claude Code.

## Architecture

Almost nothing lives in the app targets — they are thin shells. All models,
services, view-models and SwiftUI views live in the **ArrCore** local Swift
package, imported by every target. A second package, **ArrMCPServer**, hosts the
MCP server and depends on ArrCore.

```
ArrBarr.xcodeproj
  ArrBarr/            # macOS target — thin
    ArrBarrApp.swift      # @main, MenuBarExtra(style: .window), AppShortcutsProvider
    AppDelegate.swift     # NSApp lifecycle, windows (Settings/About/Paywall),
                          #   MCP wiring, notifications, Spotlight, wake handler
    ArrBarr.entitlements  # sandbox + network.client + network.server
  ArrBarriOS/         # iOS target — thin
    ArrBarriOSApp.swift   # @main, WindowGroup → iOSAppRoot() (in ArrCore)
  ArrBarrWidgets/     # WidgetKit extension
    ArrBarrWidgets.swift
  Shared/
    StoreKitBackend.swift # injected into StoreManager only in APPSTORE builds

Packages/ArrCore/           # the real codebase (Swift 6 tools, lang mode v5)
  Sources/ArrCore/
    Models/        # QueueItem, QueueGroup, ArrTypes, ChatMessage, DiscoverItem,
                   #   MCPTypes, ServiceConfig, DownloadClientTypes, …
    Services/      # arr clients (Sonarr/Radarr/Lidarr/Whisparr), download
                   #   clients (qBittorrent/Transmission/rTorrent/Deluge/
                   #   SABnzbd/NZBGet), QueueAggregator, RealtimeUpdates,
                   #   ConfigStore, SecretStore, KVSyncCoordinator, SyncedKeys,
                   #   LLM providers, ToolBackend +
                   #   LocalToolBackend, DemoMocks, WidgetDataStore, …
    ViewModels/    # QueueViewModel, ChatViewModel, DiscoverViewModel, SearchViewModel
    Views/         # all SwiftUI (PopoverContentView, SettingsView, ChatView,
                   #   DiscoverTabView, SearchView, DetailView, iOSAppRoot, …)
    AppIntents/    # ArrBarrIntents — Siri/Shortcuts/Spotlight
    Resources/Localizable.xcstrings   # single string catalog, Bundle.module
  Tests/ArrCoreTests/        # ~40 test files (Swift Testing: import Testing, @Test/#expect)

Packages/ArrMCPServer/      # MCP server (depends on ArrCore)
  Sources/ArrMCPServer/
    MCPServerController.swift # actor: start/stop, Config + BackendInputs
    NIOHTTPHost.swift         # SwiftNIO HTTP host
    MCPCallRouter.swift, ToolCatalogBridge.swift  # bridge LocalToolBackend → MCP
    StaticBearerValidator.swift, OSLogForwardingHandler.swift
  Tests/ArrMCPServerTests/

docs/superpowers/{plans,specs}/  # design docs per feature (dated)
docs/{design,notes}/             # ad-hoc design notes
```

External deps (resolved by SPM): `swift-nio`, `mcp-swift-sdk`, `swift-log`,
`eventsource`, plus swift-collections/atomics/system transitively.

## Build & Run

```bash
# Build (macOS, Debug → ./build)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build

# Kill + relaunch (ALWAYS do this after any code change — the user verifies visually)
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

After every code change: rebuild, then kill and relaunch the app — don't ask first.

Other schemes: `ArrBarriOS`, `ArrBarrWidgets`, `ArrCore`, `ArrMCPServer`,
`Paywall Test`. Build configs: **Debug**, **Release** (OSS/GitHub) and
**Release-AppStore** (sets the `APPSTORE` compilation flag → StoreKit paywall
compiled in). The CI workflow (`.github/workflows/release.yml`) builds the
`ArrBarr` scheme on `macos-26` and ships a DMG + Homebrew cask on release.

## Tests

The `ArrBarr` scheme's test action is empty — tests live in the packages and run
fastest via SwiftPM:

```bash
(cd Packages/ArrCore && swift test)
(cd Packages/ArrMCPServer && swift test)
```

## Key Patterns

- **Localization**: catalog is `ArrCore/Resources/Localizable.xcstrings`
  (en/de/es/fr/pl). In views use `Text("Key", bundle: .module)`; in
  models/services use `String(localized: "Key", bundle: .module)`. Never inline
  user-facing literals. (The old `loc("…")` helper is gone.)
- **Shared singletons** cross target boundaries: `ConfigStore.shared`,
  `QueueViewModel.shared`, `StoreManager.shared`, `PosterStore.shared`. The
  AppDelegate and the SwiftUI scenes observe the *same* instances.
- **Demo mode**: isolated `UserDefaults` suite `pl.incred.ArrBarr.demo` —
  toggling re-points `ConfigStore` live and wipes only the demo suite; the real
  profile is never touched. Launch with `--args --demo` (macOS) or
  `ARRBARR_DEMO_SUITE=1` (iOS).
- **MCP server**: `MCPServerController` (actor, NIO HTTP host, bearer auth, tool
  whitelist) is started/stopped from `AppDelegate.wireMCPServer` based on
  `ConfigStore`. swift-log (server + NIO) is bridged into `os.Logger` via
  `OSLogForwardingHandler` — bootstrap once, before the first `Logger`.
- **Tools / AI**: `ToolBackend` protocol; `LocalToolBackend` implements the arr
  tool catalog used by *both* the in-app chat and the MCP server
  (`ToolCatalogBridge`). Chat runs through `ChatProvider` — `.foundationModels`
  (Apple Intelligence) or `.openai` (OpenAI-compatible API).
- **Realtime**: `RealtimeUpdates` consumes Servarr SignalR/WebSocket. Servarr
  nests `action` inside `arguments[0].body` — parse that envelope, and force a
  reconnect on system wake (`queueVM.systemDidWake()`).
- **Season grouping**: `QueueGroup` wraps multiple `QueueItem`s; `.real` packs
  share a downloadId, `.virtual` bundles have independent progress.
- **Custom progress bars**: `GeometryReader` + `RoundedRectangle`, not
  `ProgressView` — SwiftUI's linear `ProgressView` ignores `.frame(height:)`.
- **Tooltip popovers**: `.popover(isPresented:, arrowEdge: .trailing)` steals
  mouse focus — keep `isHovering || showTooltip` for hover actions.
- **Paywall / Pro**: App Store-only. `StoreManager` stays unlocked unless a
  `StoreKitBackend` is injected (`#if APPSTORE`); the paywall is hosted in a real
  `NSWindow`, not a MenuBarExtra sheet (which auto-dismisses on focus loss).
- **Naming**: the swipe-to-discover feature is "Quiz" — never use the word
  "tinder" anywhere (strings, identifiers, docs).
