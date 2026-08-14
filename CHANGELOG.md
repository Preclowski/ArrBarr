# Changelog

All notable changes to ArrBarr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.10.0 are described on the
[Releases page](https://github.com/Preclowski/ArrBarr/releases).

## [Unreleased]

## [2.0.0-rc1] — 2026-08-14

Release candidate. Not published to the Homebrew tap — download the DMG from
the release page.

### Added

- Media server: connect one of Plex, Jellyfin or Emby (Control). Artwork comes
  from the server when it has the title, watch history feeds the Quiz, and the
  new Settings pane offers Scan library and — Plex only — Empty trash.
- Media server has its own row in Settings → Status, with a health probe.
- Chat / MCP tools: `media_server_watch_history`, `media_server_now_playing`
  and `media_server_scan_library` (the last one asks before it runs).
- Queue grouping by title: a title's two or more downloads fold into one
  collapsible row with aggregate progress and Pause / Resume / Delete all.
  Off / collapsed / expanded in Settings.
- Library tab: a browsable cover grid of everything on the arrs, with status
  filters, sort, and local substring search.
- Upcoming albums show their track count.

### Changed

- "Always visible items" is a menu picker instead of a segmented control.

### Fixed

- Enlarging a cast portrait fetched the 185-pixel thumbnail and zoomed it to
  5× instead of the original.
- Magnet links titled a download "The+Matrix+1999" — `dn` is form-encoded, so
  `+` is a space.

## [1.3.1] — 2026-08-12

### Changed

- "Existing file" block is a key-value table (Quality / Size / Score) matching
  the download spec; format chips and the filename render label-less below it.
- Score is sign-coloured (green/red) in the plain download spec and the
  existing-file table.
- Single active download gets a "Downloading" caption, symmetric with
  "Existing file".

## [1.3.0] — 2026-08-12

### Added

- Person view: tap a cast photo to open an in-app page with bio, photo,
  external links and the full filmography (movies / series, owned marked,
  credit role per title).
- People search: scope filter on the search field plus a `person:` prefix;
  matching a well-known name shows a "Starring" section with their films.
- Artist view for Lidarr: albums grouped by release type (albums / EPs /
  singles) in collapsible sections, with per-album download coverage.
  Tapping an artist anywhere now lands here instead of on a random album.
- Music search finds albums, not just artists (Music scope). Adding an
  album creates the artist with only that album monitored.
- Monitor mode picker when adding an artist (all / future / missing /
  existing / first / latest album / none).
- Per-track view with file quality; album view links to the artist.
- Episodes / Tracks section headers show downloaded-of-total counts.
- "Existing file" caption over the on-disk file block; the library chip
  moved up next to the title in every detail view.
- Edit button in movie / series / artist detail headers: change quality
  profile, root folder and the arr-specific bits (minimum availability,
  series type, metadata profile). Changing the folder moves the files.
- Empty search results show a message instead of a blank list.
- Demo mode ships people + artist fixtures.

### Fixed

- Lidarr queue rows and details regained pause/resume (protocol-name quirk).
- Lidarr artist images load again (relative remoteUrl quirk).
- Search scoring: albums no longer shove same-titled movies off the top.
- Entering the person view no longer slows the whole app down.

### Changed

- Search scope chip "Albums" is now "Music".
- Detail section headers (Cast / Seasons / Episodes / Tracks) share one
  style, with item counts.

## [1.2.1] — 2026-08-11

### Added

- Monitor bookmarks in detail headers now actually toggle monitoring (movie /
  series / season / episode / album).
- One "Search" button per detail surface, in the header next to the bookmark —
  tapping opens the automatic / manual choice.
- Rating pills link to IMDb / TMDB / TVDB / RT / Metacritic; cast photos link
  to TMDB profiles.
- Cast strip in the add-to-library panel, with a loading skeleton.
- Quiz: "library" badge on owned cards; the AI defaults to suggesting titles
  you don't own yet.
- Demo mode: duplicate-download fixtures; monitor toggles stick.

### Changed

- Detail buttons are capsules with short labels; Pause orange, Resume blue,
  Cancel a compact red ✕.
- The multi-download list uses the queue-row layout with a pause ring in the
  poster slot; per-file sizes instead of an aggregate.
- Quiz skip icon is ✕ (the old ⏩ pointed against the animation).
- The add panel shows the overview beside the poster, like the detail view.
- "Show more" appears only when it hides more than its own height.

### Fixed

- Cancelling from a context menu in the detail download list did nothing on
  iOS.
- The wrong search button showed the spinner after starting an automatic
  search.
- Missing translations: quiz "looking for more", bookmark tooltips, About
  window links.

## [1.2.0] — 2026-08-10

### Added

- Drag & drop `.torrent` / `.nzb` files or magnet links onto the menu-bar icon
  or the panel; Finder "Open With" and an opt-in `magnet:` handler included.
  Downloads are routed through the arr's own client and category so they get
  imported.
- Queue multi-select: ⌘-click or "Select multiple" in the ⋯ menu, ⇧-click for
  ranges, drag to paint rows; bulk pause / resume / delete.
- Monitored bookmarks on movie / series / season / episode / artist / album
  surfaces; unmonitored episodes dim.
- "Search" button on the download CTA strip — open the release list while a
  download is running.
- ⌘1 / ⌘2 / ⌘3 switch tabs; holding ⌘ shows the numbers on the tab pills.
- Right-click menu on the menu-bar icon (Settings / About / Quit).
- Indexer shown in download details.

### Changed

- Duplicate downloads of the same movie/episode are all listed in details,
  each with its own pause/resume and cancel; Sonarr episode rows show a
  download count.
- Search ranking: order-free word matching, punctuation folding, trailing-year
  filter ("dune 2024"), library boost, arr popularity signal, vote-count
  shrinkage for series/albums, `imdb:` lookups for series.
- Manual search: current file pinned above the candidates, release age on each
  row, diff-first hover cards.
- Queue rows regrouped: badge on the title line, client + quality · size next
  to the status word, format chips + score under the bar; the details download
  list uses the same layout.
- Discover: cards tint from the poster itself, the deck refills in the
  background, rebuilt end-of-deck screen.
- Settings: queue order dragged directly on the Media managers list, Menu bar /
  Window picker, consolidated "Needs you" section with a severity picker.
- Demo mode covers library, files and release lists; pause/cancel stick.
- Removed "Refresh" from the ⋯ menu (⌘R still works).

### Fixed

- Cancelling one of two duplicate downloads no longer resurrects the other in
  detail views.
- Lidarr was missing as a drop destination (protocol string mismatch).
- Torrent names containing quotes broke the upload to the download client.
- About window is fully localized.
- Download CTA labels no longer truncate (short verbs: Resume / Cancel /
  Search).

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
