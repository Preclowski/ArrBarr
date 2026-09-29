import Foundation

/// Routes carried by `arrbarr://` deep links from widgets. Phase 1 only emits
/// `.library`; later phases add `.upcoming`, `.needs`, `.quiz`, `.quizAdd`.
nonisolated public enum WidgetDeepLink: Equatable, Sendable {
    case library, upcoming

    public static let scheme = "arrbarr"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "library": self = .library
        case "upcoming": self = .upcoming
        default: return nil
        }
    }

    public var url: URL {
        URL(string: "\(Self.scheme)://\(self == .library ? "library" : "upcoming")")!
    }
}
