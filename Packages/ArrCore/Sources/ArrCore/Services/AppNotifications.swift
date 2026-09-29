import Foundation
import os

/// The subject every in-app message is posted for; there is one bus, so observers watch the type.
public final class AppMessageBus: Sendable { private init() {} }

/// Typed messages between surfaces (a chat card, an intent, a deep-tree row) and the hosts that react to them:
/// the popover on macOS, the tab roots on iOS. Delivered asynchronously, observed with `onMessage`.
nonisolated public enum AppMessages {
    /// A successful "Test Connection": the queue refreshes so a just-saved key clears its banner.
    public struct ConfigValidated: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public init() {}
    }
    /// The media server index now maps titles to different posters; rows composed before it hold the arr's artwork.
    public struct MediaServerArtworkChanged: NotificationCenter.AsyncMessage {
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
    /// The `discover_in_quiz` tool or the resume card: open the quiz with these picks (`append` extends a live deck).
    public struct OpenDiscoverQuiz: NotificationCenter.AsyncMessage {
        public typealias Subject = AppMessageBus
        public let items: [DiscoverItem]
        public let append: Bool
        public init(items: [DiscoverItem], append: Bool) { self.items = items; self.append = append }
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
        let center = NotificationCenter.default
        center.post(message)
    }
}

public enum DetailRequest {
    /// `entityId` is the arr-internal record id, not the TMDB/TVDB/MBID. Season and
    /// episode numbers make it an episode lookup.
    public static func syntheticItem(
        source: QueueItem.Source,
        entityId: Int,
        title: String,
        posterURL: URL? = nil,
        posterRequiresAuth: Bool = true,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) -> QueueItem {
        QueueItem(
            id: "detail-lookup-\(source.rawValue)-\(entityId)"
                + (episodeNumber.map { "-s\(seasonNumber ?? 0)e\($0)" } ?? ""),
            source: source,
            arrQueueId: 0,
            downloadId: nil,
            downloadProtocol: .unknown,
            downloadClient: nil,
            title: title,
            subtitle: nil,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
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

    /// Opens the Lidarr ARTIST surface; the marker lives in the synthetic `id`
    /// prefix (see `isLidarrArtistLookup`).
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

    private static let log = Logger(category: "Detail")

    public static func post(_ item: QueueItem, intent: DetailIntent? = nil) {
        log.notice("open detail: \(item.source.rawValue, privacy: .public) #\(item.entityId ?? 0, privacy: .public) \(intent.map { "\($0)" } ?? "", privacy: .public)")
        DetailRouter.shared.open(item, intent: intent)
    }

    /// Lidarr's search entity is the artist; handing its id to the album-shaped
    /// `DetailView` fetches `/album/{artistId}`, an unrelated record.
    public static func open(source: QueueItem.Source, arrId: Int, title: String,
                            posterURL: URL? = nil, posterRequiresAuth: Bool = false,
                            isLidarrAlbum: Bool = false) {
        post(item(source: source, arrId: arrId, title: title, posterURL: posterURL,
                  posterRequiresAuth: posterRequiresAuth, isLidarrAlbum: isLidarrAlbum))
    }

    /// For hosts that push the item themselves, so Back returns to them.
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

    /// In library → DetailView via the arr-internal id; otherwise SearchAddPanel.
    public static func tap(_ result: SearchResult, addOrigin: SearchAddRouter.Origin = .search) {
        guard let arrId = result.inLibraryArrId else {
            SearchAddRequest.post(result, origin: addOrigin)
            return
        }
        open(source: result.source, arrId: arrId, title: result.title,
             posterURL: result.posterURL, posterRequiresAuth: false,
             isLidarrAlbum: result.isLidarrAlbum)
    }
}

public extension QueueItem {
    /// Real queue rows carry `lidarr-<queueId>` ids, so the prefix can't collide.
    var isLidarrArtistLookup: Bool {
        source == .lidarr && id.hasPrefix("detail-lookup-lidarr-artist-")
    }
}

enum LibraryAddCompletion {
    static func post(foreignId: String) {
        guard !foreignId.isEmpty else { return }
        AppMessages.post(AppMessages.DidAddToLibrary(foreignId: foreignId))
    }
}

enum PersonRequest {
    static func post(_ ref: PersonRef) { AppMessages.post(AppMessages.OpenPerson(ref: ref)) }
}

enum SearchAddRequest {
    static func post(_ result: SearchResult, origin: SearchAddRouter.Origin = .search) {
        SearchAddRouter.shared.open(result, origin: origin)
    }
}
