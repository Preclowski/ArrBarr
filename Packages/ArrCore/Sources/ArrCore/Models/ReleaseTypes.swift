import Foundation
import MediaKit

/// Row-level answers the manual-search list needs from a release: what the
/// file covers and what to print as its name.
nonisolated public extension ArrRelease {
    var qualityName: String? { quality?.name }
    var isTorrent: Bool { (`protocol` ?? "").caseInsensitiveCompare("torrent") == .orderedSame }
    var sizeBytes: Int64 { size ?? 0 }
    var isRejected: Bool { rejected == true && !(rejections ?? []).isEmpty }
    /// Short protocol badge text — "Torrent" / "NZB".
    var protocolLabel: String { isTorrent ? "Torrent" : "NZB" }

    /// What one release covers. `.episodes` carries its own already-formatted
    /// label ("E04", "E01–05"); `.pack` is localised by the view.
    enum Scope: Sendable, Equatable { case pack, episodes(String) }

    /// nil when the search has no such axis — a movie, or a single episode.
    var scope: Scope? {
        if fullSeason == true { return .pack }
        let numbers = (episodeNumbers ?? []).sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        let start = String(format: "E%02d", first)
        return .episodes(first == last ? start : start + "–" + String(format: "%02d", last))
    }

    /// The release name minus the leading series name and `SxxExx` marker —
    /// both already on screen (the header and the scope badge), and both
    /// eating the width where the tokens that actually differ live. Falls back
    /// to the raw title whenever the marker isn't where we expect it.
    var shortTitle: String {
        guard let marker = title.range(of: "[Ss][0-9]{1,3}([Ee][0-9]{1,4})*(-?[Ee][0-9]{1,4})*",
                                       options: .regularExpression) else { return title }
        let rest = title[marker.upperBound...].drop { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" }
        return rest.count >= 8 ? String(rest) : title
    }

    /// The indexer's name as a human would say it. Indexers synced from
    /// Prowlarr arrive in the *arr named "NZBgeek (Prowlarr)" — the suffix says
    /// how the *arr learned about it, which is nobody's business on a button.
    var indexerName: String? {
        guard let indexer, !indexer.isEmpty else { return nil }
        return ArrRelease.strippingProwlarrSuffix(indexer)
    }

    /// The fallback spelling when Prowlarr can't be asked: the *arr's label
    /// without the one suffix we can remove without guessing.
    static func strippingProwlarrSuffix(_ name: String) -> String {
        guard let suffix = name.range(of: " (Prowlarr)", options: [.caseInsensitive, .backwards, .anchored],
                                      range: name.index(name.endIndex, offsetBy: -min(11, name.count))..<name.endIndex)
        else { return name }
        return String(name[name.startIndex..<suffix.lowerBound])
    }

}

/// Identifies what to run a manual search for: `source` picks the arr client,
/// `release` is the `/release` query.
nonisolated public struct ManualSearchTarget: Identifiable, Hashable, Sendable {
    public let source: QueueItem.Source
    public let title: String
    public let release: ReleaseTarget

    public var id: String { "\(source.rawValue)-\(release)" }

    /// The searched season, for a whole-season search. The same `/release`
    /// endpoint also returns per-episode releases, so ReleaseListView offers a
    /// packs-only filter for these.
    public var season: Int? {
        if case let .season(_, season) = release { return season }
        return nil
    }
    public var isSeasonSearch: Bool { season != nil }

    public static func movie(source: QueueItem.Source, movieId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: source, title: title, release: .movie(movieId))
    }
    public static func episode(episodeId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .sonarr, title: title, release: .episode(episodeId))
    }
    public static func album(albumId: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .lidarr, title: title, release: .album(albumId))
    }
    public static func season(seriesId: Int, seasonNumber: Int, title: String) -> ManualSearchTarget {
        ManualSearchTarget(source: .sonarr, title: title, release: .season(seriesID: seriesId, season: seasonNumber))
    }
}
