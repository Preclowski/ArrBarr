import Foundation

/// TMDB accepts two credentials and they are sent differently: the v4 "API
/// Read Access Token" is a JWT (`eyJ…`) that rides in an `Authorization:
/// Bearer` header, while the legacy v3 key is a hex string in an `api_key`
/// query parameter. Users paste whichever their TMDB page showed them.
///
/// One place decides, because getting it wrong is invisible until every call
/// 401s — which is exactly what happened the first time this provider met a
/// v4 token, while the app kept working on other providers' answers and said
/// nothing.
struct TMDBAuth: Sendable {
    let credential: String

    var isReadAccessToken: Bool {
        credential.hasPrefix("eyJ") || credential.split(separator: ".").count == 3
    }

    var isConfigured: Bool { !credential.isEmpty }

    /// A request for a TMDB path, authenticated the way this credential needs.
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")
        var items = query
        if !isReadAccessToken {
            items.append(URLQueryItem(name: "api_key", value: credential))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if isReadAccessToken {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
