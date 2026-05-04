# Lidarr Search — Future Work

Deferred from the initial Search tab implementation (Radarr + Sonarr only).

## How it differs from Radarr/Sonarr

- Lidarr searches **artists**, not titles. `/api/v1/artist/lookup?term=<query>` returns a list of artists.
- Results show circular artist thumbnails (MusicBrainz convention), not portrait posters.
- "Already in library" check: `/api/v1/artist` returns all monitored artists — filter by `foreignArtistId`.

## Add panel fields (Lidarr-specific)

| Field | API param | Notes |
|---|---|---|
| Quality Profile | `qualityProfileId` | Fetch from `/api/v1/qualityprofile` |
| Root Folder | `rootFolderPath` | Fetch from `/api/v1/rootfolder` |
| Metadata Profile | `metadataProfileId` | Lidarr-specific, fetch from `/api/v1/metadataprofile` |
| Monitor | `monitored` + `monitorNewItems` | Chips: All / Future / Missing / None |

POST to `/api/v1/artist` to add.

## Visual notes

- Sub-tab accent: amber (`#ff9f40`) to distinguish from Radarr (blue) and Sonarr (blue).
- Artist thumbnails: `width: 34px, height: 34px, border-radius: 50%` in result rows.
- Hero image in add panel: `46×46px` circle.
- Image source: `images` array on artist record, `coverType = "poster"` — same `pickPosterURL` helper works.

## API endpoint

`GET /api/v1/artist/lookup?term=<query>` — note Lidarr uses `/api/v1/` not `/api/v3/`.
`POST /api/v1/artist` to add an artist.

## Mock data shape

```swift
struct LidarrArtistLookupResult: Decodable {
    let foreignArtistId: String
    let artistName: String
    let overview: String?
    let images: [ArrImage]?
    let genres: [String]?
    let statistics: LidarrArtistStats?
}

struct LidarrArtistStats: Decodable {
    let albumCount: Int?
}
```
