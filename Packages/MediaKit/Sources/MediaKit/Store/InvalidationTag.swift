public enum CollectionName: String, Sendable, Codable, CaseIterable {
    case queue, calendar, history, library, health, profiles, commands, sessions, downloads, lookup, status
}

public struct InvalidationTag: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static func instance(_ id: InstanceID) -> Self { .init(rawValue: "i:\(id)") }
    public static func collection(_ c: CollectionName, _ id: InstanceID) -> Self { .init(rawValue: "c:\(c.rawValue)@\(id)") }
    public static func entity(_ id: InstanceID, _ kind: MediaKind, _ entityID: Int) -> Self { .init(rawValue: "e:\(kind.rawValue)/\(id)/\(entityID)") }
    public static func identity(_ id: MediaID) -> Self { .init(rawValue: "x:\(id)") }
    public static func capabilities(_ id: InstanceID) -> Self { .init(rawValue: "k:\(id)") }

    public var description: String { rawValue }

    /// The instance the tag names; identity tags span instances and name none.
    var instance: InstanceID? {
        let body = rawValue.drop { $0 != ":" }.dropFirst()
        let id: Substring? = switch rawValue.prefix(2) {
        case "i:", "k:": body
        case "c:": body.split(separator: "@", maxSplits: 1).last
        case "e:": body.split(separator: "/").dropFirst().first
        default: nil
        }
        guard let parts = id?.split(separator: "#"), parts.count == 2,
              let kind = InstanceKind(rawValue: String(parts[0])), let ordinal = Int(parts[1]) else { return nil }
        return InstanceID(kind, ordinal: ordinal)
    }
}
