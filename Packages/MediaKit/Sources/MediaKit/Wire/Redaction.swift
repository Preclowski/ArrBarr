import Foundation

/// One registry the log sink and the recorder consult before anything leaves the process.
public struct Redaction: Sendable {
    public let headerNames: Set<String>
    public let queryItems: Set<String>
    public let formFields: Set<String>
    public let rpcMethods: Set<String>

    public static let standard = Redaction(
        headerNames: ["x-api-key", "x-plex-token", "x-emby-token", "authorization", "cookie", "set-cookie", "x-transmission-session-id"],
        queryItems: ["apikey", "api_key", "access_token"],
        formFields: ["username", "password"],
        rpcMethods: ["auth.login"]
    )

    public func loggableURL(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        var out = "\(c.scheme ?? "http")://\(c.host ?? "")"
        if let port = c.port { out += ":\(port)" }
        return out + c.path
    }

    public func scrub(_ request: HTTPRequest) -> HTTPRequest {
        var out = request
        for name in request.headers.names where headerNames.contains(name.lowercased()) { out.headers[name] = "<redacted>" }
        if var c = URLComponents(url: request.url, resolvingAgainstBaseURL: false), let items = c.queryItems {
            c.queryItems = items.map { queryItems.contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: "<redacted>") : $0 }
            out.url = c.url ?? request.url
        }
        switch request.body {
        case let .form(fields):
            out.body = .form(fields.mapValuesWithKey { formFields.contains($0.lowercased()) ? "<redacted>" : $1 })
        case let .multipart(fields, file):
            out.body = .multipart(fields: fields.mapValuesWithKey { formFields.contains($0.lowercased()) ? "<redacted>" : $1 }, file: file)
        case let .bytes(data, contentType):
            out.body = .bytes(scrub(data, contentType: contentType, rpcMethod: request.rpcMethod), contentType: contentType)
        case .none: break
        }
        return out
    }

    public func scrub(_ body: Data, contentType: String, rpcMethod: String? = nil) -> Data {
        guard contentType.contains("json"), let method = rpcMethod, rpcMethods.contains(method),
              case var .object(o)? = try? JSONDecoder().decode(JSONValue.self, from: body) else { return body }
        o["params"] = .array([.string("<redacted>")])
        return (try? JSONEncoder().encode(JSONValue.object(o))) ?? body
    }
}

extension Dictionary where Key == String, Value == String {
    fileprivate func mapValuesWithKey(_ f: (String, String) -> String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in self { out[k] = f(k, v) }
        return out
    }
}
