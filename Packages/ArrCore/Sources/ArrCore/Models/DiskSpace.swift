import Foundation
import MediaKit

nonisolated extension ArrDiskSpace: @retroactive Identifiable {
    public var id: String { mountPath }
    public var mountPath: String { path ?? "" }
    public var free: Int64 { freeSpace ?? 0 }
    public var capacity: Int64 { totalSpace ?? 0 }

    /// Clamped at 0: a server can report free > total.
    public var usedSpace: Int64 { max(0, capacity - free) }

    public var usedFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(usedSpace) / Double(capacity)))
    }

    public var isMeaningful: Bool { capacity > 0 && path != nil }
}
