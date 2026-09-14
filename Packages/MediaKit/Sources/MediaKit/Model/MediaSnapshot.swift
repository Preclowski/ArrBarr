import Foundation

/// Who said this, when, and whether it came off the wire or out of the cache.
///
/// Not decoration: this is how the UI can write "IMDb 8.1 via Radarr", how a
/// stale value is told apart from a missing one, and how a wrong badge is
/// debugged without a proxy.
public struct Provenance: Hashable, Sendable, Codable {
    public let provider: ProviderID
    public let fetchedAt: Date
    public let fromCache: Bool

    public init(provider: ProviderID, fetchedAt: Date, fromCache: Bool) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
    }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(fetchedAt) }
}

/// What one provider returned for one query — its own answer, before merging.
/// Providers also hand back ids they learned (an arr lookup that reveals the
/// IMDb id), which is how an identity grows richer with every call.
public struct MediaFragment: Sendable {
    public var identity: MediaIdentity
    public var title: TitleFacts?
    public var artwork: Artwork?
    public var ratings: Ratings?
    public var availability: Availability?
    public var credits: Credits?
    public var streaming: StreamingAvailability?

    public init(identity: MediaIdentity) { self.identity = identity }

    /// Which of the requested fields this fragment actually answered — a
    /// provider that returns nothing for a field it claimed is a fact worth
    /// recording, not an error.
    public var populated: MediaFieldSet {
        var set: MediaFieldSet = []
        if title != nil { set.insert(.title) }
        if artwork != nil { set.insert(.artwork) }
        if ratings != nil { set.insert(.ratings) }
        if availability != nil { set.insert(.availability) }
        if credits != nil { set.insert(.credits) }
        if streaming != nil { set.insert(.streaming) }
        return set
    }
}

/// The answer to a query: whatever could be gathered, plus a record of where
/// each part came from and what failed.
///
/// Partial answers are the normal case, not an error path. One dead media
/// server must cost exactly one field — the poster, the title and the score
/// are still on screen.
public struct MediaSnapshot: Sendable {
    public private(set) var identity: MediaIdentity
    public private(set) var title: TitleFacts?
    public private(set) var artwork: Artwork?
    public private(set) var ratings: Ratings?
    public private(set) var availability: Availability?
    public private(set) var credits: Credits?
    public private(set) var streaming: StreamingAvailability?

    public private(set) var provenance: [MediaField: Provenance] = [:]
    public private(set) var failures: [MediaField: MediaError] = [:]

    public init(identity: MediaIdentity) { self.identity = identity }

    public var fields: MediaFieldSet {
        var set: MediaFieldSet = []
        for field in MediaField.allCases where provenance[field] != nil {
            set.insert(field.set)
        }
        return set
    }

    public func has(_ field: MediaField) -> Bool { provenance[field] != nil }

    /// Fold a provider's fragment in.
    ///
    /// Precedence is **positional**: the caller applies fragments in the order
    /// the field's precedence table names, and a field already answered is not
    /// overwritten. The two exceptions merge instead of losing data — ratings
    /// union by service, availability unions across sources — because there
    /// "second answer" means "another service also knows something", not
    /// "a worse answer".
    public mutating func apply(_ fragment: MediaFragment, from provenance: Provenance) {
        identity.merge(fragment.identity)

        func take<T>(_ field: MediaField, _ value: T?, into keyPath: WritableKeyPath<MediaSnapshot, T?>) {
            guard let value, self[keyPath: keyPath] == nil else { return }
            self[keyPath: keyPath] = value
            self.provenance[field] = provenance
            self.failures[field] = nil
        }

        take(.title, fragment.title, into: \.title)
        take(.artwork, fragment.artwork, into: \.artwork)
        take(.credits, fragment.credits, into: \.credits)
        take(.streaming, fragment.streaming, into: \.streaming)

        if let incoming = fragment.ratings, !incoming.scores.isEmpty {
            ratings = (ratings ?? Ratings()).merging(incoming)
            self.provenance[.ratings] = self.provenance[.ratings] ?? provenance
            failures[.ratings] = nil
        }
        if let incoming = fragment.availability {
            availability = availability.map { $0.merging(incoming) } ?? incoming
            self.provenance[.availability] = self.provenance[.availability] ?? provenance
            failures[.availability] = nil
        }
    }

    /// Record that a field could not be answered. Only sticks while the field
    /// is still empty — a failure next to a good value is noise.
    public mutating func fail(_ fields: MediaFieldSet, with error: MediaError) {
        for field in fields.fields where !has(field) {
            failures[field] = error
        }
    }
}

/// Everything that can go wrong, in terms the caller can act on. Deliberately
/// small: the layer's job is to degrade, not to explain HTTP.
public enum MediaError: Error, Hashable, Sendable, Codable {
    /// The provider has no credentials / is switched off. Not a failure —
    /// the planner simply skips it.
    case notConfigured(ProviderID)
    case unreachable(ProviderID)
    case unauthorized(ProviderID)
    case rateLimited(ProviderID, retryAfter: TimeInterval?)
    /// The provider answered, and does not know this title.
    case notFound(ProviderID)
    case decoding(ProviderID, String)
    case cancelled
    /// No configured provider claims this field at all.
    case unsupported(MediaField)
    /// No configured provider can serve this catalog query — the sources are
    /// missing, unconfigured, or none of them speaks this intent. Carries a
    /// description of what was asked, because `unsupported(.title)` on a
    /// browse told the user nothing and told the developer less.
    case noSource(String)
}

/// What the user sees when a screen has to show the failure.
///
/// Without this, SwiftUI's fallback prints the enum — the browse that failed
/// said "unsupported(MediaKit.MediaField.title)" on screen, which names a
/// Swift case rather than telling anyone what went wrong.
extension MediaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            "\(provider.rawValue) is not set up yet."
        case .unreachable(let provider):
            "Can't reach \(provider.rawValue)."
        case .unauthorized(let provider):
            "\(provider.rawValue) refused the key."
        case .rateLimited(let provider, let retryAfter):
            retryAfter.map { "\(provider.rawValue) is rate limiting — try again in \(Int($0))s." }
                ?? "\(provider.rawValue) is rate limiting."
        case .notFound(let provider):
            "\(provider.rawValue) doesn't know this title."
        case .decoding(let provider, _):
            "\(provider.rawValue) answered in a shape this build doesn't understand."
        case .cancelled:
            "Cancelled."
        case .unsupported(let field):
            "Nothing configured can answer \(field.rawValue)."
        case .noSource(let detail):
            "No source can answer this: \(detail)."
        }
    }
}
