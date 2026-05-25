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
    /// Build a synthetic `QueueItem` suitable for handing to `DetailView` —
    /// only `source`, `title`, `entityId`, and `posterURL` matter; everything
    /// else is placeholder. The detail screen refetches by `entityId`.
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
}

public extension Notification.Name {
    /// Posted when the user taps a missing search-result poster inside the
    /// chat. Popover/MainWindow listen and open the full `SearchAddPanel`
    /// overlay so the user gets the same rich add UI as the `+` flow.
    static let arrBarrOpenSearchAdd = Notification.Name("ArrBarrOpenSearchAdd")

    /// Posted by the `discover_in_tinder` chat tool. `userInfo["mood"]` is a
    /// non-empty String. PopoverContentView listens and switches to the
    /// Discover tab in tinder mode with the given mood pre-loaded.
    static let arrBarrOpenDiscoverInTinder = Notification.Name("ArrBarr.OpenDiscoverInTinder")
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
