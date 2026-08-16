import Foundation

/// One album as the chat renders it. A slim view-shape rather than the raw
/// `LidarrAlbumListRecord`: the rich payload needs `Equatable` (the whole
/// message stream diffs on it) and only wants the handful of fields a card
/// shows — everything else is one tap away in the album detail.
public struct ChatAlbum: Sendable, Equatable, Identifiable {
    /// Lidarr's album id — what a tap hands to the detail surface, and what
    /// `lidarr_monitor_album` takes.
    public let id: Int
    public let title: String
    public let year: Int?
    /// "Album" / "Single" / "EP" / "Live" / … as Lidarr reports it.
    public let albumType: String?
    public let monitored: Bool
    public let trackFileCount: Int
    public let trackCount: Int
    /// Cover art, resolved against the Lidarr base URL by the card (same path
    /// the library cards use, so authenticated covers work the same way).
    public let images: [ArrImage]

    public init(id: Int, title: String, year: Int?, albumType: String?,
                monitored: Bool, trackFileCount: Int, trackCount: Int, images: [ArrImage]) {
        self.id = id
        self.title = title
        self.year = year
        self.albumType = albumType
        self.monitored = monitored
        self.trackFileCount = trackFileCount
        self.trackCount = trackCount
        self.images = images
    }

    /// Every track on the album is on disk. Drives the same green check the
    /// movie cards use for "you have this".
    public var isComplete: Bool { trackCount > 0 && trackFileCount >= trackCount }

    /// "8/12" — nil when Lidarr reports no track count at all (an announced
    /// album with no known tracklist yet), where a "0/0" badge would be noise.
    public var trackProgress: String? {
        guard trackCount > 0 else { return nil }
        return "\(trackFileCount)/\(trackCount)"
    }
}
