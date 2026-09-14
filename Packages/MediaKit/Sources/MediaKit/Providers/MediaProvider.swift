import Foundation

/// A provider's stable name. String-backed so it survives in caches, logs and
/// the debug report; the well-known ones are constants so call sites don't
/// spell them differently.
public struct ProviderID: Hashable, Sendable, Codable, CustomStringConvertible,
                          ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }

    public static let tmdb = ProviderID("tmdb")
    public static let radarr = ProviderID("radarr")
    public static let sonarr = ProviderID("sonarr")
    public static let plex = ProviderID("plex")
    public static let jellyfin = ProviderID("jellyfin")
    public static let cache = ProviderID("cache")
    /// Id cross-walks are counted apart from field traffic: they are a
    /// different question, and mixing them made every resolved series look
    /// like a repeated fetch.
    public static let tmdbIDs = ProviderID("tmdb-ids")
}

/// What a call to this provider costs. The planner prefers cheap sources for
/// fields several providers can answer — "just the title" of a library title
/// should never leave the house.
public enum ProviderCost: Int, Hashable, Sendable, Comparable, Codable {
    /// Already in memory or on disk.
    case free = 0
    /// A box on the LAN: fast, unmetered, and it is the user's own hardware.
    case local = 1
    /// A configured internet service the user pays nothing per call for.
    case remote = 2
    /// Rate-limited or quota-bearing — used only when nobody cheaper can answer.
    case metered = 3

    public static func < (lhs: ProviderCost, rhs: ProviderCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ProviderHealth: String, Hashable, Sendable, Codable {
    case unknown
    case healthy
    /// Answered badly or slowly often enough to be deprioritised. The planner
    /// still tries it when it is the only source for a field.
    case degraded
    case down
}

/// One source of media facts.
///
/// A provider declares what it can answer; it never decides what a screen
/// needs. Everything is injected — credentials, transport, clock — so a test
/// builds a graph out of fakes and no provider reaches for a singleton.
public protocol MediaProvider: Sendable {
    var id: ProviderID { get }
    /// The fields this provider can answer, at best. The planner intersects
    /// this with what was asked for.
    var supplies: MediaFieldSet { get }
    var cost: ProviderCost { get }
    /// Credentials present and the service switched on. A provider that is
    /// not configured is skipped silently — that is a normal state, not an
    /// error the user should see.
    var isConfigured: Bool { get }
    var health: ProviderHealth { get }

    /// Id namespaces this provider can be asked in. Empty means "anything
    /// with a TMDB id will do". Sonarr, for instance, can only be asked about
    /// a TVDB id — a TMDB *series* id names a different show to it — so the
    /// graph must resolve one first or skip the provider.
    var requiredIDs: Set<MediaID.Namespace> { get }

    /// Whether this provider answers a whole page's worth of titles without a
    /// request per title — because it holds an index in memory, or because it
    /// is the app's own state.
    ///
    /// The planner fans a page out only across these. Cost is not enough of a
    /// signal: Radarr is `.local` and still does one HTTP lookup per title, so
    /// enriching a 20-card grid with it meant twenty concurrent calls to a box
    /// that then rate-limited and timed out — the exact waste this layer is
    /// supposed to prevent, committed by the layer itself.
    var answersFromIndex: Bool { get }

    /// Whether this provider can be asked about this title as it stands —
    /// the right id space AND the right kind (Radarr has nothing to say about
    /// a series). A protocol REQUIREMENT, not just an extension default:
    /// through `any MediaProvider` an extension-only method dispatches
    /// statically, and every override would be silently ignored.
    func canAnswer(_ identity: MediaIdentity) -> Bool

    /// How much this provider's answer is worth for a given field, higher
    /// first. Precedence is declared PER FIELD, not per provider, because the
    /// same source is authoritative for one thing and a poor guess for
    /// another: the media server knows what you watched, TMDB knows what the
    /// film is called, and neither should overwrite the other.
    func precedence(for field: MediaField) -> Int

    /// Answer as much of `fields` as this provider can for one title.
    /// Providers return what they have; they do not throw for fields they
    /// simply don't know. Throwing means the *call* failed.
    func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment
}

public extension MediaProvider {
    var health: ProviderHealth { .unknown }

    var requiredIDs: Set<MediaID.Namespace> { [] }

    var answersFromIndex: Bool { false }

    func precedence(for field: MediaField) -> Int { 0 }

    func canAnswer(_ identity: MediaIdentity) -> Bool {
        requiredIDs.isEmpty || requiredIDs.contains { identity.id(in: $0) != nil }
    }

    /// Fields worth asking this provider for, given a request.
    func answerable(_ fields: MediaFieldSet) -> MediaFieldSet {
        isConfigured ? fields.intersection(supplies) : []
    }
}

/// Providers that can answer for many titles in one call — a poster grid is
/// one arr call and one server call, not two hundred.
public protocol BatchMediaProvider: MediaProvider {
    func fetch(_ identities: [MediaIdentity],
               fields: MediaFieldSet) async throws -> [MediaIdentity: MediaFragment]
}

/// Turns one id into more ids (tvdb ↔ tmdb, title+year → tmdb). Separate from
/// `MediaProvider` because resolution is a different question with a different
/// failure mode: a wrong id is worse than a missing field, so a resolver may
/// say how sure it is and the planner may refuse a weak match.
public protocol IdentityResolving: Sendable {
    var id: ProviderID { get }
    func resolve(_ identity: MediaIdentity,
                 into namespace: MediaID.Namespace) async throws -> MediaID?
}

/// Credentials come from the app, never from inside this package: TonightBarr
/// has no Keychain (ad-hoc signing) and ArrBarr has its own `SecretStore`.
/// MediaKit takes what it is handed and reads nothing off disk.
public protocol CredentialsProviding: Sendable {
    func credentials(for provider: ProviderID) async -> ProviderCredentials?
}

public struct ProviderCredentials: Hashable, Sendable {
    public var baseURL: URL?
    public var apiKey: String?
    public var username: String?
    public var password: String?
    public var region: String?

    public init(baseURL: URL? = nil, apiKey: String? = nil, username: String? = nil,
                password: String? = nil, region: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.username = username
        self.password = password
        self.region = region
    }

    /// "Is this still the same server?" — the cache key suffix. The key's
    /// LENGTH stands in for the key so a secret never lands in a cache dump
    /// or a debug report (ArrCore's `identityFingerprint`, generalized).
    public var fingerprint: String {
        "\(baseURL?.absoluteString ?? "-")|\(apiKey?.count ?? 0)|\(username ?? "-")"
    }
}
