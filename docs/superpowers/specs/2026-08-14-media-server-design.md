# Media server integration (Plex / Jellyfin / Emby)

Date: 2026-08-14

One media server, chosen by the user, connected read-mostly. It supplies
artwork, watch state and two maintenance actions. No new views — every payoff
lands in surfaces that already exist.

## Scope

- Three servers supported, **one active at a time**.
- New Settings section "Media server", Control-gated (paywall) like download
  clients.
- Posters preferred from the media server, falling back to the arr's artwork.
- Settings actions: **Scan library**, **Empty trash**.
- Watch history feeds the Quiz (taste signal + exclusions).
- Three MCP / chat tools.

Explicitly out of scope: watched badges in queue rows, "now playing" UI,
play/deep-link buttons, multi-server configs.

## Configuration

`MediaServerKind` is a new enum (`plex`, `jellyfin`, `emby`) and deliberately
**not** a `ServiceKind` case. `ServiceKind` drives queue aggregation, health
reporting, `arrOrder`, brand icons and the secrets roster; a media server
belongs to none of those loops, and widening the enum would touch every
exhaustive switch in the app for no benefit.

```swift
public struct MediaServerConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var kind: MediaServerKind
    var baseURL: String
    var token: String
    /// Resolved on connection test; needed for Jellyfin/Emby watch state.
    var userId: String
}
```

- Persisted under `ArrBarr.mediaServer` (JSON, token blanked).
- Token lives in `SecretStore` under `SecretKey.mediaServerToken`
  (`synced: true`, matching the arr API keys), and is added to
  `SecretKey.syncable`.
- `ArrBarr.mediaServer` joins `SyncedKeys.all`.
- `ProFeature.mediaServer` is added for the paywall copy.

### Auth per server

| Server | Header | Token acquisition |
|---|---|---|
| Plex | `X-Plex-Token` | User pastes it. Settings explains the standard route: open any library item's **Get Info → View XML** and copy `X-Plex-Token` from the URL. |
| Jellyfin | `Authorization: MediaBrowser Token="…"` | API key from Dashboard → API Keys. |
| Emby | `X-Emby-Token` | API key from Dashboard → Advanced → API Keys. |

Jellyfin and Emby also need a user id for watch state; the connection test
resolves it (`/Users` filtered to the token's owner) and stores it in
`userId`, so the user never types it.

## Client layer — `Services/MediaServer/`

```swift
protocol MediaServerClient: Sendable {
    func testConnection() async -> ConnectionTestResult
    func libraryIndex() async throws -> [MediaServerEntry]
    func scanLibraries() async throws
    func emptyTrash() async throws
    func nowPlaying() async throws -> [MediaServerSession]
    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch]
}
```

`MediaServerClientFactory.make(config:)` returns the right implementation.
Jellyfin and Emby share a base implementation parameterised by header style
and a couple of path deltas; Plex is its own type (XML-ish JSON at
`/library/sections`, `?includeGuids=1` for provider ids).

`MediaServerEntry` carries: server item id, kind (movie / show), title, year,
poster path, external ids (tmdb / tvdb / imdb), watched flag, play count,
last-played date.

## Index — `MediaServerIndex` (actor)

One fetch across all movie and show libraries, reduced to
`[ExternalKey: MediaServerEntry]` where `ExternalKey` is `.tmdb(Int)`,
`.tvdb(Int)` or `.imdb(String)`. Every id a title exposes becomes a key, so a
Radarr movie known only by imdb still matches.

Refresh triggers: config change, app launch, a 15-minute timer, and the
Settings "Scan library" action. Failure leaves the previous index in place —
a media server that goes away must not blank the artwork.

## Posters

Poster URLs are baked into models at fetch time (`QueueItem.posterURL`,
`UpcomingItem.posterURL`, `LibraryItem.posterURL`, `SearchResult.posterURL`),
and `RemotePoster` receives only a URL — it has no title identity to look up.
So the substitution happens where those models are built, through one helper:

```swift
MediaServerPosters.override(tmdbId:tvdbId:imdbId:fallback:) -> URL?
```

It returns the server's image URL (token in the query string, so
`posterRequiresAuth` stays false) when the index holds a match, and the
`fallback` otherwise. An empty or still-loading index therefore behaves
exactly like today.

## Quiz

`DiscoverLLMPrompt.build` gains a `watched: [String]` parameter used twice in
the prompt: as a taste signal ("the user recently watched …") and as an
exclusion list. Capped at 40 titles to bound the prompt. The library deck
source drops titles the index marks watched.

## MCP / chat tools

| Tool | Gate |
|---|---|
| `media_server_watch_history` | read-only (allowlist) |
| `media_server_now_playing` | read-only (allowlist) |
| `media_server_scan_library` | destructive → confirmation |

All three are advertised only when the media server is configured.
`ChatToolCatalog.MCPToolInfo` gains an optional `systemImage`, because these
tools have no `ServiceKind` brand mark to render. `LocalToolBackend` and
`MCPServerController.BackendInputs` each gain a `mediaServer` field.

## Testing

- Response parsing for each of the three servers against captured fixtures.
- External-id extraction, including Plex's `guid` forms
  (`tmdb://123`, `imdb://tt…`, legacy `com.plexapp.agents.*`).
- Poster override: match, no match, empty index — the last two must return
  the arr fallback unchanged.
- Prompt building includes watched titles and honours the 40-title cap.

Localization: every new user-facing string goes into
`ArrCore/Resources/Localizable.xcstrings` (en/de/es/fr/nl/pl).
