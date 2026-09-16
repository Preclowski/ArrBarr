public enum FreshnessClass: Int, Sendable, Codable, CaseIterable, Comparable {
    case volatile = 0
    case live = 1
    case warm = 2
    case reference = 3
    case archival = 4

    public var defaultTTL: Duration {
        switch self {
        case .volatile: .seconds(5)
        case .live: .seconds(60)
        case .warm: .seconds(600)
        case .reference: .seconds(6 * 3600)
        case .archival: .seconds(30 * 86_400)
        }
    }

    public var retention: Duration {
        switch self {
        case .volatile: .zero
        case .live: .seconds(86_400)
        case .warm: .seconds(7 * 86_400)
        case .reference: .seconds(30 * 86_400)
        case .archival: .seconds(180 * 86_400)
        }
    }

    public var persists: Bool { self != .volatile }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}
