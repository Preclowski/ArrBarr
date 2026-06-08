import Foundation

/// One arr's library headline: how many items and how many bytes on disk.
/// Pure value type so the summation logic is unit-testable without a network.
public struct LibrarySummary: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, CaseIterable, Identifiable {
        case radarr, sonarr, lidarr, whisparr
        public var id: String { rawValue }
    }

    public let source: Source
    public let count: Int
    public let totalBytes: Int64

    public var id: String { source.rawValue }

    public init(source: Source, count: Int, totalBytes: Int64) {
        self.source = source
        self.count = count
        self.totalBytes = totalBytes
    }

    public static func radarr(from recs: [RadarrLibraryRecord]) -> LibrarySummary {
        .init(source: .radarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) })
    }
    public static func whisparr(from recs: [WhisparrLibraryRecord]) -> LibrarySummary {
        .init(source: .whisparr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) })
    }
    public static func sonarr(from recs: [SonarrLibraryRecord]) -> LibrarySummary {
        .init(source: .sonarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.statistics?.sizeOnDisk ?? 0) })
    }
    public static func lidarr(from recs: [LidarrLibraryRecord]) -> LibrarySummary {
        .init(source: .lidarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.statistics?.sizeOnDisk ?? 0) })
    }
}
