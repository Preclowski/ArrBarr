import Foundation

enum AuthHeader {
    static func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}

/// Applies `plan.auth` from the credential material; services with a real session override `establish`.
struct HeaderAuthStrategy: SessionStrategy {
    init() {}

    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest {
        var out = request
        switch (plan.auth, credentials.material) {
        case let (.header(name), .apiKey(key)), let (.header(name), .token(key)):
            out.headers[name] = key
        case let (.bearer, .bearer(token)), let (.bearer, .apiKey(token)), let (.bearer, .token(token)):
            out.headers["Authorization"] = "Bearer \(token)"
        case let (.basic, .userPassword(user, password)):
            out.headers["Authorization"] = AuthHeader.basic(user, password)
        case let (.jellyfinMediaBrowser, .token(token)), let (.jellyfinMediaBrowser, .apiKey(token)):
            out.headers["Authorization"] = "MediaBrowser Token=\"\(token)\", Client=\"ArrBarr\", Device=\"ArrBarr\", DeviceId=\"arrbarr\", Version=\"1\""
        case let (.querySecret(name), .apiKey(key)), let (.querySecret(name), .token(key)):
            out.url = appending(query: (name, key), to: out.url)
        case (.session, _), (.none, _), (_, .none):
            break
        default:
            break
        }
        return out
    }

    func rejection(for response: HTTPResponse) -> SessionRejection? {
        response.status == 401 || response.status == 403 ? .unauthenticated : nil
    }

    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? { nil }

    func appending(query: (String, String), to url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let encoded = "\(RequestBuilder.escape(query.0))=\(RequestBuilder.escape(query.1))"
        c.percentEncodedQuery = [c.percentEncodedQuery, encoded].compactMap { $0 }.joined(separator: "&")
        return c.url ?? url
    }
}

struct SABnzbdStrategy: SessionStrategy {
    private let base = HeaderAuthStrategy()
    init() {}
    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest {
        var p = plan
        p.auth = .querySecret("apikey")
        return try base.authorize(request, plan: p, credentials: credentials, session: session)
    }
    func rejection(for response: HTTPResponse) -> SessionRejection? {
        guard response.status == 200, let v = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              v["status"]?.boolValue == false, v["error"]?.stringValue?.localizedCaseInsensitiveContains("api key") == true else {
            return response.status == 401 || response.status == 403 ? .unauthenticated : nil
        }
        return .unauthenticated
    }
    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? { nil }
}

/// Cookie jar lives in the instance's URLSession; `Referer` is required by qBittorrent's CSRF check.
struct QBittorrentStrategy: SessionStrategy {
    private let base = HeaderAuthStrategy()
    init() {}

    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest {
        var out = request
        out.headers["Referer"] = credentials.baseURL.absoluteString
        if case .apiKey = credentials.material {
            var p = plan
            p.auth = .bearer
            return try base.authorize(out, plan: p, credentials: credentials, session: session)
        }
        return out
    }

    func rejection(for response: HTTPResponse) -> SessionRejection? {
        response.status == 401 || response.status == 403 ? .unauthenticated : nil
    }

    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? {
        guard case let .userPassword(user, password) = credentials.material else { return nil }
        var login = HTTPRequest(method: "POST",
                                url: RequestBuilder.url(base: credentials.baseURL, pathTemplate: "/api/v2/auth/login", values: [:], query: []),
                                body: .form(["username": user, "password": password]),
                                operation: OperationID(.qbittorrent, "login"), pathTemplate: "/api/v2/auth/login")
        login.headers["Referer"] = credentials.baseURL.absoluteString
        let response = try await send(login)
        guard response.isSuccess, String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Ok." else {
            throw MediaKitError.unauthorized(InstanceID(.qbittorrent), status: response.status, serverMessage: RequestBuilder.serverMessage(from: response.body))
        }
        return SessionToken()
    }
}

struct TransmissionStrategy: SessionStrategy {
    init() {}

    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest {
        var out = request
        if case let .userPassword(user, password) = credentials.material, !user.isEmpty {
            out.headers["Authorization"] = AuthHeader.basic(user, password)
        }
        return out
    }

    func rejection(for response: HTTPResponse) -> SessionRejection? {
        if response.status == 409, let id = response.headers["X-Transmission-Session-Id"] {
            return .handshake(header: "X-Transmission-Session-Id", value: id)
        }
        return response.status == 401 || response.status == 403 ? .unauthenticated : nil
    }

    /// The token is the rejection's header value; no request is made.
    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? {
        guard case let .handshake(header, value)? = rejection else { return nil }
        var headers = HTTPHeaders()
        headers[header] = value
        return SessionToken(headers: headers)
    }
}

struct DelugeStrategy: SessionStrategy {
    init() {}

    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest { request }

    func rejection(for response: HTTPResponse) -> SessionRejection? {
        if response.status == 401 || response.status == 403 { return .unauthenticated }
        guard response.status == 200, let v = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { return nil }
        if let message = v["error"]?["message"]?.stringValue, message.localizedCaseInsensitiveContains("not authenticated") { return .unauthenticated }
        return nil
    }

    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? {
        let password: String
        switch credentials.material {
        case let .userPassword(_, p): password = p
        case let .apiKey(p), let .token(p), let .bearer(p): password = p
        case .none: return nil
        }
        let login = HTTPRequest(method: "POST",
                                url: RequestBuilder.url(base: credentials.baseURL, pathTemplate: "/json", values: [:], query: []),
                                body: try RequestBuilder.jsonRPC(method: "auth.login", params: .array([.string(password)])),
                                operation: OperationID(.deluge, "login"), pathTemplate: "/json", rpcMethod: "auth.login")
        let response = try await send(login)
        let v = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        guard response.isSuccess, v?["result"]?.boolValue == true else {
            throw MediaKitError.unauthorized(InstanceID(.deluge), status: response.status, serverMessage: v?["error"]?["message"]?.stringValue)
        }
        return SessionToken()
    }
}

/// v4 read access tokens go in the Authorization header; a v3 key is the second sanctioned query secret.
struct TMDBStrategy: SessionStrategy {
    private let base = HeaderAuthStrategy()
    init() {}
    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest {
        var p = plan
        if case let .apiKey(key) = credentials.material, !TMDBService.isReadAccessToken(key) { p.auth = .querySecret("api_key") } else { p.auth = .bearer }
        return try base.authorize(request, plan: p, credentials: credentials, session: session)
    }
    func rejection(for response: HTTPResponse) -> SessionRejection? { response.status == 401 ? .unauthenticated : nil }
    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken? { nil }
}

enum SessionStrategies {
    static let standard: [InstanceKind: any SessionStrategy] = {
        var table: [InstanceKind: any SessionStrategy] = [:]
        for kind in InstanceKind.allCases { table[kind] = HeaderAuthStrategy() }
        table[.sabnzbd] = SABnzbdStrategy()
        table[.qbittorrent] = QBittorrentStrategy()
        table[.transmission] = TransmissionStrategy()
        table[.deluge] = DelugeStrategy()
        table[.tmdb] = TMDBStrategy()
        return table
    }()
}
