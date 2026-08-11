import Foundation

public extension Notification.Name {
    /// Posted by AppDelegate when the user picks "Add…" from the status menu.
    /// PopoverContentView listens for this and opens the search overlay.
    static let arrBarrTriggerAdd = Notification.Name("ArrBarrTriggerAdd")

    /// Posted when a result card in chat is tapped. `userInfo["item"]` is a
    /// `QueueItem` — usually a synthetic one carrying just `source`, `title`,
    /// `entityId`, and `posterURL` (the only fields DetailView needs to fetch
    /// detail). PopoverContentView and MainWindowView listen and set their
    /// detail target.
    static let arrBarrOpenDetail = Notification.Name("ArrBarrOpenDetail")
    /// Posted by deep-tree views that need a confirmation modal.
    /// `userInfo["payload"]` is the `PendingConfirm` instance.
    /// `PopoverContentView` listens and renders the overlay at panel
    /// width.
    static let arrBarrConfirmRequest = Notification.Name("ArrBarrConfirmRequest")

    /// Posted after a successful "Test Connection" in Settings. The
    /// QueueViewModel listens and refreshes immediately so a freshly-entered
    /// API key clears the stale "missing API key" banner without waiting for
    /// the next scheduled poll.
    static let arrBarrConfigValidated = Notification.Name("ArrBarr.ConfigValidated")

    /// Posted when torrent/nzb files (or a magnet link) are dropped onto the
    /// panel or the detached window. `userInfo["urls"]` is `[URL]`; AppDelegate
    /// listens and opens the add-download window — the same one Dock drops,
    /// "Open With" and magnet clicks land in, so there is exactly one add UI
    /// regardless of how the payload arrived.
    static let arrBarrDropDownloads = Notification.Name("ArrBarr.DropDownloads")

    /// Posted by the `SearchToAddIntent` App Intent. `userInfo["query"]` is the
    /// search string; the queue/search surface picks it up and runs the search.
    static let arrBarrSearchQuery = Notification.Name("ArrBarr.SearchQuery")
}

public enum DetailRequest {
    /// Build a synthetic `QueueItem` suitable for handing to
    /// `DetailView`. `source` + `entityId` (the **arr-internal**
    /// record id, NOT the foreign TMDB/TVDB/MBID) is what the detail
    /// panel needs to refetch the full record — MediaRef carries the
    /// external identity, which is a different thing and not
    /// interchangeable with the internal id without a library-map
    /// lookup. See `tap(_:)` below for the router that uses both.
    public static func syntheticItem(
        source: QueueItem.Source,
        entityId: Int,
        title: String,
        posterURL: URL? = nil,
        posterRequiresAuth: Bool = true
    ) -> QueueItem {
        QueueItem(
            id: "detail-lookup-\(source.rawValue)-\(entityId)",
            source: source,
            arrQueueId: 0,
            downloadId: nil,
            downloadProtocol: .unknown,
            downloadClient: nil,
            title: title,
            subtitle: nil,
            status: .unknown,
            progress: 0,
            sizeTotal: 0,
            sizeLeft: 0,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil,
            entityId: entityId,
            posterURL: posterURL,
            posterRequiresAuth: posterRequiresAuth
        )
    }

    /// Synthetic item that opens the Lidarr ARTIST surface instead of the
    /// album detail. Lidarr's addable/search entity is the artist, so both
    /// the in-library search tap and the post-add navigation carry an
    /// artist id — handing that to the album-shaped `DetailView` fetched
    /// `/album/{artistId}` and landed on an unrelated album. The marker
    /// lives in the synthetic `id` prefix (see `isLidarrArtistLookup`);
    /// real queue rows keep `lidarr-<queueId>` ids and are never artists.
    public static func syntheticArtistItem(
        artistId: Int,
        name: String,
        posterURL: URL? = nil,
        posterRequiresAuth: Bool = true
    ) -> QueueItem {
        QueueItem(
            id: "detail-lookup-lidarr-artist-\(artistId)",
            source: .lidarr,
            arrQueueId: 0,
            downloadId: nil,
            downloadProtocol: .unknown,
            downloadClient: nil,
            title: name,
            subtitle: nil,
            status: .unknown,
            progress: 0,
            sizeTotal: 0,
            sizeLeft: 0,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil,
            entityId: artistId,
            posterURL: posterURL,
            posterRequiresAuth: posterRequiresAuth
        )
    }

    public static func post(_ item: QueueItem) {
        NotificationCenter.default.post(name: .arrBarrOpenDetail, object: nil, userInfo: ["item": item])
    }

    /// Tap-router for a `SearchResult`. Owns the "is it in the
    /// library?" decision so individual call sites stop reimplementing
    /// the same `if let arrId = ... { detail } else { addPanel }`
    /// branch (Queue search row, chat result card, library card —
    /// all three had near-identical 8-line copies of this logic).
    ///
    /// In library → drill into DetailView via the arr-internal id.
    /// Not in library → open SearchAddPanel with the search result so
    /// the user gets the same hero card + form as the `+` flow.
    public static func tap(_ result: SearchResult) {
        if let arrId = result.inLibraryArrId {
            // Lidarr search results are ARTISTS (artist/lookup), so the
            // arr-internal id is an artist id — route to the artist view,
            // not the album-shaped DetailView.
            if result.source == .lidarr {
                post(syntheticArtistItem(
                    artistId: arrId,
                    name: result.title,
                    posterURL: result.posterURL,
                    posterRequiresAuth: false
                ))
                return
            }
            post(syntheticItem(
                source: result.source,
                entityId: arrId,
                title: result.title,
                posterURL: result.posterURL,
                // Library-side rows came through `fetchLibraryArrIdMap`
                // which doesn't require auth on poster URLs (they're
                // resolved against the arr's own image cache via
                // public CDN paths).
                posterRequiresAuth: false
            ))
        } else {
            SearchAddRequest.post(result)
        }
    }
}

public extension QueueItem {
    /// True for the synthetic "open Lidarr artist" items built by
    /// `DetailRequest.syntheticArtistItem`. `DetailView` branches on this to
    /// render the artist surface (album list) instead of treating `entityId`
    /// as an album id. Real queue rows carry `lidarr-<queueId>` ids, so the
    /// prefix can't collide.
    var isLidarrArtistLookup: Bool {
        source == .lidarr && id.hasPrefix("detail-lookup-lidarr-artist-")
    }
}

public extension Notification.Name {
    /// Posted when the user taps a missing search-result poster inside the
    /// chat. Popover/MainWindow listen and open the full `SearchAddPanel`
    /// overlay so the user gets the same rich add UI as the `+` flow.
    static let arrBarrOpenSearchAdd = Notification.Name("ArrBarrOpenSearchAdd")

    /// Posted by the `discover_in_quiz` chat tool. `userInfo["mood"]` is a
    /// non-empty String. PopoverContentView listens and opens the Discover
    /// overlay in quiz mode with the given mood pre-loaded.
    static let arrBarrOpenDiscoverQuiz = Notification.Name("ArrBarr.OpenDiscoverQuiz")
}

public enum SearchAddRequest {
    public static func post(_ result: SearchResult) {
        NotificationCenter.default.post(
            name: .arrBarrOpenSearchAdd,
            object: nil,
            userInfo: ["result": result]
        )
    }
}
