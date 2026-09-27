import Foundation

public struct QueueCounts: Sendable, Equatable, Codable {
    public let total, count, unknown: Int
    public let errors, warnings: Bool
    public init(total: Int, count: Int, unknown: Int, errors: Bool, warnings: Bool) {
        self.total = total; self.count = count; self.unknown = unknown; self.errors = errors; self.warnings = warnings
    }
}

public enum DataEvent: Sendable, Equatable {
    case queueChanged(InstanceID)
    case queueStatus(InstanceID, QueueCounts)
    case fileImported(InstanceID, kind: MediaKind, entityID: Int?)
    case entityChanged(InstanceID, kind: MediaKind, entityID: Int?)
    case healthChanged(InstanceID)
    case calendarChanged(InstanceID)
    case commandFinished(InstanceID, name: String)
    case other(InstanceID, resource: String, action: String)

    public var instance: InstanceID {
        switch self {
        case let .queueChanged(i), let .queueStatus(i, _), let .fileImported(i, _, _), let .entityChanged(i, _, _),
             let .healthChanged(i), let .calendarChanged(i), let .commandFinished(i, _), let .other(i, _, _): i
        }
    }
}
