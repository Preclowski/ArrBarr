import Foundation

/// Routes carried by `arrbarr://` deep links from widgets. Phase 1 only emits
/// `.library`; later phases add `.upcoming`, `.needs`, `.quiz`, `.quizAdd`.
public enum WidgetDeepLink: Equatable, Sendable {
    case library

    public static let scheme = "arrbarr"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "library": self = .library
        default: return nil
        }
    }
}
