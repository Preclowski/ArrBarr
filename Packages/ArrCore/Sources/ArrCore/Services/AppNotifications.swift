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

public extension Notification.Name {
    /// Posted when the user taps a missing search-result poster inside the
    /// chat. Popover/MainWindow listen and open the full `SearchAddPanel`
    /// overlay so the user gets the same rich add UI as the `+` flow.
    static let arrBarrOpenSearchAdd = Notification.Name("ArrBarrOpenSearchAdd")
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
