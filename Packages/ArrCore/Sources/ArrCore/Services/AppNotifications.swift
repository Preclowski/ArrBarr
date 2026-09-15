import Foundation

/// The subject every in-app message is posted for; there is one bus, so observers watch the type.
public final class AppMessageBus: Sendable { private init() {} }

/// Typed messages between surfaces (a chat card, an intent, a deep-tree row) and the hosts that react to them:
/// the popover on macOS, the tab roots on iOS. Delivered asynchronously, observed with `onMessage`.
nonisolated public enum AppMessages {
    /// A result card in chat, a library tile or a queue search hit was tapped: the host pushes `DetailView`.
    /// The item is usually synthetic, carrying just what the detail needs to fetch the record.
    public struct OpenDetail: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let item: QueueItem
        public init(item: QueueItem) { self.item = item }
    }
    /// A deep-tree view needs a confirmation modal; the host renders it at panel width.
    public struct ConfirmRequest: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let payload: PendingConfirm
        public init(payload: PendingConfirm) { self.payload = payload }
    }
    /// A successful "Test Connection": the queue refreshes so a just-saved key clears its banner.
    public struct ConfigValidated: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public init() {}
    }
    /// Torrent/nzb files or a magnet link dropped on the panel or the detached window; the app opens the add window.
    public struct DropDownloads: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let urls: [URL]
        public init(urls: [URL]) { self.urls = urls }
    }
    /// The search-to-add intent or a chat link that resolved to nothing: run this query on the search surface.
    public struct SearchQuery: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let query: String
        public init(query: String) { self.query = query }
    }
    /// A not-in-library result was tapped or swiped right: open the add panel with it.
    public struct OpenSearchAdd: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let result: SearchResult
        public init(result: SearchResult) { self.result = result }
    }
    /// The `discover_in_quiz` tool or the resume card: open the quiz with these picks (`append` extends a live deck).
    public struct OpenDiscoverQuiz: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let mood: String
        public let items: [DiscoverItem]
        public let append: Bool
        public init(mood: String, items: [DiscoverItem], append: Bool) { self.mood = mood; self.items = items; self.append = append }
    }
    /// A person card in chat or an `arrbarr://person/…` link: push `PersonView`.
    public struct OpenPerson: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let ref: PersonRef
        public init(ref: PersonRef) { self.ref = ref }
    }
    /// A title was added to an arr; the quiz drops a card it was still offering.
    public struct DidAddToLibrary: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let foreignId: String
        public init(foreignId: String) { self.foreignId = foreignId }
    }

    public static func post<M: NotificationCenter.AsyncMessage>(_ message: M) where M.Subject == AppMessageBus {
        NotificationCenter.default.post(message)
    }
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

    public static func post(_ item: QueueItem) { AppMessages.post(AppMessages.OpenDetail(item: item)) }

    /// The one place that knows "a Lidarr ARTIST is not a Lidarr ALBUM".
    ///
    /// Lidarr's addable/search entity is the artist, so an artist id handed to
    /// the album-shaped `DetailView` fetched `/album/{artistId}` and landed on
    /// an unrelated record. Three call sites each carried their own copy of
    /// that branch; this is it, once.
    public static func open(source: QueueItem.Source, arrId: Int, title: String,
                            posterURL: URL? = nil, posterRequiresAuth: Bool = false,
                            isLidarrAlbum: Bool = false) {
        post(item(source: source, arrId: arrId, title: title, posterURL: posterURL,
                  posterRequiresAuth: posterRequiresAuth, isLidarrAlbum: isLidarrAlbum))
    }

    /// The item `open` posts, for hosts that push it themselves — the history
    /// list opens a title on its own navigation stack so Back returns to it.
    public static func item(source: QueueItem.Source, arrId: Int, title: String,
                            posterURL: URL? = nil, posterRequiresAuth: Bool = false,
                            isLidarrAlbum: Bool = false) -> QueueItem {
        if source == .lidarr, !isLidarrAlbum {
            return syntheticArtistItem(artistId: arrId, name: title,
                                       posterURL: posterURL,
                                       posterRequiresAuth: posterRequiresAuth)
        }
        return syntheticItem(source: source, entityId: arrId, title: title,
                             posterURL: posterURL,
                             posterRequiresAuth: posterRequiresAuth)
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
        guard let arrId = result.inLibraryArrId else {
            SearchAddRequest.post(result)
            return
        }
        // Library-side rows came through `fetchLibraryOwnership`, which
        // doesn't require auth on poster URLs (they resolve against the arr's
        // own image cache via public CDN paths).
        open(source: result.source, arrId: arrId, title: result.title,
             posterURL: result.posterURL, posterRequiresAuth: false,
             isLidarrAlbum: result.isLidarrAlbum)
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

public enum LibraryAddCompletion {
    public static func post(foreignId: String) {
        guard !foreignId.isEmpty else { return }
        AppMessages.post(AppMessages.DidAddToLibrary(foreignId: foreignId))
    }
}

public enum PersonRequest {
    public static func post(_ ref: PersonRef) { AppMessages.post(AppMessages.OpenPerson(ref: ref)) }
}

public enum SearchAddRequest {
    public static func post(_ result: SearchResult) { AppMessages.post(AppMessages.OpenSearchAdd(result: result)) }
}
