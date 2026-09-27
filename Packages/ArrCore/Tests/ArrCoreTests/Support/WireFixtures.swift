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
