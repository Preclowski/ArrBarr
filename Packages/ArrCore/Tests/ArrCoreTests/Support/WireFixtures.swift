import Foundation
import MediaKit

/// MediaKit's wire records only decode; tests build them the way the arr sends them.
extension ArrHealth {
    static func fixture(source: String? = nil, type: String?, message: String?, wikiUrl: String? = nil) -> ArrHealth {
        var json: [String: Any] = [:]
        json["source"] = source; json["type"] = type; json["message"] = message; json["wikiUrl"] = wikiUrl
        return try! JSONDecoder().decode(ArrHealth.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

/// TMDB answers in snake_case; MediaKit's TMDB records decode it the way `TMDBService` does.
let tmdbDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()
