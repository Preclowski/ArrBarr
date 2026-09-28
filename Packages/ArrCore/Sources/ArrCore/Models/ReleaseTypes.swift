import Foundation
import MediaKit

nonisolated public extension ArrRelease {
    var qualityName: String? { quality?.name }
    var isTorrent: Bool { (`protocol` ?? "").caseInsensitiveCompare("torrent") == .orderedSame }
    var sizeBytes: Int64 { size ?? 0 }
    var isRejected: Bool { rejected == true && !(rejections ?? []).isEmpty }
    var protocolLabel: String { isTorrent ? "Torrent" : "NZB" }

    /// `.episodes` carries a formatted label ("E04", "E01–05"); `.pack` is localised by the view.
    enum Scope: Sendable, Equatable { case pack, episodes(String) }

    /// nil for a movie or a single episode.
    var scope: Scope? {
        if fullSeason == true { return .pack }
        let numbers = (episodeNumbers ?? []).sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        let start = String(format: "E%02d", first)
        return .episodes(first == last ? start : start + "–" + String(format: "%02d", last))
    }

    /// Drops the series name and `SxxExx`, both already on screen; raw title when
    /// the marker isn't where expected.
    var shortTitle: String {
        guard let marker = title.range(of: "[Ss][0-9]{1,3}([Ee][0-9]{1,4})*(-?[Ee][0-9]{1,4})*",
                                       options: .regularExpression) else { return title }
        let rest = title[marker.upperBound...].drop { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" }
        return rest.count >= 8 ? String(rest) : title
    }

    /// Prowlarr-synced indexers arrive as "NZBgeek (Prowlarr)"; the suffix is dropped.
    var indexerName: String? {
        guard let indexer, !indexer.isEmpty else { return nil }
        return ArrRelease.strippingProwlarrSuffix(indexer)
    }

    /// Fallback when Prowlarr can't be asked.
    static func strippingProwlarrSuffix(_ name: String) -> String {
        guard let suffix = name.range(of: " (Prowlarr)", options: [.caseInsensitive, .backwards, .anchored],
                                      range: name.index(name.endIndex, offsetBy: -min(11, name.count))..<name.endIndex)
        else { return name }
        return String(name[name.startIndex..<suffix.lowerBound])
    }

}

nonisolated public struct ManualSearchTarget: Identifiable, Hashable, Sendable {
    public let source: QueueItem.Source
    public let title: String
    public let release: ReleaseTarget

    public var id: String { "\(source.rawValue)-\(release)" }

    /// `/release` also returns per-episode releases, hence ReleaseListView's packs-only filter.
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
