import Foundation

/// An in-app link the assistant can write: `[Sicario](arrbarr://media/tmdb:68718)`,
/// `[Adam Sandler](arrbarr://person/19292)`. Strict parsing: an invented scheme never becomes a link.
nonisolated enum ChatLink: Equatable, Sendable {
    case media(MediaRef)
    /// `name` comes from the link text, so `PersonView` can show it while TMDB details load.
    case person(id: Int, name: String)

    static let scheme = "arrbarr"

    init?(url: URL) {
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

    var verificationKey: String {
        switch self {
        case .media(let ref):  return ref.urlString.lowercased()
        case .person(let id, _): return "person:\(id)"
        }
    }

    var url: URL? {
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
