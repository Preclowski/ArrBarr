# Changelog

All notable changes to ArrBarr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.10.0 are described on the
[Releases page](https://github.com/Preclowski/ArrBarr/releases).

## [1.0.0] — 2026-07-22

The 1.0 release is a large one: 370-odd commits since 0.10.0 turned a macOS
menu-bar queue monitor into a three-target app with an AI chat, a discovery
feed, an embedded MCP server and an iOS companion.

### Added

**iOS app and widgets**
- New **ArrBarriOS** target — the queue, calendar, search, detail and chat
  surfaces on iPhone and iPad, sharing the whole ArrCore package with macOS.
- New **ArrBarrWidgets** WidgetKit extension: per-service library counts
  (small), a multi-service status grid (medium), and Up Next (small and medium).
- A floating Liquid Glass search bar and iOS-native confirmation dialogs.

**AI chat**
- A chat tab that drives the whole stack in plain language, backed by either
  Apple Intelligence (Foundation Models) or any OpenAI-compatible API.
- A built-in tool backend, so chat works with no external MCP server.
- Destructive tool calls are gated behind an explicit confirm card that shows
  the poster, quality profile and root folder before anything is added.
- Markdown rendering for assistant messages, including GFM tables, lists and
  code blocks; rich result cards with poster carousels; block and inline
  spoilers with tap-to-reveal.

**Embedded MCP server**
- New **ArrMCPServer** package: a SwiftNIO HTTP host that exposes the same arr
  tool catalog to external LLM clients.
- Secure by default — bearer-token auth on, loopback bind, `Origin` validation,
  and a refusal to bind a non-loopback address without a token.
- Per-tool enable/disable in Settings, and a device-only bearer token that never
  syncs.

**Search, add and discovery**
- Search across every configured arr at once from a `+` button, with a
  relevance-ranked, de-duplicated result list and a Bayesian quality
  tie-breaker.
- An add panel that picks quality profile and root folder, shows cast, and
  understands titles that came from TMDB rather than from an arr.
- **Quiz** — swipe-to-discover, powered by TMDB and cross-referenced against
  your library so owned titles open the normal detail view instead.

**Media and library**
- **Whisparr** as a fourth media source, behind an age confirmation and with
  optional poster blurring.
- Detail views for queue items, movies, series, seasons, episodes and albums,
  with cast, ratings, overviews, upgrade diffs and existing-file comparisons.
- A "start now" action for queued and deferred downloads.

**Platform integration**
- Six App Intents for Siri, Shortcuts and Spotlight: show queue, show upcoming,
  pause all, resume all, search to add, and check arr health.
- An optional detached macOS window (Dock-icon mode) with a NavigationSplitView
  layout at feature parity with the popover.
- iCloud sync of settings and secrets in App Store builds, with a visible sync
  status, quota-error surfacing and an explicit off switch.

**Localization**
- **Dutch (nl)** added, bringing the app to six fully translated languages, and
  regenerated German, Spanish and French with a Polish gold pass and a
  terminology glossary.

### Changed

- Almost all code moved out of the app targets into the **ArrCore** Swift
  package, so macOS, iOS and the widgets share one implementation.
- Secrets (arr API keys, download-client passwords, OpenAI and TMDB keys) now go
  through a single `SecretStore`: the system Keychain when the build's signature
  actually provisions the shared access group, and the sandboxed app-container
  plist otherwise. Existing plaintext values migrate automatically.
- Connection health is now monitored centrally, with per-service status dots and
  "Needs you" rows instead of scattered error banners.
- Being away from the LAN is treated as an expected state: a quiet offline chip,
  no alarms, and no repeated retry noise.
- Chat dropped external MCP-server support in favour of the built-in backend,
  which the embedded server now shares.
- Queue rows, progress bars, tooltips, diffs and detail panels were unified onto
  one visual language — glass floating bars, outlined label pills, and a single
  download-progress card.

### Fixed

- The hover tooltip no longer swallows the first click on a queue action, and
  the popover no longer flickers on every queue refresh.
- Search no longer loses keyboard focus on each keystroke, and no longer spins
  on every poll.
- Season packs stopped showing redundant per-episode metadata and phantom
  upgrade arrows.
- Detail views read the queue item live instead of resurrecting a stale
  snapshot, so a finished import no longer freezes at "importing".
- The MCP handshake is now performed before `tools/list` and `tools/call`, and
  destructive-tool classification is driven by one shared source of truth
  instead of a suffix heuristic that misclassified `*_search` as destructive.
- Keychain items are matched regardless of their iCloud-sync flag, so toggling
  sync no longer hides existing secrets.
- Many localization gaps closed, including strings that bypassed Xcode's
  extraction because their keys were built at runtime.

### Release engineering

- CI ran `xcodebuild -scheme ArrBarr test` against a scheme with no test action,
  which failed on every run and silently skipped DMG creation, release upload
  and the Homebrew cask update. Tests now run the real SwiftPM suites, and
  publishing lives in a separate job that only runs when they pass.
- `swift-markdown` was pinned to its `main` branch and `Package.resolved` was
  git-ignored, so every signed DMG built against whatever landed upstream that
  day. All dependencies are now pinned to released versions and all three
  resolved files are tracked.
- `CURRENT_PROJECT_VERSION` had never been incremented past 1. It now derives
  from the CI run number, and a release whose tag disagrees with
  `MARKETING_VERSION` fails the build before anything is published.
- Third-party attribution now ships in the DMG
  ([THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)), as Apache-2.0 §4(d)
  requires for SwiftNIO and swift-log.
- The hardcoded development team moved out of the checked-in project settings,
  so forks build ad-hoc instead of failing to sign.

## [0.10.0] — 2026-05-03

Baseline for this changelog. See the
[release notes](https://github.com/Preclowski/ArrBarr/releases/tag/v0.10.0).
