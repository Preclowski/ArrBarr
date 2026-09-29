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
    Services/      # ServiceGateway (the one door to MediaKit), facades over it
                   #   (RadarrClient…, DownloadClients, TMDBClient,
                   #   MediaServerFacade), QueueAggregator, ConfigStore,
                   #   SecretStore, KVSyncCoordinator, SyncedKeys, LLM providers,
                   #   LocalToolBackend, DemoMocks, WidgetDataStore, …
    Compositions/  # ArrCompositions / ArrQueueLoader: MediaKit records → QueueItem,
                   #   UpcomingItem, HistoryItem
    ViewModels/    # QueueViewModel, ChatViewModel, DiscoverViewModel, SearchViewModel
    Views/         # all SwiftUI (PopoverContentView, SettingsView, ChatView,
                   #   DiscoverTabView, SearchView, DetailView, iOSAppRoot, …)
    AppIntents/    # ArrBarrIntents — Siri/Shortcuts/Spotlight
    Resources/Localizable.xcstrings   # single string catalog, Bundle.module
  Tests/ArrCoreTests/        # ~40 test files (Swift Testing: import Testing, @Test/#expect)

Packages/MediaKit/          # zero-dependency communication layer (Swift 6, strict):
                            #   transport, per-host limits, SQLite resource store,
                            #   SignalR, clients for the arrs / download clients /
                            #   media servers / TMDB, FixtureTransport for demo
  Sources/MediaKit/Fixtures/<kind>.json   # anonymised recordings, open-source titles only
  Sources/MediaKitRecording/              # read-only recording transport + allow-list

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
`eventsource`, plus swift-collections/atomics/system transitively. MediaKit has none.

## MediaKit

All HTTP, sockets and caching live in `Packages/MediaKit`; ArrCore never builds a
`URLSession` for a service. `ServiceGateway` (owned by `ConfigStore`) assembles one
`MediaStack` from the profile, reconciles it on config changes, swaps in
`FixtureTransport` for demo, and is the only thing that touches MediaKit's registry.
Views and view-models take facades from `ConfigStore` (`radarrClient`,
`arrClient(for:)`, `tmdbClient`, `mediaServerClient`) or `ServiceHandles` for a
Settings draft — never construct a client. Reads go through `ResourceStore`
policies (`cacheFirst`, `staleWhileRevalidate`, `mustRevalidate`); writes are
`Command`s that declare invalidation tags. Realtime is `EventHub` over
`SignalRSource`. Fixtures are packed one JSON per kind by `Tools/fixtures/pack_fixtures.py`;
re-record only with `(cd Packages/MediaKit && swift run mediakit-record <instances.json> <scratch-dir>)`
(`MediaKitRecording`: reads only, allow-list), keep the raw recording in the scratchpad, and run
`Tools/fixtures/anonymize_fixtures.py --check` before packing, then `Tools/fixtures/curate_demo.py` (puts
the demo library's titles and artwork from `demo_catalogue.json` over the placeholders) before committing. Package tests:
`(cd Packages/MediaKit && swift test)`. ArrCore compiles with
`.defaultIsolation(MainActor.self)`: wire models, helpers and facades are `nonisolated`.

## Build & Run

```bash
# Build (macOS, Debug → ./build)
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build

# Kill + relaunch (ALWAYS do this after any code change — the user verifies visually)
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

After every code change: rebuild, then kill and relaunch the app — don't ask first.

Xcode 27 ships an MCP server (`xcrun mcpbridge`, configured for this project) —
prefer `BuildProject` + `GetBuildLog` over parsing `xcodebuild` output when the
project is open in Xcode, `DocumentationSearch` before using any macOS/iOS 26+
API from memory, `RunCodeSnippet` for quick behaviour probes, and
`RunProject` + `GetConsoleOutput` to read the app's OSLog. Worktrees are not
open in Xcode: use the `xcodebuild` commands there. Package tests stay on
`swift test`.

Other schemes: `ArrBarriOS`, `ArrBarrWidgets`, `ArrCore`, `ArrMCPServer`,
`Paywall Test`. Build configs: **Debug**, **Release** (OSS/GitHub) and
**Release-AppStore** (sets the `APPSTORE` compilation flag → StoreKit paywall
compiled in). The CI workflow (`.github/workflows/release.yml`) builds the
`ArrBarr` scheme with Xcode 27 on the `xcode-27` runner and ships a DMG + Homebrew cask on release.

## Tests

The `ArrBarr` scheme's test action is empty — tests live in the packages and run
fastest via SwiftPM:

```bash
(cd Packages/ArrCore && swift test)
(cd Packages/ArrMCPServer && swift test)
(cd Packages/MediaKit && swift test)
```

## Key Patterns

- **Localization**: catalog is `ArrCore/Resources/Localizable.xcstrings`
  (en/de/es/fr/nl/pl). In views use `Text("Key", bundle: .module)`; in
  models/services use `String(localized: "Key", bundle: .module)`. Never inline
  user-facing literals. (The old `loc("…")` helper is gone.)
- **Shared singletons** cross target boundaries: `ConfigStore.shared`,
  `QueueViewModel.shared`, `StoreManager.shared`, `PosterStore.shared`. The
  AppDelegate and the SwiftUI scenes observe the *same* instances.
- **Demo mode**: isolated `UserDefaults` suite `pl.incred.ArrBarr.demo` —
  toggling re-points `ConfigStore` live and wipes only the demo suite; the real
  profile is never touched. Launch with `--args -ArrBarrDemo YES` (macOS; bare
  `--demo` only unlocks Developer options) or `ARRBARR_DEMO_SUITE=1` (iOS).
  Every demo answer comes from MediaKit's bundled fixtures through
  `FixtureTransport`; `DemoMocks` only keeps the chat persona and people search.
  Demo instances are seeded configured (demo URL, key `demo`, qBittorrent and
  SABnzbd included), so views gate them like a real profile — no
  `DemoMode.isActive` exemptions in view code.
- **MCP server**: `MCPServerController` (actor, NIO HTTP host, bearer auth, tool
  whitelist) is started/stopped from `AppDelegate.wireMCPServer` based on
  `ConfigStore`. swift-log (server + NIO) is bridged into `os.Logger` via
  `OSLogForwardingHandler` — bootstrap once, before the first `Logger`.
- **Tools / AI**: `LocalToolBackend` implements the arr
  tool catalog used by *both* the in-app chat and the MCP server
  (`ToolCatalogBridge`). Chat runs through `ChatProvider` — `.foundationModels`
  (Apple Intelligence) or `.openai` (OpenAI-compatible API).
- **Logging**: always `Logger(category: "…")` (the `AppLog` extension) — never
  spell out the subsystem, never build a logger per call (`static let`). Levels:
  `.debug` for repeating background work (fetches, purges, reconnects, index
  refreshes), `.notice` for one-shot events with a user-visible consequence
  (a tool the AI ran, a drop, server lifecycle) because `.info`/`.debug` are
  *not* persisted for `log show`, `.error` for failures the user may feel,
  `.fault` only when OUR invariant broke. Counts/ids/enum cases are `.public`;
  titles, people and anything carrying the user's infrastructure are `.private`
  (`sudo log config --subsystem pl.incred.ArrBarr --mode private_data:on` to
  read those while developing). Never log a URL whole — `url.loggableDescription`
  drops the query, where every API key lives. Timings go to `AppSignpost`
  (`OSSignposter`), not to log lines.
- **Realtime**: MediaKit's `SignalRSource` + `EventHub` per arr; `QueueViewModel`
  subscribes to `gateway.events.events()`. Servarr nests `action` inside
  `arguments[0].body`; system wake forces a reconnect (`queueVM.systemDidWake()`).
- **In-app messages**: surfaces talk to their hosts through typed
  `AppMessages.*` (`NotificationCenter.AsyncMessage`), observed with
  `.onMessage(_:perform:)` — no `Notification.Name` posts.
- **Media server**: ONE of Plex / Jellyfin / Emby (`MediaServerConfig`, not a
  `ServiceKind`). `MediaServerIndex` is a lock-guarded snapshot — not an actor —
  so poster resolution stays synchronous; it supplies artwork overrides, the
  Quiz's watch history, and the `media_server_*` tools. Control-gated.
- **Season grouping**: only Sonarr season packs (rows sharing one downloadId)
  collapse into a `QueueGroup`; separate episodes of a series stay separate rows.
- **Custom progress bars**: `GeometryReader` + `RoundedRectangle`, not
  `ProgressView` — SwiftUI's linear `ProgressView` ignores `.frame(height:)`.
- **Tooltip popovers**: `.popover(isPresented:, arrowEdge: .trailing)` steals
  mouse focus — keep `isHovering || showTooltip` for hover actions.
- **Paywall / Pro**: App Store-only. `StoreManager` stays unlocked unless a
  `StoreKitBackend` is injected (`#if APPSTORE`); the paywall is hosted in a real
  `NSWindow`, not a MenuBarExtra sheet (which auto-dismisses on focus loss).
- **Naming**: the swipe-to-discover feature is "Quiz" — never use the word
  "tinder" anywhere (strings, identifiers, docs).
