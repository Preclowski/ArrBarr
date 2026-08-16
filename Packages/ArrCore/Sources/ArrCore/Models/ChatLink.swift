import Foundation

/// An in-app link the assistant can write into its prose: a title or a person
/// that opens the matching surface instead of a browser tab.
///
/// Wire form (what the model is told to emit, and all it is allowed to emit):
///
///   [Sicario](arrbarr://media/tmdb:68718)
///   [Blade Runner](arrbarr://media/imdb:tt0083658)
///   [Adam Sandler](arrbarr://person/19292)
///
/// Parsing is strict on purpose. A model that invents an id is a fact-shaped
/// mistake we cannot catch, but a model that invents a *scheme* is one we can:
/// anything that doesn't parse here never becomes a tappable link, and anything
/// that does is handed to the same routers the rest of the app uses, so a bad id
/// fails as a normal "not found", not as a crash or a random surface.
public enum ChatLink: Equatable, Sendable {
    case media(MediaRef)
    /// `name` comes from the link's own text — `PersonView` shows it in the
    /// header while TMDB details load, so a link reads correctly the instant
    /// it's tapped.
    case person(id: Int, name: String)

    public static let scheme = "arrbarr"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        // "arrbarr://media/tmdb:68718" → host "media", one path component.
        let value = url.pathComponents.filter { $0 != "/" }.first ?? ""
        guard !value.isEmpty else { return nil }
        switch url.host {
        case "media":
            guard let ref = MediaRef(urlString: value) else { return nil }
            self = .media(ref)
        case "person":
            guard let id = Int(value), id > 0 else { return nil }
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value ?? ""
            self = .person(id: id, name: name)
        default:
            return nil
        }
    }

    /// Identity used to check a link against what the tools actually returned.
    var verificationKey: String {
        switch self {
        case .media(let ref):  return ref.urlString.lowercased()
        case .person(let id, _): return "person:\(id)"
        }
    }

    /// The URL form, used by the tests and by `MarkdownMessage` when it stamps a
    /// person link with the text the model wrote for it.
    public var url: URL? {
        switch self {
        case .media(let ref):
            return URL(string: "\(Self.scheme)://media/\(ref.urlString)")
        case .person(let id, let name):
            var c = URLComponents()
            c.scheme = Self.scheme
            c.host = "person"
            c.path = "/\(id)"
            if !name.isEmpty { c.queryItems = [URLQueryItem(name: "name", value: name)] }
            return c.url
        }
    }
}
