# Changelog

All notable changes to ArrBarr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.10.0 are described on the
[Releases page](https://github.com/Preclowski/ArrBarr/releases).

## [1.2.0] — 2026-08-10

A release about doing more from inside ArrBarr: drop torrents and NZBs straight
into your arrs, control every duplicate download individually, and have search
find what you actually meant.

### Added

- **Add downloads by drag & drop.** Drop a `.torrent` / `.nzb` file or a magnet
  link onto the menu-bar icon or the open panel — or hand it over from Finder
  ("Open With") and the browser (ArrBarr registers as a `magnet:` handler,
  opt-in via Settings → Download clients). The download is routed *through the
  arr*: the arr picks its own download client and category, so the file doesn't
  just land somewhere — it gets imported. Mixed drops split per protocol, only
  arrs that can actually take the payload are offered, and partial failures
  keep the window open with "N of M could not be added" plus the client's own
  reason. "Add paused" pre-fills from the client's preference where it exposes
  one.
- **Queue multi-select.** "Select multiple" in the queue's ⋯ menu — or just
  ⌘-click a row: tap to toggle, ⇧-click to extend a range, or paint a run of
  rows by dragging across them, then pause / resume / delete everything at
  once. Selection circles draw over the posters, so the queue keeps its
  identity while you pick.
- **Monitored bookmarks.** Movie, series, season, episode, artist and album
  surfaces now show the arr's monitored flag with the same bookmark glyph the
  web UIs use; unmonitored episodes dim as a whole.
- **Search from the download strip.** While something is downloading, a third
  "Search" capsule opens the release list — grab a better release without
  cancelling the current one first.
- **⌘1 / ⌘2 / ⌘3 switch tabs.** Holding ⌘ crossfades the tab pills to their
  numbers, Safari-style.
- Right-click on the menu-bar icon opens a context menu (Settings / About /
  Quit).
- The indexer a grab came from now shows in the download details — it was
  tooltip-only before.

### Changed

- **Duplicate downloads are first-class.** When the same movie or episode has
  two active grabs (auto + manual, say), the detail view now lists both — each
  with its own pause/resume ring and a cancel in the context menu. The bottom
  pause/cancel strip steps aside when there's more than one download (it could
  only ever act on one of them), and Sonarr episode rows flag "2 downloads"
  instead of silently showing one.
- **Search ranks like you'd expect.** Word order no longer matters ("bunny
  big" finds Big Buck Bunny), punctuation folds ("spiderman" reaches
  Spider-Man), a trailing year filters ("dune 2024" beats the 2021 Dune),
  titles already in your library get a nudge, the arr's own popularity signal
  finally counts, and Sonarr/Lidarr vote counts now shrink obscure
  10.0-with-three-votes entries the way movies always did. `imdb:` lookups
  work for series too.
- **Manual search shows the upgrade context.** Your current file is pinned
  above the candidates, each row carries the release's age, and the hover card
  leads with the current → incoming diff instead of a bare spec table.
- Queue rows regrouped: New/Upgrade badge on the title line, download client
  and quality · size next to the status word above the progress bar, and the
  custom-format chips with their score on the line below. The multi-download
  list in details wears the exact same layout.
- Discover cards tint from the poster's own colours instead of catching up a
  beat later, the deck tops itself up in the background, and the end-of-deck
  screen was rebuilt around one clear action.
- Settings: queue section order is dragged directly on the Media managers
  list, "Show in Dock" became a Menu bar / Window picker, and the "Needs you"
  options live in one section with an Errors-only / Errors-and-warnings
  picker.
- Demo mode now has real data behind every surface — library, on-disk files,
  release lists, custom formats — and pause/cancel visibly stick instead of
  being wiped by the next poll.
- The ⋯ menu dropped its "Refresh" item; ⌘R still refreshes.

### Fixed

- Cancelling one of two duplicate downloads no longer makes the other pop back
  like a zombie — detail views tracked one download per episode and hid the
  rest.
- Lidarr never showed up as a drop destination (it spells its torrent protocol
  differently than the other arrs).
- Torrent names with quotes no longer break the upload to the download client.
- The About window is fully localized (Website / Privacy Policy / the pretzel
  credit).
- The download CTA labels are short verbs (Resume / Cancel / Search) in every
  language, so they no longer truncate mid-word.

## [1.1.0] — 2026-08-03

A release about how much ArrBarr talks to your servers. Measured against a live
setup with a 77-item Lidarr queue, sustained LAN traffic went from **5.6 GB/day
to under 0.3 GB/day** with no change to what the app shows you.

### Fixed

- **ArrBarr no longer disappears after a few minutes.** It was never crashing —
  macOS was terminating it. The app was writing 2.1 GB/day into the HTTP cache
  (CFNetwork stores every polled response), which put it over the system's
  disk-writes limit and made `cache_delete` kill it to reclaim the space. The
  cache served nothing — queue data is live by definition — and is now off.
- Poster artwork for Spotlight results survived those terminations, then didn't:
  it lived in `~/Library/Caches`, which is exactly what `cache_delete` empties,
  so every kill was followed by re-downloading the whole library's artwork. It
  now lives where the OS won't reclaim it, and existing artwork is moved rather
  than re-fetched.
- macOS kept no offline "Upcoming" snapshot. The check for whether the App Group
  container was usable passed even when writing to it was denied, so the
  fallback path was unreachable and every refresh logged a permission error.

### Changed

- Queue polling no longer asks the arrs to embed the full series/movie/artist/
  album record in every row of every poll. Titles, years, artwork and deep-link
  slugs are resolved once and kept; the poll now carries only what actually
  changes. On a season pack, where Sonarr repeats the entire series object once
  per episode, this was the single largest thing on the wire.
- Realtime (SignalR) updates now refresh only the arr that sent them, instead of
  all four, and can no longer drive refreshes faster than the polling interval
  would have.
- With a healthy realtime connection, polling is suppressed entirely — Servarr
  broadcasts on a fixed schedule even when idle, so silence is evidence the
  connection has failed rather than that nothing happened. A new **Realtime
  health check** setting (1 / 5 / 15 minutes) controls how long a quiet
  connection is trusted before polling takes over.
- The calendar and the arr health records have their own refresh schedules
  instead of being re-fetched at the queue's cadence, and the connection-status
  probes stop while the panel is closed.
- Spotlight re-indexing is throttled to once every six hours and remembers that
  across launches, instead of re-reading the whole library every couple of
  minutes.

### Added

- Optional notifications when an arr reports a health **error** (Settings →
  General). Off by default; warnings and notices continue to appear only in
  "Needs you".
- Opening the panel puts the cursor straight in the search or chat field, so you
  can start typing immediately.

## [1.0.1] — 2026-07-24

### Added

- Chat input: **Shift+Return** inserts a newline; Return still sends.

### Changed

- New Liquid Glass app icon, across macOS and iOS.
- The search header (back chevron + "Searching") stays pinned to the top of the
  popover instead of scrolling away with the results.
- The Quiz back chevron now matches the plain back chevron used everywhere else.

### Fixed

- Pausing/resuming from a queue poster no longer risks blanking the hover
  controls on *every* row: a single per-item failure — e.g. resuming a download
  the client has already finished and dropped — no longer pins the whole
  download client as unreachable.
- The Quiz "More picks like these" button now asks for another round instead of
  doing nothing.
- Switching the in-app language now takes effect immediately for text sent to
  the chat (the Quiz movie/series buttons and the empty-state suggestion chips)
  and for the "Today"/"Tomorrow" labels in Up Next, instead of lagging in the
  previous language — which also made the assistant keep replying in it — until
  the next relaunch.

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
