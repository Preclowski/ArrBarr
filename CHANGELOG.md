# Changelog

All notable changes to ArrBarr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Releases before 0.10.0 are described on the
[Releases page](https://github.com/Preclowski/ArrBarr/releases).

## [Unreleased]

## [3.2.1] — 2026-10-01

### Added

- Trailers sit in a row under the cast; their tiles fly into the player and back.

### Changed

- Hover previews on the monitor ribbon, bookmark, cast heads, link chips and person portrait.
- The poster lightbox opens with a flare.
- The release-search wait cover's blur pulses like a lens finding focus.
- Detail pages load in two steps without layout jumps.
- Long trailer rows scroll smoothly.

### Fixed

- TMDB rows and filmographies show the same cover as the detail page.
- Trailer tiles no longer vanish mid-flight.

## [3.2.0] — 2026-10-01

### Added

- Roulette spins popular and in-cinema titles (needs a TMDB key), with an "In library" filter.
- Settings: choose the tab the app opens on.
- Confetti when a quiz pick lands in the library.
- Ended series show an "Ended" tag.

### Changed

- Removing a queue row animates: red tint, trash on the poster, slide out.
- Deleting a title asks in the centred alert; add and edit forms float as a card.
- Adding from the quiz throws the card aside and opens the add panel.
- Trailers play in a wider panel; fullscreen only in the detached window.
- Roulette corner buttons show their label on hover.
- Detail pages fade in instead of sliding.
- "Add import exclusion" is now "Don't re-add from lists".

### Fixed

- Reopened history keeps the depth it was scrolled to.
- Episode manual search shows the series' wait stories.
- The Settings search field no longer crowds the window buttons.

## [3.1.0] — 2026-09-30

### Added

- Automatic and manual search in queue, library and Upcoming row menus.
- The quiz card shows in chat as soon as its deck is dealt.
- VoiceOver actions on queue rows: pause, resume, remove.

### Changed

- Search is ⌘F (was ⌘N).
- Quiz and release search load over the title's cover instead of a spinner.
- Filmography scores show as rating chips.
- Apple Intelligence stays selected while its model downloads.
- Posters decode off the main thread; scrolling stutters less.

### Fixed

- Resume all / Pause all on a grouped series stopped after a few episodes.
- Apple Intelligence silently cancelled tools that ask for confirmation.
- OpenAI chat sent each message twice and returned empty replies at the token
  limit.
- Errors show the arr's own reason.
- A wrong qBittorrent or Deluge password is not retried until it changes.
- MCP server refused every request when bound to the LAN.
- Deep links and Siri searches no longer get lost before the panel opens.
- The widget's Today and Tomorrow turn over at midnight.
- More of the app is translated and readable by VoiceOver.

## [3.0.0] — 2026-09-28

### Added

- Shelf tab (macOS): the library as cover flow, morph, warp, tunnel or globe,
  filtered by genre, year and unwatched.
- Prowlarr as a service: its own Settings page, a status dot, and indexer names
  on release rows.
- Hide a queue row from its context menu; "Show hidden" brings it back.
- Watched marks on queue and library posters, from the media server.
- The media server's Settings pane lists its libraries, each with Scan.
- Per-title history in the detail "..." menu.
- History loads further back as you scroll.
- History compares an upgrade with the file it replaced.
- Release list: one sort-and-filter menu, rejected releases hidden until asked
  for, rejection reasons in plain words.
- "Open in <indexer>" on a release row.
- Trailer reel: every clip for the title, the featured one first.
- Quiz variants: from my library, in cinemas / airing now (needs a TMDB key),
  hidden gems.
- The quiz deck fills in while the model is still naming titles.
- "Did you know" cards while a manual search or a quiz deck loads.
- Series detail shows the next episode to air.
- A person's page links to their TMDB profile.
- Episode and track files show release group and languages, like movie files.
- Chat's welcome screen rotates through sixteen suggestions.
- Data cache size and a Clear button in Settings, next to the image cache.
- Genre names are translated.

### Changed

- Requires macOS 26 and iOS 26.
- New data layer, MediaKit: one on-disk cache and per-host request limits for
  every arr, download client, media server and TMDB.
- The queue refreshes on each arr's live pushes and polls only while that
  connection is down.
- A server that keeps failing is backed off and shows as unreachable in Status.
- The widget reads the app's cache and opens no connections of its own.
- One search on Queue, Library and Upcoming: same results, scopes and
  "In library" toggle on every tab.
- Search results, quiz and chat cards use the media server's poster, like the
  queue and the library.
- Every confirmation is one centred alert: Cancel, and a verb that names the
  action.
- macOS 26 look: native glass on floating bars, section titles at full contrast.
- Loading shows the system spinner.
- The Chat tab hides on macOS, as on iOS, when the chosen AI provider can't run.
- The library scrolls smoother on large libraries and keeps its position
  across tab switches.

### Fixed

- A title you just added no longer reads as not owned for minutes.
- Grabbing a delay-profile release no longer leaves a ghost row or a second
  banner.
- Upcoming drops "missing" as soon as a title is imported.
- An outage no longer empties Needs you or repeats the same health alert.
- Search buttons say "queued" only when the arr accepted the search, and show
  its reason when it didn't.
- Profile, root folder and metadata pickers show the arr's reason instead of an
  empty list.
- Siri says it couldn't reach your servers instead of "nothing is downloading".
- Quiz picks resolve to the title they name, not a namesake.
- A person's filmography shows what you own now, not what you owned at first
  open.
- A series no longer takes the media-server artwork of a movie with the same id.
- iPhone search follows a server re-pointed in Settings.
- Chat errors and the connection-test result are translated.

### Security

- An arr's API key goes only to that arr: chat library cards sent it with every
  poster request, TMDB's image CDN included.

## [2.1.0] — 2026-08-30

### Added

- Directing credits on the detail hero — "Directed by" for a film, "Created by"
  for a series, each name tappable through to its filmography.
- Delete a title from the arr, with the two choices the arrs offer: take the
  files on disk with it, and add an import-list exclusion.
- Monitor a season or an episode straight from its row's bookmark.
- Automatic / Manual search from a season or episode row, by right-click or
  long-press.
- Season packs wear the media server's season poster when it has one.
- Library joins the iPhone tab bar, with the system search field.
- Multi-select on iPhone; search collapses into a toolbar button and gives the
  list its row back.
- One set of search scopes, shared by the queue and the library.
- Trailers fill the screen when the phone is turned, and play in demo mode.
- Quiz cards sit on a blurred backdrop of their own artwork that tracks the
  swipe.
- TMDB's mark and attribution notice in Settings and About.

### Changed

- Detail header actions fold into one "..." menu — four glyphs left the title
  almost no width.
- Library chrome, edit-mode buttons and sheets are sized for touch and grow
  with Dynamic Type.
- History leaves the iPhone tab bar for the per-arr section header, as on
  macOS; its event-type filter comes along.
- Interactive indexer searches get a 120s budget instead of the refresh-safe
  15s that timed out searches Sonarr's own UI completes.
- The iPhone minimum is iOS 18.

### Fixed

- qBittorrent no longer reports a torrent it already has as a broken file —
  the drop is matched by info-hash.
- Queue rows and detail views agree on artwork again: the Spotlight seed keeps
  the media-server keys it was dropping.
- Toggling demo mode rebuilds the chat view model instead of leaving the old
  one wired up.
- The demo's quiz CTA opens the real deck, and its suggestions carry real
  artwork.

## [2.0.0-rc3] — 2026-08-17

Release candidate. Not published to the Homebrew tap — download the DMG from
the release page.

### Added

- Library filter searches every name a title has: accents folded ("leon" finds
  "Léon"), plus original-language and translated titles from the arr.
- Library sorts by release date and by date added; Lidarr gains the rating sort.
- Country of production in the detail metadata row (needs a TMDB key).
- Episode rows show a tooltip whether or not they are downloading — synopsis,
  air date, and the on-disk file's quality, size and formats.
- Trailers on every media surface.
- Chat links open the app, verified against what the tools actually returned.
- Cast faces and poster sleeves in chat answers; a copy button on messages.

### Changed

- Detail heroes say what is on disk (Downloaded / 142/150 / Missing) instead of
  tagging the title "library".
- `list_download_queue` covers every configured arr, not just Sonarr and Radarr.
- Library rows: status chip on the trailing edge, file size in its place,
  quality profile as a chip.
- Library filter field takes focus on appear, like Queue and Chat.
- Arr and rating brand marks in the library's picker and sort menus.
- Search results show a person's full name rather than a footnote.
- Album detail drops the title the header already carries.

### Fixed

- Series are resolved to TMDB by id, never by title — a same-named show could
  be mistaken for one you own.
- Chat messages containing two `||` runs no longer render as an empty bubble.
- The existing file is shown under multiple active downloads, not only under
  one.
- Add posts the TMDB id rather than the row's identity.
- Tool results are no longer fed back to the model as a user turn.
- Date parsing and formatting are cached instead of rebuilt per call inside
  view bodies.
- Quality-profile lookups read through the shared cache.

## [2.0.0-rc2] — 2026-08-15

Release candidate. Not published to the Homebrew tap — download the DMG from
the release page.

### Added

- Enlarged poster: a zoom slider on macOS, and right-click to save the image
  to Downloads. The slider and the close button fade out when idle.

### Changed

- Quality-profile chip is a neutral filled tag instead of purple, and leads
  the movie hero's badge row.
- Episode rows drop their hover pause / resume / cancel actions — the queue
  owns those — and gain the queue's long-hover tooltip.
- Upgrade / New tag on an episode row moved to the trailing edge.
- Season-pack tooltip shows the upgrade diff the same way the single-item
  tooltip does, and no longer lists file names.
- Indexer moved into the detail info grid.

### Fixed

- Quality profiles are fetched once per arr instead of on every detail open
  and every Upcoming row.
- iOS build was broken by a stale assignment to a now-constant poll interval.

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
