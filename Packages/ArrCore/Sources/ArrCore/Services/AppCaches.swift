import Foundation
import os

/// The app's on-disk caches, and the two things anyone ever wants to do to
/// them: sweep what has expired, and throw the artwork away on purpose.
///
/// It exists because "clear the cache" was scattered. The launch sweep was two
/// `Task.detached` calls copied into the macOS AppDelegate and again into the
/// iOS scene; the only user-facing clear lived under Siri & Shortcuts and
/// wiped the poster icon tier as a side effect of clearing the Spotlight
/// index, which nothing said out loud. Each new cache added another place to
/// remember.
///
/// What is NOT here, on purpose:
///
/// - **In-memory caches** (`CastProvider`, `PersonStore`, `SearchOptionsCache`,
///   `MediaServerIndex`). They die with the process and are rebuilt from the
///   network; a button for them would promise a fix it cannot deliver.
/// - **`TitleMetadataStore`'s records.** They are titles, years and slugs — an
///   answer that does not go stale, and re-fetching them costs one request per
///   queued title. Its *artwork* is no longer a reason to clear it either:
///   the media-server override is resolved at read time
///   (`Metadata.applyingMediaServerArtwork`), so connecting or switching a
///   server is reflected on the next poll.
/// - **The Spotlight index.** Clearing it is a distinct, user-visible act
///   ("stop ArrBarr appearing in Spotlight"), and it has its own button.
public enum AppCaches {
    private static let logger = Logger(category: "AppCaches")

    /// Retention sweep. Called once per launch on both platforms; safe to run
    /// off the main actor and cheap enough to fire and forget.
    public static func purgeExpired() async {
        await PosterStore.shared.purge()
        await TitleMetadataStore.shared.purge()
    }

    /// Bytes the poster store currently occupies, for the Settings row that
    /// offers to reclaim them. A number is what makes that button honest —
    /// "Clear" with nothing to clear should say so.
    public static func artworkBytes() async -> Int64 {
        await PosterStore.shared.diskUsage()
    }

    /// Throw away every cached poster.
    ///
    /// Covers all three tiers plus the derived tint colours, which are keyed by
    /// poster URL and would otherwise outlive the images they were sampled
    /// from. Everything here is re-downloadable: the cost of pressing this is
    /// bandwidth, never data.
    ///
    /// The icon tier goes too, even though it backs the Spotlight index — a
    /// half-cleared artwork cache is exactly the state that makes "I cleared it
    /// and the wrong poster is still there" true. Spotlight re-inlines its
    /// thumbnails on the next `SpotlightIndexer.reindex`, which the caller
    /// kicks.
    public static func clearArtwork() async {
        await PosterStore.shared.clearAllTiers()
        await PosterTint.resetCache()
        logger.notice("cleared the artwork cache on request")
    }
}
