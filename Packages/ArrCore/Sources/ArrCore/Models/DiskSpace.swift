import Foundation
import MediaKit

nonisolated extension ArrDiskSpace: @retroactive Identifiable {
    public var id: String { mountPath }
    /// Mount path as the server sees it (e.g. "/data", "/movies").
    public var mountPath: String { path ?? "" }
    public var free: Int64 { freeSpace ?? 0 }
    public var capacity: Int64 { totalSpace ?? 0 }

    /// Bytes in use — clamped at 0 so a server that reports free > total
    /// never yields a negative bar.
    public var usedSpace: Int64 { max(0, capacity - free) }

    /// Fraction of the mount in use, 0…1; zero when the total is unknown.
    public var usedFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(usedSpace) / Double(capacity)))
    }

    /// A mount is only worth showing once the server reported a real capacity.
    public var isMeaningful: Bool { capacity > 0 && path != nil }
}
