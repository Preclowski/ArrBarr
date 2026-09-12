import Foundation

/// Turns the id you have into the id a provider needs.
///
/// The one crossing that matters today: a TMDB **series** id into a TVDB id,
/// because Sonarr can only be asked in TVDB terms and nothing else in the app
/// speaks them. It goes through TMDB's own `external_ids`, which is a stated
/// mapping rather than a title guess — the difference between a resolution
/// and a coincidence.
///
/// Resolutions are cached for the session: they are stable (a show's TVDB id
/// does not change) and each one is a network call that would otherwise
/// repeat per poster.
public actor TMDBIdentityResolver: IdentityResolving {
    public let id = ProviderID.tmdbIDs

    private let auth: TMDBAuth
    private let transport: HTTPTransport
    private let telemetry: MediaTelemetry?
    private var resolved: [String: MediaID] = [:]
    /// Crossings we asked about and TMDB had no answer for. Kept so the same
    /// hopeless lookup is not retried once per card — cleared with the rest
    /// on `reset()`.
    private var unresolvable: Set<String> = []

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport(),
                telemetry: MediaTelemetry? = nil) {
        self.auth = TMDBAuth(credential: apiKey)
        self.transport = transport
        self.telemetry = telemetry
    }

    public func resolve(_ identity: MediaIdentity,
                        into namespace: MediaID.Namespace) async throws -> MediaID? {
        guard auth.isConfigured else { return nil }
        if let existing = identity.id(in: namespace) { return existing }
        // Only the crossing we can actually prove.
        guard namespace == .tvdb, identity.kind == .series,
              let tmdbID = identity.tmdbID else { return nil }

        let key = "tv/\(tmdbID)→tvdb"
        if let hit = resolved[key] {
            await telemetry?.record(.init(kind: .cacheHit, provider: id,
                                          identity: identity.cacheKey, fields: [],
                                          note: "id resolution"))
            return hit
        }
        if unresolvable.contains(key) { return nil }

        guard let request = auth.request(path: "/tv/\(tmdbID)/external_ids") else { return nil }

        struct ExternalIDs: Decodable {
            let tvdbId: Int?
            enum CodingKeys: String, CodingKey { case tvdbId = "tvdb_id" }
        }
        await telemetry?.record(.init(kind: .request, provider: id,
                                      identity: identity.cacheKey, fields: [],
                                      note: "id resolution"))
        let started = Date()
        let response = try await transport.send(request)
        await telemetry?.record(.init(kind: .response, provider: id,
                                      identity: identity.cacheKey, fields: [],
                                      duration: Date().timeIntervalSince(started),
                                      bytes: response.data.count,
                                      note: "id resolution"))
        guard response.isSuccess,
              let ids = try? JSONDecoder().decode(ExternalIDs.self, from: response.data),
              let tvdb = ids.tvdbId, tvdb > 0 else {
            unresolvable.insert(key)
            return nil
        }
        let value = MediaID.tvdb(tvdb)
        resolved[key] = value
        return value
    }

    public func reset() {
        resolved.removeAll()
        unresolvable.removeAll()
    }
}
