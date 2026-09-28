import Foundation

enum RequestBuilder {
    /// Joins `baseURL` (which may carry a path prefix) with a template whose `{name}` segments come from `values`.
    static func url(base: URL, pathTemplate: String, values: [String: String], query: [(String, String)]) -> URL {
        var path = pathTemplate
        for (name, value) in values {
            path = path.replacingOccurrences(of: "{\(name)}", with: value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        components.percentEncodedQuery = query.isEmpty ? nil : formEncode(query)
        return components.url ?? base
    }

    /// RFC 3986 unreserved set, `+` and `/` escaped, keys in the caller's order.
    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func formEncode(_ fields: [String: String]) -> String {
        formEncode(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    static func urlRequest(from request: HTTPRequest) -> URLRequest {
        var out = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout.seconds)
        out.httpMethod = request.method
        for (name, value) in request.headers.dictionary { out.setValue(value, forHTTPHeaderField: name) }
        switch request.body {
        case .none: break
        case let .bytes(data, contentType):
            out.httpBody = data
            out.setValue(contentType, forHTTPHeaderField: "Content-Type")
        case let .form(fields):
            out.httpBody = Data(formEncode(fields).utf8)
            out.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case let .multipart(fields, file):
            let boundary = "MediaKit-\(UUID().uuidString)"
            out.httpBody = multipart(fields: fields, file: file, boundary: boundary)
            out.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        return out
    }

    static func multipart(fields: [String: String], file: HTTPRequest.FilePart?, boundary: String) -> Data {
        var data = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if let file {
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.contentType)\r\n\r\n")
            data.append(file.data)
            data.append("\r\n")
        }
        data.append("--\(boundary)--\r\n")
        return data
    }

    static func json<T: Encodable>(_ value: T) throws -> HTTPRequest.Body {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .bytes(try encoder.encode(value), contentType: "application/json")
    }

    static func jsonRPC(method: String, params: JSONValue, id: Int = 1) throws -> HTTPRequest.Body {
        try json(JSONRPCEnvelope(method: method, params: params, id: id))
    }

    /// The reason a server gave, in any of the three shapes the arr stack uses.
    static func serverMessage(from body: Data) -> String? {
        guard !body.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            let text = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<") ? nil : text
        }
        switch value {
        case let .array(items):
            let messages = items.compactMap { $0["errorMessage"]?.stringValue ?? $0["message"]?.stringValue }.filter { !$0.isEmpty }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        case let .object(object):
            // ASP.NET ProblemDetails: {"title": "...", "errors": {"field": ["...", ...]}}
            if case let .object(errors)? = object["errors"] {
                let messages = errors.keys.sorted().flatMap { key in errors[key]?.arrayValue?.compactMap(\.stringValue) ?? errors[key]?.stringValue.map { [$0] } ?? [] }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
            return ["errorMessage", "message", "error", "title", "detail"].lazy.compactMap { value[$0]?.stringValue }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case let .string(s): return s
        default: return nil
        }
    }
}

struct JSONRPCEnvelope: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue
    let id: Int
}

extension Data {
    fileprivate mutating func append(_ string: String) { append(Data(string.utf8)) }
}
