import Foundation
import os

/// The app's on-disk caches: the retention sweep and the user's "clear artwork".
/// In-memory indexes and the Spotlight index are deliberately not here; Spotlight has its own button.
public enum AppCaches {
    private static let logger = Logger(category: "AppCaches")

    /// Once per launch; safe off the main actor.
    public static func purgeExpired() async {
        await PosterStore.shared.purge()
        // Never forces the gateway into existence; without one, `MediaStack.start` sweeps.
        await ServiceGateway.current?.sweepDataCache()
    }

    public static func artworkBytes() async -> Int64 {
        await PosterStore.shared.diskUsage()
    }

    /// All three tiers plus the URL-keyed tint colours, which would outlive their images.
    /// The icon tier goes too; the caller reindexes Spotlight to re-inline its thumbnails.
    public static func clearArtwork() async {
        await PosterStore.shared.clearAllTiers()
        PosterTint.resetCache()
        logger.notice("cleared the artwork cache on request")
    }
}
