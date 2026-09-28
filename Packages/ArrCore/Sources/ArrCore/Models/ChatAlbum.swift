import Foundation
import MediaKit

/// Slim view shape instead of `ArrAlbum`: the rich payload must be `Equatable` because the message stream diffs on it.
nonisolated public struct ChatAlbum: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let year: Int?
    public let monitored: Bool
    public let trackFileCount: Int
    public let trackCount: Int
    public let images: [ArrImage]

    public init(id: Int, title: String, year: Int?,
                monitored: Bool, trackFileCount: Int, trackCount: Int, images: [ArrImage]) {
        self.id = id
        self.title = title
        self.year = year
        self.monitored = monitored
        self.trackFileCount = trackFileCount
        self.trackCount = trackCount
        self.images = images
    }

    public var isComplete: Bool { trackCount > 0 && trackFileCount >= trackCount }

    /// nil when Lidarr reports no track count (announced album), where "0/0" would be noise.
    public var trackProgress: String? {
        guard trackCount > 0 else { return nil }
        return "\(trackFileCount)/\(trackCount)"
    }
}
