import Foundation

/// One filesystem mount reported by an arr's `/diskspace` endpoint. Every arr
/// (Sonarr/Radarr/Lidarr/Whisparr, both API v1 and v3) serves the same shape,
/// so the shared `ArrAPIClient.fetchDiskSpace()` decodes straight into this.
public struct DiskSpace: Decodable, Equatable, Sendable, Identifiable {
    /// Mount path as the server sees it (e.g. "/data", "/movies").
    public let path: String
    /// Optional human label the arr attaches to the mount (often empty).
    public let label: String?
    public let freeSpace: Int64
    public let totalSpace: Int64

    public var id: String { path }

    /// Bytes in use — clamped at 0 so a server that reports free > total
    /// never yields a negative bar.
    public var usedSpace: Int64 { max(0, totalSpace - freeSpace) }

    /// Fraction of the mount in use, 0…1. Zero when the total is unknown so the
    /// bar renders empty rather than dividing by zero.
    public var usedFraction: Double {
        guard totalSpace > 0 else { return 0 }
        return min(1, max(0, Double(usedSpace) / Double(totalSpace)))
    }

    /// A mount is only worth showing once the server reported a real capacity.
    public var isMeaningful: Bool { totalSpace > 0 }

    public init(path: String, label: String? = nil, freeSpace: Int64, totalSpace: Int64) {
        self.path = path
        self.label = label
        self.freeSpace = freeSpace
        self.totalSpace = totalSpace
    }
}
